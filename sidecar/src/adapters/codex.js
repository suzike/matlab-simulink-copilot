import { spawn } from 'node:child_process';
import { BackendAdapter, renderContextPreamble } from './types.js';
import { createLineBuffer, parseLine, OutMsg } from '../protocol.js';
import { terminateProcessTree } from '../processTree.js';

/**
 * 后端:OpenAI Codex CLI(`codex exec --json`,逐 JSONL 事件)。
 *
 * Codex 与 Claude Code 的差异:
 *  - 按「完整 item」推送(item.completed),不是逐 token;每个 item 直接整条渲染。
 *  - 事件:thread.started(resume id)→ turn.started → item.completed* → turn.completed。
 *  - MCP 服务器、模型、鉴权都来自 Codex 自身配置(~/.codex),无需我们注入。
 *  - 多轮用 `codex exec resume <thread_id>` 续接。
 */
export class CodexAdapter extends BackendAdapter {
  constructor(opts = {}) {
    super();
    this.bin = opts.bin || process.env.CODEX_BIN || 'codex';
    this.cwd = opts.cwd || process.cwd();
    this.model = opts.model || null;                 // -m
    this.effort = opts.effort || null;               // low|medium|high → model_reasoning_effort
    this.sandbox = opts.sandbox || 'workspace-write'; // read-only|workspace-write|danger-full-access
    this.extraArgs = opts.extraArgs || [];
    // 默认 --ignore-user-config:甩掉用户 ~/.codex 里的大量 skill 与会卡顿的 MCP(有的鉴权超时 ~30s),
    // 启动耗时近乎减半(实测 64s→36s);再用 -c 精准注入 matlab MCP 保留模型/仿真工具。
    this.ignoreUserConfig = opts.ignoreUserConfig ?? true;
    this.matlabMcp = opts.matlabMcp || null; // { command, args }
    this.threadId = null;
    this.child = null;
    this._pending = [];      // 上一轮收尾(进程未 close)期间排队的下几条消息(FIFO)
    // 主动 kill 标记绑定到具体 child 实例(child._killing),避免「同步 kill+立即新建」
    // 与「异步 close 回调」跨代竞争一个共享布尔(与 claudeCode.js 一致)。
  }

  async start() {
    this.emitEvent({ type: OutMsg.READY });
  }

