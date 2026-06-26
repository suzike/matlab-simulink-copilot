import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { InMsg, OutMsg, serialize, createLineBuffer, parseLine } from './protocol.js';
import { isReadonlyTool, isExecuteTool, isSafeIntrospection, INSERT_SYSTEM_PROMPT } from './config.js';
import { getCapabilities, resolveSlashCommand } from './capabilities.js';

/**
 * sidecar 的网络层:
 *  - clientServer(clientPort):UI/MATLAB 连接。转发后端事件,接收用户消息。
 *  - controlServer(controlPort):权限确认 MCP(permissionServer)回连。
 *    收到工具确认请求 → 只读自动放行,其余转发给 UI 等用户点确认。
 *
 * 单 UI 客户端(侧边栏面板)即可满足 v1。
 */
export class Server {
  constructor({ makeAdapter, config, cwd, host, clientPort, controlPort }) {
    this.makeAdapter = makeAdapter;
    this.config = config || {};      // 默认/全局配置 {backend,model,effort,mode}
    this.cwd = cwd || process.cwd();
    this.host = host;
    this.clientPort = clientPort;
    this.controlPort = controlPort;
    this.convs = new Map();          // convId -> 会话状态 {convId,config,adapter,compacting,compactBuf,seed}
    this.client = null;              // 当前 UI socket
    this.pendingPermissions = new Map(); // reqId -> { sock, convId }
    this.audit = [];                 // 操作审计轨迹(破坏性工具调用留痕)
    this._clientServer = null;
    this._controlServer = null;
  }

  // 取/建一个会话(标签页/分支)。convId 缺省为 'main';新会话可带初始配置(每页独立配置)。
  ensureConv(convId, config) {
    convId = convId || 'main';
    let c = this.convs.get(convId);
    if (c) return c;
    c = { convId, config: { ...this.config, ...(config || {}) }, adapter: null,
          compacting: false, compactBuf: '', seed: null };
    c.adapter = this.makeAdapter({ ...c.config, convId });
    this.wireConv(c);
    Promise.resolve(c.adapter.start()).catch((e) =>
      this.toClient({ type: OutMsg.ERROR, convId, message: '后端启动失败: ' + (e?.message || e) }));
    this.convs.set(convId, c);
    return c;
  }

  getConv(convId) { return this.convs.get(convId || 'main') || this.ensureConv(convId); }

  wireConv(c) {
    c.adapter.on('event', (uiMsg) => this.onAdapterEvent(c, uiMsg));
    c.adapter.on('error', (err) =>
      this.toClient({ type: OutMsg.ERROR, convId: c.convId, message: String(err?.message || err) }));
  }

  // 操作审计:破坏性工具调用 → 记一条(含改了什么、属于哪个会话),落 JSONL + 推 UI「变更记录」。
  recordAudit(c, uiMsg) {
    try {
      if (uiMsg.type === OutMsg.TOOL_USE && !isReadonlyTool(uiMsg.name)) {
        const entry = {
          id: uiMsg.id,
          convId: c.convId,
          time: new Date().toISOString(),
          tool: uiMsg.name,
          action: summarizeAction(uiMsg.input),
          status: 'pending',   // 工具被请求;待 TOOL_RESULT 回来转 ok/failed(被拒/未执行则停在 pending,不谎称已执行)
          backend: c.config.backend || null,
          mode: c.config.mode || null,
        };
        this.audit.push(entry);
        writeAuditLine(entry);
        this.toClient({ type: OutMsg.AUDIT, convId: c.convId, entry });
      } else if (uiMsg.type === OutMsg.TOOL_RESULT) {
        const e = this.audit.find((a) => a.id === uiMsg.id);
        if (e) {
          e.status = uiMsg.ok === false ? 'failed' : 'ok';
          e.resultTime = new Date().toISOString();
          writeAuditLine(e);   // append-only 事件日志:追加最终状态一行
          this.toClient({ type: OutMsg.AUDIT, convId: e.convId, entry: e });
        }
      }
    } catch {}
  }

