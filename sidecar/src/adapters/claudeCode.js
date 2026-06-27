import { spawn } from 'node:child_process';
import { BackendAdapter, renderContextPreamble } from './types.js';
import { createStreamTranslator } from '../streamJsonParser.js';
import { createLineBuffer, parseLine, OutMsg } from '../protocol.js';

/**
 * v1 后端:headless Claude Code(`claude --print --output-format stream-json`)。
 *
 * 两种生命周期模式:
 *  ① resume 模式(默认,已验证可靠):每轮 spawn 一个 `claude --print` 进程,
 *     通过 --resume 续接上一轮 session_id。进程生命周期简单、易中断;每轮冷启数百 ms。
 *  ② 常驻模式(opt-in,env MATLAB_COPILOT_PERSISTENT=1):start 时拉起一个常驻
 *     `--input-format stream-json` 进程,每轮往 stdin 写一条 user 消息,消除冷启延迟。
 *     进程意外退出 → 下轮自动以 sessionId resume 重启;中断 → kill+resume 续接。
 *     per-turn systemPrompt(如 insert 模式)无法热换 system prompt → 指令并入消息文本。
 */
export class ClaudeCodeAdapter extends BackendAdapter {
  constructor(opts = {}) {
    super();
    this.bin = opts.bin || process.env.CLAUDE_BIN || 'claude';
    this.cwd = opts.cwd || process.cwd();
    this.model = opts.model || null;
    this.allowedTools = opts.allowedTools || null; // string[] 预批工具,免确认
    this.mcpConfigPath = opts.mcpConfigPath || null; // 权限确认 MCP 配置
    this.strictMcpConfig = opts.strictMcpConfig ?? false; // 只用 --mcp-config 里的 server
    this.permissionPromptTool = opts.permissionPromptTool || null; // 例如 mcp__approval__approval
    this.permissionMode = opts.permissionMode || null; // null(默认/逐条确认)| acceptEdits | plan
    this.appendSystemPrompt = opts.appendSystemPrompt || null;
    this.extraArgs = opts.extraArgs || [];
    this.scrubNestedAuth = opts.scrubNestedAuth ?? true;
    // extended thinking 预算(token)。>0 时让子 claude 输出思考过程;0 关闭。
    this.thinkingTokens = opts.thinkingTokens ?? 0;
    // 常驻模式开关:opt-in,默认走可靠的 resume 模式。
    this.persistent = opts.persistent ?? (process.env.MATLAB_COPILOT_PERSISTENT === '1');
    this.sessionId = null;
    this.child = null;
    this.translator = null;   // 常驻模式:跨轮复用的 stream-json 翻译器
    this.busy = false;        // 常驻模式:本轮是否进行中(防上一轮未结束就又发;不依赖 child 是否存在)
    this._pending = [];       // resume 模式:上一轮收尾(result 已出、未 close)期间排队的下几条消息(FIFO)
    // 主动 kill / 不回写 session 的标记绑定到具体 child 实例(child._killing / child._noSession),
    // 避免「同步 kill+立即新建」与「异步 close 回调」跨代竞争一个共享布尔。
  }

  // 构造子 claude 的环境变量。若检测到自己运行在 Claude Code 会话内部(CLAUDECODE),
  // 其注入的受限 ANTHROPIC_AUTH_TOKEN 会让新拉起的 claude 报 401。此时剔除这些注入变量,
  // 让子 claude 回退到本机登录凭据(~/.claude/.credentials.json)。
  // 正常从 MATLAB 启动不会设置 CLAUDECODE,因此不受影响,用户的 relay(ANTHROPIC_BASE_URL 等)得以保留。
  buildEnv() {
    const env = { ...process.env };
    if (this.scrubNestedAuth && env.CLAUDECODE) {
      delete env.ANTHROPIC_API_KEY;
      delete env.ANTHROPIC_AUTH_TOKEN;
      delete env.ANTHROPIC_BASE_URL;
      delete env.CLAUDECODE;
      delete env.CLAUDE_AGENT_SDK_VERSION;
      for (const k of Object.keys(env)) {
        if (k.startsWith('CLAUDE_CODE_')) delete env[k];
      }
    }
    // 启用 extended thinking:Claude Code 读 MAX_THINKING_TOKENS 决定思考预算。
    if (this.thinkingTokens > 0) env.MAX_THINKING_TOKENS = String(this.thinkingTokens);
    return env;
  }