  buildArgs() {
    const args = ['exec', '--json', '--skip-git-repo-check', '--color', 'never'];
    if (this.threadId) args.splice(1, 0, 'resume', this.threadId); // exec resume <id> --json ...
    if (this.ignoreUserConfig) args.push('--ignore-user-config');
    args.push('-C', this.cwd);
    args.push('-s', this.sandbox);
    if (this.model) args.push('-m', this.model);
    if (this.effort) args.push('-c', `model_reasoning_effort="${this.effort}"`);
    // 精简模式下重新注入 matlab MCP(路径用正斜杠避开 TOML 反斜杠转义)。
    if (this.ignoreUserConfig && this.matlabMcp && this.matlabMcp.command) {
      const fwd = (s) => String(s).replace(/\\/g, '/');
      const list = (this.matlabMcp.args || []).map((a) => '"' + fwd(a).replace(/"/g, '\\"') + '"').join(',');
      args.push('-c', `mcp_servers.matlab.command="${fwd(this.matlabMcp.command)}"`);
      args.push('-c', `mcp_servers.matlab.args=[${list}]`);
    }
    args.push(...this.extraArgs);
    return args;
  }

  async sendMessage(payload = {}) {
    if (this.child) {
      // 上一轮收尾中(已产出结果、进程未 close)→ 入队,close 后逐条发,避免「上一轮尚未结束」。
      this._pending.push(payload);
      return;
    }
    const { text, context } = payload;
    const prompt = renderContextPreamble(context) + (text || '');
    const args = this.buildArgs();
    const useShell = process.platform === 'win32';

    this.emitEvent({ type: OutMsg.STATUS, text: 'thinking' });

    const child = spawn(this.bin, useShell ? args.map(quoteArg) : args, {
      cwd: this.cwd,
      shell: useShell,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });
    this.child = child;

    // stdin 异步错误(进程已死 → EPIPE)监听:不挂则会冒泡成未捕获异常,拖垮整个 sidecar。
    child.stdin.on('error', (err) => {
      if (this.child === child) this.child = null;
      if (!child._killing) this.emitEvent({ type: OutMsg.ERROR, message: `codex 输入流错误: ${err.message}` });
    });

    let stderrBuf = '';
    let gotTurn = false;

    // 空闲看门狗:codex 进程「卡住不输出也不退出」(hang)时,close 兜底不会触发 → UI 永久卡死。
    // 基于「静默」超时(每次有输出就重置),不误杀慢响应;codex 冷启较慢,阈值取 180s。
    let watchdog = null;
    const armWatchdog = () => {
      if (watchdog) clearTimeout(watchdog);
      watchdog = setTimeout(() => {
        if (this.child === child && !gotTurn) {
          this.emitEvent({ type: OutMsg.ERROR, message: 'Codex 长时间无响应(180s 静默),已终止本轮' });
          this.killChild(child);              // _killing=true → close 回调不再重复补事件
          if (this.child === child) this.child = null;
          this.emitEvent({ type: OutMsg.RESULT, id: null, ok: false, text: '', costUsd: null });
        }
      }, 180000);
      if (watchdog.unref) watchdog.unref();
    };
    armWatchdog();

    const feed = createLineBuffer((line) => {
      if (this.child !== child || child._killing) return;
      const obj = parseLine(line);   // 自动跳过非 JSON 行(codex 的日志行)
      if (!obj) return;
      if (this.handle(obj)) gotTurn = true;
    });

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d) => {
      if (this.child !== child || child._killing) return;
      armWatchdog();
      feed(d);
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (d) => { stderrBuf += d; });

    // 以下回调闭包捕获这一代 child,用 `this.child === child` 守卫,
    // 避免旧进程的异步 close/error 误清新一代 child 或误报错误。
    child.on('error', (err) => {
      if (this.child !== child) return;
      this.child = null;
      if (!child._killing) this.emitEvent({ type: OutMsg.ERROR, message: `启动 codex 失败: ${err.message}` });
    });
    child.on('close', (code) => {
      if (watchdog) clearTimeout(watchdog);        // 进程已结束,撤看门狗
      if (this.child === child) this.child = null;
      if (child._userAbort) { this._pending = []; return; }   // 用户主动中断/重置:清空排队,不补事件
      // 看门狗超时(_killing 但非 userAbort)已自行补过 RESULT;此处只跳过补事件,排队仍续发。
      if (!child._killing && !gotTurn) {
        // 进程结束却没拿到 turn.completed(codex 中途退出/卡断/事件格式异常)。
        // 必须补一个 RESULT 让 UI 一定收尾,否则会永久卡在「思考中」(这是 Codex「只回一下就没反应」的根因)。
        if (code !== 0) {
          const tail = stderrBuf.trim().split('\n').slice(-6).join('\n');
          this.emitEvent({ type: OutMsg.ERROR, message: `codex 退出码 ${code}${tail ? `:\n${tail}` : ''}` });
        } else {
          this.emitEvent({ type: OutMsg.STATUS, text: 'Codex 未给出完整结果(进程已结束)' });
        }
        this.emitEvent({ type: OutMsg.RESULT, id: null, ok: code === 0, text: '', costUsd: null });
      }
      // 排队的下一轮:进程正常退出后逐条发(this.child 已 null)。同步 spawn,同时兜住同步抛错与异步 reject,
      // 避免排队消息发送失败时未捕获异常拖垮整个 sidecar。
      if (!this.child && this._pending.length) {
        const p = this._pending.shift();
        try {
          const r = this.sendMessage(p);
          if (r && typeof r.catch === 'function') r.catch((err) => this.emitEvent({ type: OutMsg.ERROR, message: '排队消息发送失败: ' + (err?.message || err) }));
        } catch (err) {
          this.emitEvent({ type: OutMsg.ERROR, message: '排队消息发送失败: ' + (err?.message || err) });
        }
      }
    });

    try {
      child.stdin.write(prompt);
      child.stdin.end();
    } catch (e) {
      if (this.child === child) this.child = null;
      this.emitEvent({ type: OutMsg.ERROR, message: `写入 codex 失败: ${e?.message || e}` });
    }
  }

  // 处理一个 codex JSONL 事件,翻译成 UI 事件。返回 true 表示本轮已完成(turn.completed)。
  handle(obj) {
    switch (obj.type) {
      case 'thread.started':
        if (obj.thread_id) this.threadId = obj.thread_id;
        return false;
      case 'item.completed':
        this.handleItem(obj.item || {});
        return false;
      case 'turn.completed': {
        const u = obj.usage || {};
        this.emitEvent({ type: OutMsg.RESULT, id: null, ok: true, text: '', costUsd: null, usage: u });
        return true;
      }
      case 'turn.failed':
        this.emitEvent({ type: OutMsg.ERROR, message: '本轮失败:' + (obj.error?.message || '未知') });
        // 补一个 RESULT 让 UI 一定收尾(解除 thinking/结束本轮),否则失败轮会停在思考态。
        this.emitEvent({ type: OutMsg.RESULT, id: null, ok: false, text: '', costUsd: null });
        return true;
      default:
        return false;
    }
  }

  handleItem(item) {
    const id = `codex-${item.id || Math.random().toString(36).slice(2)}`;
    switch (item.type) {
      case 'agent_message': {
        const text = item.text || '';
        if (!text) break;
        this.emitEvent({ type: OutMsg.ASSISTANT_START, id });
        this.emitEvent({ type: OutMsg.ASSISTANT_DELTA, id, text });
        this.emitEvent({ type: OutMsg.ASSISTANT_STOP, id });
        break;
      }
      case 'reasoning': {
        const text = item.text || item.summary || '';
        if (!text) break;
        this.emitEvent({ type: OutMsg.THINKING_START, id });
        this.emitEvent({ type: OutMsg.THINKING_DELTA, id, text });
        this.emitEvent({ type: OutMsg.THINKING_STOP, id });
        break;
      }
      case 'command_execution': {
        const out = item.aggregated_output ?? item.output ?? '';
        const ok = (item.exit_code ?? 0) === 0;
        this.emitEvent({ type: OutMsg.TOOL_USE, id, name: 'Bash', input: { command: item.command || '' } });
        this.emitEvent({ type: OutMsg.TOOL_RESULT, id, ok, summary: String(out).slice(0, 600) });
        break;
      }
      case 'mcp_tool_call': {
        const ok = item.status !== 'failed' && !item.is_error;
        this.emitEvent({ type: OutMsg.TOOL_USE, id, name: item.tool || item.name || 'mcp', input: item.arguments ?? item.input ?? {} });
        this.emitEvent({ type: OutMsg.TOOL_RESULT, id, ok, summary: String(item.result ?? item.output ?? '').slice(0, 600) });
        break;
      }
      case 'file_change':
      case 'patch': {
        this.emitEvent({ type: OutMsg.TOOL_USE, id, name: '文件修改', input: item.changes ?? item.files ?? item });
        this.emitEvent({ type: OutMsg.TOOL_RESULT, id, ok: true, summary: '已生成改动(可用 codex apply 落地)' });
        break;
      }
      case 'error': {
        const msg = item.message || '';
        // 过滤已知的非致命噪声:skill 预算超限、传输层回退/重试(Codex 会自动重试成功)。
        if (/skills context budget|falling back from websockets|transport.*timed out/i.test(msg)) break;
        this.emitEvent({ type: OutMsg.ERROR, message: 'Codex: ' + msg });
        break;
      }
      default:
        break;
    }
  }

  // 结束一个 child:标记 _killing(close 据此不补错误),包 try/catch(进程可能已退出)。
  // userAbort=true 表示「用户主动中断/重置」→ close 会清空排队;看门狗超时等自动终止不传,排队保留续发。
  killChild(child, { userAbort = false } = {}) {
    if (!child) return;
    child._killing = true;
    if (userAbort) child._userAbort = true;
    terminateProcessTree(child);
  }

  interrupt() {
    this._pending = [];   // 中断即丢弃所有排队消息(与 claudeCode 一致)
    if (this.child) {
      this.killChild(this.child, { userAbort: true });
      this.child = null;
      this.emitEvent({ type: OutMsg.STATUS, text: 'interrupted' });
    }
  }

  async stop() {
    this._pending = [];
    if (this.child) { this.killChild(this.child, { userAbort: true }); this.child = null; }
  }

  resetSession() { this.threadId = null; this._pending = []; }
}

function quoteArg(arg) {
  const s = String(arg);
  if (/[\s"]/.test(s)) return `"${s.replace(/"/g, '\\"')}"`;
  return s;
}