  // 适配器事件 → 打上 convId 让 UI 路由到对应标签页/分支 → 审计 → 压缩处理 → 转发。
  onAdapterEvent(c, uiMsg) {
    const tagged = { ...uiMsg, convId: c.convId };
    this.recordAudit(c, tagged);
    if (c.compacting) {
      if (tagged.type === OutMsg.ASSISTANT_DELTA) c.compactBuf += tagged.text || '';
      else if (tagged.type === OutMsg.RESULT) {
        c.seed = c.compactBuf.trim();
        c.compactBuf = '';
        c.compacting = false;
        try { c.adapter.resetSession(); } catch {}
        this.toClient(tagged);
        this.toClient({ type: OutMsg.STATUS, convId: c.convId, text: '已压缩:历史已重置,摘要将带入下一轮' });
        return;
      }
    }
    this.toClient(tagged);
  }

  // 运行时切换某会话的后端/模型/模式/思考强度:停旧、按新配置重建、重连事件。
  async applyConfig(convId, partial) {
    const c = this.getConv(convId);
    c.config = { ...c.config, ...(partial || {}) };
    // 切后端会换掉 adapter,正在进行的 /compact 那次 RESULT 不会再来 → 清压缩中间态,避免会话永久卡在 compacting。
    c.compacting = false; c.compactBuf = '';
    try { await c.adapter?.stop(); } catch {}
    c.adapter = this.makeAdapter({ ...c.config, convId: c.convId });
    this.wireConv(c);
    try { await c.adapter.start(); } catch (e) {
      this.toClient({ type: OutMsg.ERROR, convId: c.convId, message: '切换后端失败: ' + (e?.message || e) });
    }
    this.toClient({ type: OutMsg.CONFIG_CHANGED, convId: c.convId, config: c.config });
  }

  async closeConv(convId) {
    const c = this.convs.get(convId);
    if (!c || convId === 'main') return;   // main 不关
    try { await c.adapter?.stop(); } catch {}
    this.convs.delete(convId);
  }

  async start() {
    this.ensureConv('main', this.config);   // 默认会话,向后兼容单页

    this._clientServer = net.createServer((sock) => this.onClient(sock));
    this._controlServer = net.createServer((sock) => this.onControl(sock));

    await listen(this._clientServer, this.clientPort, this.host);
    await listen(this._controlServer, this.controlPort, this.host);

    return {
      clientPort: this._clientServer.address().port,
      controlPort: this._controlServer.address().port,
    };
  }

  async stop() {
    for (const c of this.convs.values()) { try { await c.adapter.stop(); } catch {} }
    this._clientServer?.close();
    this._controlServer?.close();
  }

  // ── UI 客户端 ───────────────────────────────────────────────────────────
  onClient(sock) {
    sock.setEncoding('utf8');
    this.client = sock;
    const feed = createLineBuffer((line) => this.handleClientLine(line));
    sock.on('data', feed);
    sock.on('close', () => { if (this.client === sock) this.client = null; });
    sock.on('error', () => {});
    this.toClient({ type: OutMsg.READY });
  }

  handleClientLine(line) {
    const msg = parseLine(line);
    if (!msg) return;
    switch (msg.type) {
      case InMsg.PING:
        this.toClient({ type: OutMsg.PONG });
        break;
      case InMsg.USER_MESSAGE: {
        const c = this.getConv(msg.convId);
        // insert_at_cursor 模式:用「只产出代码」的系统提示覆盖本轮。
        const systemPrompt = msg.intent === 'insert_at_cursor' ? INSERT_SYSTEM_PROMPT : undefined;
        let context = msg.context;
        if (c.seed) { context = { ...(context || {}), compactSummary: c.seed }; c.seed = null; }
        c.adapter.sendMessage({ text: msg.text, context, systemPrompt });
        break;
      }
      case InMsg.INTERRUPT:
        this.getConv(msg.convId).adapter.interrupt();
        break;
      case InMsg.PERMISSION_RESPONSE:
        this.resolvePermission(msg.convId, msg.id, msg.approved === true);
        break;
      case InMsg.SET_CONFIG:
        this.applyConfig(msg.convId, msg.config || {});
        break;
      case InMsg.CLOSE_CONV:
        this.closeConv(msg.convId);
        break;
      case InMsg.GET_CAPABILITIES:
        this.toClient({ type: OutMsg.CAPABILITIES, ...getCapabilities(this.config, this.cwd) });
        break;
      case InMsg.SLASH_COMMAND:
        this.handleSlash(msg);
        break;
      default:
        break;
    }
  }