  async start() {
    // 常驻模式:预热常驻进程,消除首轮冷启(失败不致命,首轮 sendMessage 会重试)。
    if (this.persistent) {
      try { this.ensurePersistentChild(); } catch (e) { /* 留给首轮重启 */ }
    }
    this.emitEvent({ type: OutMsg.READY });
  }

  buildArgs(systemPrompt, { stream = false } = {}) {
    const args = [
      '--print',
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
    ];
    if (stream) args.push('--input-format', 'stream-json');  // 常驻模式:从 stdin 读多条消息
    if (this.sessionId) args.push('--resume', this.sessionId);
    if (this.model) args.push('--model', this.model);
    if (this.allowedTools?.length) args.push('--allowedTools', this.allowedTools.join(','));
    if (this.permissionMode) args.push('--permission-mode', this.permissionMode);
    if (this.mcpConfigPath) args.push('--mcp-config', this.mcpConfigPath);
    if (this.strictMcpConfig) args.push('--strict-mcp-config');
    if (this.permissionPromptTool) args.push('--permission-prompt-tool', this.permissionPromptTool);
    const sys = systemPrompt || this.appendSystemPrompt;
    if (sys) args.push('--append-system-prompt', sys);
    args.push(...this.extraArgs);
    return args;
  }

  async sendMessage({ text, context, systemPrompt } = {}) {
    if (this.persistent) {
      // 常驻模式无法热换 system prompt → per-turn override(如 insert)并入消息文本。
      let t = text || '';
      if (systemPrompt) t = `[本轮系统指令] ${systemPrompt}\n\n${t}`;
      return this.sendPersistent({ text: t, context });
    }
    return this.sendOneShot({ text, context, systemPrompt });
  }

  // resume 模式:每轮独立 spawn,写完 stdin 即关闭 → claude 处理产出 result 后退出。
  sendOneShot(payload = {}) {
    if (this.child) {
      // 上一轮收尾中(result 已发、进程尚未 close)→ 入队,进程 close 后逐条发;
      // 否则会撞上「上一轮尚未结束」(队列/引导模式在 result 后立刻发下一条时常见)。
      this._pending.push(payload);
      return;
    }
    const { text, context, systemPrompt } = payload;
    const prompt = renderContextPreamble(context) + (text || '');
    const args = this.buildArgs(systemPrompt);
    const child = this.spawnChild(args);
    this.child = child;
    this.emitEvent({ type: OutMsg.STATUS, text: 'thinking' });

    const translator = createStreamTranslator();
    this.wireChild(child, translator, 'claude');

    child.stdin.write(prompt);
    child.stdin.end();
  }