  handleSlash(msg) {
    const c = this.getConv(msg.convId);
    const name = msg.name || '';
    if (name === '/compact') {
      // 真压缩:生成摘要(用户可见)→ 本轮结束后重置会话 → 摘要播种下一轮(见 onAdapterEvent)。
      c.compacting = true;
      c.compactBuf = '';
      c.adapter.sendMessage({
        text: '请用要点总结我们到目前为止的对话:关键决策、约束、已完成、待办。控制在 300 字内。',
        context: msg.context,
      });
      return;
    }
    const cmd = resolveSlashCommand(name, this.cwd);
    if (cmd && cmd.kind === 'custom') {
      // 约定:命令体含 $ARGUMENTS 则替换为用户参数,否则把参数附在末尾。
      let text = cmd.body;
      if (/\$ARGUMENTS/.test(text)) text = text.replace(/\$ARGUMENTS/g, msg.args || '');
      else if (msg.args) text += '\n\n' + msg.args;
      c.adapter.sendMessage({ text, context: msg.context });
    }
    // 其余内置命令(/model /mode /clear 等)由 UI 端直接处理(set_config / 本地动作)。
  }

  toClient(obj) {
    if (this.client && !this.client.destroyed) {
      this.client.write(serialize(obj) + '\n');
    }
  }

  // ── 权限确认(控制端口)─────────────────────────────────────────────────
  onControl(sock) {
    sock.setEncoding('utf8');
    const feed = createLineBuffer((line) => this.handleControlLine(line, sock));
    sock.on('data', feed);
    sock.on('error', () => {});
    // control 连接断开:清理该 sock 的所有悬挂权限请求(含定时器),避免 Map 泄漏与悬挂回调。
    sock.on('close', () => {
      for (const [key, p] of this.pendingPermissions) {
        if (p.sock === sock) {
          if (p.timer) clearTimeout(p.timer);
          this.pendingPermissions.delete(key);
        }
      }
    });
  }

  handleControlLine(line, sock) {
    const msg = parseLine(line);
    if (!msg || msg.type !== 'permission_request') return;
    const { id, tool, input } = msg;
    // 权限请求由各会话的 approval MCP 带上 convId(见 index.js / permissionServer.js);
    // 据此用「该会话的」编辑模式判定,并把确认卡路由到对应标签页。
    const convId = msg.convId || 'main';
    const mode = (this.convs.get(convId)?.config || this.config).mode;

    // 只读工具,或只读文档自省(help/which/exist/lookfor,文档兜底用):自动放行。
    if (isReadonlyTool(tool) || isSafeIntrospection(tool, input)) {
      this.controlReply(sock, id, true);
      return;
    }
    // 「自动」编辑模式:改模型/写文件自动放行;"运行代码/跑测试/执行 shell"仍需确认。
    if (mode === 'auto' && !isExecuteTool(tool)) {
      this.controlReply(sock, id, true);
      return;
    }
    // 「计划」模式:只读探索、绝不改动。破坏性工具一律拒绝(sidecar 强制)。
    if (mode === 'plan') {
      this.controlReply(sock, id, false, '计划模式:先给出方案,暂不执行修改;要执行请切到 Ask/Auto。');
      return;
    }
    // 没有 UI 连接时,破坏性操作一律拒绝(安全默认)。
    if (!this.client || this.client.destroyed) {
      this.controlReply(sock, id, false, '面板未连接,已自动拒绝');
      return;
    }
    // 转发给 UI 等用户确认(带 convId,卡片落到对应标签页)。键用 convId::id 避免跨标签页 id 撞车。
    // 超时(180s)未响应 → 默认拒绝(安全默认),并清理条目,避免悬挂回调与 Map 泄漏。
    const key = `${convId}::${id}`;
    const timer = setTimeout(() => {
      if (this.pendingPermissions.has(key)) {
        this.pendingPermissions.delete(key);
        this.controlReply(sock, id, false, '确认超时，已自动拒绝');
      }
    }, 180000);
    if (timer.unref) timer.unref();   // 不阻止进程退出
    this.pendingPermissions.set(key, { sock, id, convId, timer });
    const diff = buildDiff(tool, input);
    this.toClient({ type: OutMsg.PERMISSION_REQUEST, convId, id, tool, input, destructive: true, diff });
  }

  resolvePermission(convId, id, approved) {
    const key = `${convId || 'main'}::${id}`;
    const p = this.pendingPermissions.get(key);
    if (!p) return;
    if (p.timer) clearTimeout(p.timer);
    this.pendingPermissions.delete(key);
    this.controlReply(p.sock, id, approved);
  }

  controlReply(sock, id, approved, message) {
    if (sock && !sock.destroyed) {
      sock.write(serialize({ type: 'permission_decision', id, approved, message }) + '\n');
    }
  }
}

// 把工具入参解析成结构化 diff，供 UI 渲染改动预览卡。
// 返回 null 表示无法结构化（UI 降级显示原始 JSON）。
function buildDiff(tool, input) {
  if (!input || typeof input !== 'object') return null;
  // 剥掉 mcp__serverName__ 前缀，只保留工具名称
  const t = tool.replace(/^mcp__[^_]+__/, '');

  if (t === 'model_edit') {
    const model = input.model || '';
    const changes = [];
    // 批量格式：edits / changes / modifications 数组
    const arr = input.edits || input.changes || input.modifications || [];
    if (Array.isArray(arr) && arr.length > 0) {
      for (const c of arr) {
        changes.push({
          block: c.block || c.blockPath || c.block_path || c.path || '',
          param: c.parameter || c.param || c.name || '',
          value: c.value != null ? String(c.value) : '',
        });
      }
    } else {
      // 单条格式
      const block = input.block || input.blockPath || input.block_path || input.path || '';
      const param = input.parameter || input.param || input.name || '';
      const value = input.value != null ? String(input.value) : '';
      if (block || param) changes.push({ block, param, value });
    }
    if (!changes.length) return null;
    return { type: 'model_edit', model, changes };
  }

  if (t === 'evaluate_matlab_code') {
    const code = input.code || input.command || input.script || '';
    return { type: 'code_exec', code };
  }

  if (t === 'run_matlab_file') {
    const file = input.file || input.path || input.filename || input.filePath || '';
    const args = typeof input.args === 'string' ? input.args : '';
    return { type: 'file_run', file, args };
  }

  if (t === 'model_test') {
    return { type: 'model_test', model: input.model || '' };
  }

  return null;
}

// 把工具入参压成一句可读的「改了什么」(审计用)。优先常见字段,否则截断 JSON。
function summarizeAction(input) {
  if (!input || typeof input !== 'object') return '';
  const keys = ['block', 'blockPath', 'block_path', 'path', 'parameter', 'param', 'name', 'value', 'model', 'file', 'code', 'command', 'script'];
  const parts = [];
  for (const k of keys) {
    const v = input[k];
    if (v != null && typeof v !== 'object') parts.push(`${k}=${String(v).replace(/\s+/g, ' ').slice(0, 80)}`);
  }
  if (parts.length) return parts.join(' · ');
  const s = JSON.stringify(input);
  return s.length > 140 ? s.slice(0, 140) + '…' : s;
}

// 审计落盘:按天追加 JSONL 到 ~/.matlab-copilot/audit-YYYY-MM-DD.jsonl(持久留痕、可追溯)。
function writeAuditLine(entry) {
  try {
    const dir = path.join(os.homedir(), '.matlab-copilot');
    fs.mkdirSync(dir, { recursive: true });
    const day = String(entry.time).slice(0, 10);
    fs.appendFileSync(path.join(dir, `audit-${day}.jsonl`), JSON.stringify(entry) + '\n');
  } catch {}
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
}