  // 常驻模式:确保常驻进程在跑,往 stdin 写一条 stream-json user 消息(不关 stdin)。
  sendPersistent({ text, context } = {}) {
    if (this.busy) {                         // C1:常驻 child 长存,不能用 child 判忙
      this.emitEvent({ type: OutMsg.ERROR, message: '上一轮尚未结束' });
      return;
    }
    const prompt = renderContextPreamble(context) + (text || '');
    const line = JSON.stringify({
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text: prompt }] },
    }) + '\n';

    // 写入失败(进程刚死/EPIPE)→ 重启常驻进程并重发一次,避免吞掉本轮请求。
    const tryWrite = (allowRetry) => {
      try {
        this.ensurePersistentChild();
      } catch (e) {
        this.busy = false;
        this.emitEvent({ type: OutMsg.ERROR, message: '启动常驻 claude 失败: ' + (e?.message || e) });
        return;
      }
      this.busy = true;
      this.emitEvent({ type: OutMsg.STATUS, text: 'thinking' });
      const child = this.child;
      try {
        child.stdin.write(line);
      } catch (e) {
        if (this.child === child) this.child = null;
        if (allowRetry) { tryWrite(false); return; }   // 重启重发一次
        this.busy = false;
        this.emitEvent({ type: OutMsg.ERROR, message: '写入常驻 claude 失败: ' + (e?.message || e) });
      }
    };
    tryWrite(true);
  }

  // 常驻进程惰性创建:已存活则复用;意外退出后下次调用以 sessionId resume 重建。
  ensurePersistentChild() {
    if (this.child) return;
    const child = this.spawnChild(this.buildArgs(null, { stream: true }));
    this.child = child;
    this.translator = createStreamTranslator();
    this.wireChild(child, this.translator, '常驻 claude');
  }

  // 统一 spawn,挂 stdin error 监听(防 EPIPE 异步抛出冒泡 crash)。
  spawnChild(args) {
    const useShell = process.platform === 'win32';
    const child = spawn(this.bin, useShell ? args.map(quoteArg) : args, {
      cwd: this.cwd,
      shell: useShell,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: this.buildEnv(),
    });
    child.stdin.on('error', (err) => {
      if (this.child === child) { this.child = null; this.busy = false; }
      if (!child._killing) this.emitEvent({ type: OutMsg.ERROR, message: `claude 输入流错误: ${err.message}` });
    });
    return child;
  }

  // 统一接线 stdout/stderr/error/close。所有状态绑定到这一代 child(闭包捕获),
  // 用 `this.child === child` 守卫,避免旧进程的异步 close 误清新进程/误报错误。
  wireChild(child, translator, label) {
    let stderrBuf = '';
    const feed = createLineBuffer((rawLine) => {
      const obj = parseLine(rawLine);
      if (!obj) return;
      for (const ev of translator.handle(obj)) {
        if (ev.type === OutMsg.RESULT && this.child === child) {
          this.busy = false;                                 // 本轮结束
          const sid = translator.getSessionId();             // 及时回写 session,供崩溃/中断后 resume 重启
          if (sid && !child._noSession) this.sessionId = sid;
        }
        this.emitEvent(ev);
      }
    });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', feed);
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (d) => { stderrBuf += d; });

    child.on('error', (err) => {
      if (this.child === child) { this.child = null; this.busy = false; }
      this.emitEvent({ type: OutMsg.ERROR, message: `启动 ${label} 失败: ${err.message}` });
    });

    child.on('close', (code) => {
      // 只回写自己这代 translator 的 session;_noSession(reset 触发)时不回写,避免覆盖刚清空的 session。
      const sid = translator.getSessionId();
      if (sid && !child._noSession) this.sessionId = sid;
      if (this.child === child) { this.child = null; this.busy = false; }  // 仅清自己这代
      if (code !== 0 && !child._killing) {
        const tail = stderrBuf.trim().split('\n').slice(-5).join('\n');
        this.emitEvent({ type: OutMsg.ERROR, message: `${label} 退出码 ${code}${tail ? `:\n${tail}` : ''}` });
      }
      // 排队的下一轮:进程正常退出后逐条发(此时 this.child 已 null);主动 kill(中断/重置)则清空排队。
      // 同步 spawn,同时兜住同步抛错与异步 reject,避免排队消息发送失败时未捕获异常拖垮 sidecar。
      if (child._killing) { this._pending = []; }
      else if (!this.child && this._pending.length) {
        const p = this._pending.shift();
        try {
          const r = this.sendMessage(p);
          if (r && typeof r.catch === 'function') r.catch((err) => this.emitEvent({ type: OutMsg.ERROR, message: '排队消息发送失败: ' + (err?.message || err) }));
        } catch (err) {
          this.emitEvent({ type: OutMsg.ERROR, message: '排队消息发送失败: ' + (err?.message || err) });
        }
      }
    });
  }

  // 主动结束一个 child:标记 _killing(close 据此不报错)+ 可选不回写 session,然后 kill。
  killChild(child, { noSession = false } = {}) {
    if (!child) return;
    child._killing = true;
    if (noSession) child._noSession = true;
    try { child.kill('SIGTERM'); } catch { /* 已退出 */ }
  }

  interrupt() {
    this._pending = [];   // 中断即丢弃所有排队消息(前端队列也已同步清空)
    if (this.child) {
      this.killChild(this.child);
      this.child = null;   // 常驻模式:下轮 sendPersistent 以 sessionId resume 重启
      this.busy = false;
      this.emitEvent({ type: OutMsg.STATUS, text: 'interrupted' });
    }
  }

  async stop() {
    this._pending = [];
    if (this.child) {
      this.killChild(this.child);
      this.child = null;
      this.busy = false;
    }
  }

  resetSession() {
    this.sessionId = null;
    this._pending = [];   // 换会话:残留的旧排队不应带进新会话
    // 在途进程必须 kill 并禁止其 close 回写 session(否则旧进程退出会覆盖刚清空的 sessionId)。
    // 常驻模式下这也保证换新 session 时重启进程。
    if (this.child) {
      this.killChild(this.child, { noSession: true });
      this.child = null;
      this.busy = false;
    }
  }
}

// shell:true(Windows)下,给含空格的参数加引号,避免路径被拆断。
function quoteArg(arg) {
  const s = String(arg);
  if (/[\s"]/.test(s)) return `"${s.replace(/"/g, '\\"')}"`;
  return s;
}
