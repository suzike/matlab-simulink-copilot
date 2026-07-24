import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { InMsg, OutMsg, serialize, createLineBuffer, parseLine } from './protocol.js';
import { isReadonlyTool, isAutoEditableTool, isSafeIntrospection, INSERT_SYSTEM_PROMPT } from './config.js';
import { getCapabilities, resolveSlashCommand } from './capabilities.js';
import { ProjectChangeRecorder } from './projectChangeRecorder.js';

function normalizeConvId(value) {
  const id = String(value || 'main');
  return /^[A-Za-z0-9_-]{1,96}$/.test(id) ? id : 'main';
}

/**
 * sidecar 的网络层:
 *  - clientServer(clientPort):UI/MATLAB 连接。转发后端事件,接收用户消息。
 *  - controlServer(controlPort):权限确认 MCP(permissionServer)回连。
 *    收到工具确认请求 → 只读自动放行,其余转发给 UI 等用户点确认。
 *
 * 单 UI 客户端(侧边栏面板)即可满足 v1。
 */
export class Server {
  constructor({ makeAdapter, config, cwd, host, clientPort, controlPort,
    transactionPrepareTimeoutMs = 15000, permissionTimeoutMs = 180000,
    onClientDisconnect = null }) {
    this.makeAdapter = makeAdapter;
    this.config = config || {};      // 默认/全局配置 {backend,model,effort,mode}
    this.cwd = cwd || process.cwd();
    this.host = host;
    this.clientPort = clientPort;
    this.controlPort = controlPort;
    this.transactionPrepareTimeoutMs = transactionPrepareTimeoutMs;
    this.permissionTimeoutMs = permissionTimeoutMs;
    this.onClientDisconnect = onClientDisconnect;
    this.convs = new Map();          // convId -> 会话状态 {convId,config,adapter,compacting,compactBuf,seed}
    this.client = null;              // 当前 UI socket
    this.pendingPermissions = new Map(); // reqId -> { sock, convId }
    this.pendingPreparations = new Map(); // auto-edit requests waiting for MATLAB checkpoint ack
    this.audit = [];                 // 操作审计轨迹(破坏性工具调用留痕)
    this._clientServer = null;
    this._controlServer = null;
    this.changeRecorder = new ProjectChangeRecorder({ root: this.cwd });
    this.changeRecorder.on('change', (entry) => this.toClient({ type: OutMsg.PROJECT_CHANGE, entry }));
    this.changeRecorder.on('state', (state) => this.toClient({ type: OutMsg.CHANGE_RECORDER_STATE, state }));
    this.changeRecorder.on('warning', (warning) => this.toClient({
      type: OutMsg.STATUS, text: `模型变更记录器: ${warning.message}`,
    }));
  }

  // 取/建一个会话(标签页/分支)。convId 缺省为 'main';新会话可带初始配置(每页独立配置)。
  ensureConv(convId, config) {
    convId = normalizeConvId(convId);
    let c = this.convs.get(convId);
    if (c) return c;
    c = { convId, config: { ...this.config, ...(config || {}) }, adapter: null,
          compacting: false, compactBuf: '', seed: null, ready: Promise.resolve(),
          generation: 0, dispatchEpoch: 0, closed: false };
    c.adapter = this.makeAdapter({ ...c.config, convId });
    this.wireConv(c, c.adapter);
    this.convs.set(convId, c);
    c.ready = Promise.resolve(c.adapter.start()).catch((e) =>
      this.toClient({ type: OutMsg.ERROR, convId, message: '后端启动失败: ' + (e?.message || e) }));
    return c;
  }

  getConv(convId, initialConfig) {
    convId = normalizeConvId(convId);
    return this.convs.get(convId) || this.ensureConv(convId, initialConfig);
  }

  wireConv(c, adapter) {
    adapter.on('event', (uiMsg) => {
      if (!c.closed && c.adapter === adapter) this.onAdapterEvent(c, uiMsg);
    });
    adapter.on('error', (err) => {
      if (!c.closed && c.adapter === adapter) {
        this.toClient({ type: OutMsg.ERROR, convId: c.convId, message: String(err?.message || err) });
      }
    });
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
        const e = this.audit.find((a) => a.id === uiMsg.id && a.convId === c.convId);
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
  applyConfig(convId, partial) {
    convId = normalizeConvId(convId);
    if (!this.convs.has(convId)) {
      // 新标签第一次动作就是切模式/后端时，直接按完整 UI 配置创建；不要先造默认
      // adapter 再异步重建，否则紧随其后的首条消息可能落到默认后端。
      const c = this.ensureConv(convId, partial);
      this.toClient({ type: OutMsg.CONFIG_CHANGED, convId: c.convId, config: c.config });
      return c.ready;
    }
    const c = this.getConv(convId);
    this.denyPendingPermissions((p) => p.convId === convId, '会话配置已变更，旧权限请求已拒绝');
    c.config = { ...c.config, ...(partial || {}) };
    // 切后端会换掉 adapter,正在进行的 /compact 那次 RESULT 不会再来 → 清压缩中间态,避免会话永久卡在 compacting。
    c.compacting = false; c.compactBuf = '';
    const generation = ++c.generation;
    const previousReady = c.ready || Promise.resolve();
    c.ready = Promise.resolve(previousReady).then(async () => {
      if (c.closed || c.generation !== generation) return;
      const old = c.adapter;
      try { await old?.stop(); } catch {}
      if (c.closed || c.generation !== generation) return;
      const next = this.makeAdapter({ ...c.config, convId: c.convId });
      c.adapter = next;
      this.wireConv(c, next);
      try { await next.start(); } catch (e) {
        this.toClient({ type: OutMsg.ERROR, convId: c.convId, message: '切换后端失败: ' + (e?.message || e) });
      }
      if (c.closed || c.generation !== generation) {
        try { await next.stop(); } catch {}
        return;
      }
      this.toClient({ type: OutMsg.CONFIG_CHANGED, convId: c.convId, config: c.config });
    });
    return c.ready;
  }

  async closeConv(convId) {
    convId = normalizeConvId(convId);
    const c = this.convs.get(convId);
    this.denyPendingPermissions((p) => p.convId === convId, '会话已关闭，操作已自动拒绝');
    if (c) {
      c.closed = true;
      c.generation += 1;
      c.dispatchEpoch += 1;
      this.convs.delete(convId);
      try { await c.ready; } catch {}
      try { await c.adapter?.stop(); } catch {}
    }
  }

  denyPendingPermissions(predicate, message) {
    for (const [key, p] of this.pendingPermissions) {
      if (!predicate(p)) continue;
      if (p.timer) clearTimeout(p.timer);
      this.pendingPermissions.delete(key);
      this.controlReply(p.sock, p.id, false, message);
    }
    for (const [key, p] of this.pendingPreparations) {
      if (!predicate(p)) continue;
      if (p.timer) clearTimeout(p.timer);
      this.pendingPreparations.delete(key);
      this.controlReply(p.sock, p.id, false, message);
    }
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
    this.denyPendingPermissions(() => true, 'Sidecar is stopping; operation denied.');
    await this.changeRecorder.stop();
    for (const c of this.convs.values()) {
      c.closed = true; c.generation += 1;
      c.dispatchEpoch += 1;
      try { await c.ready; } catch {}
      try { await c.adapter.stop(); } catch {}
    }
    this._clientServer?.close();
    this._controlServer?.close();
  }

  // ── UI 客户端 ───────────────────────────────────────────────────────────
  onClient(sock) {
    sock.setEncoding('utf8');
    this.client = sock;
    const feed = createLineBuffer((line) => this.handleClientLine(line));
    sock.on('data', feed);
    sock.on('close', () => {
      const wasActiveClient = this.client === sock;
      if (wasActiveClient) {
        this.client = null;
        this.denyPendingPermissions(() => true, '面板已断开，操作已自动拒绝');
      }
      for (const [key, p] of this.pendingPreparations) {
        if (p.sock === sock) {
          if (p.timer) clearTimeout(p.timer);
          this.pendingPreparations.delete(key);
        }
      }
      if (wasActiveClient && this.onClientDisconnect) {
        Promise.resolve().then(() => this.onClientDisconnect()).catch(() => {});
      }
    });
    sock.on('error', () => {});
    this.toClient({ type: OutMsg.READY });
    this.toClient({ type: OutMsg.CHANGE_RECORDER_STATE, state: this.changeRecorder.status() });
  }

  handleClientLine(line) {
    const msg = parseLine(line);
    if (!msg) return;
    switch (msg.type) {
      case InMsg.PING:
        this.toClient({ type: OutMsg.PONG });
        break;
      case InMsg.USER_MESSAGE: {
        // 新标签/Fork 的首条消息携带 UI 中继承的完整配置；创建 adapter 前原子合并，
        // 避免先 SET_CONFIG 再 USER_MESSAGE 时异步重建尚未完成而落到默认后端。
        const c = this.getConv(msg.convId, msg.config);
        // insert_at_cursor 模式:用「只产出代码」的系统提示覆盖本轮。
        const systemPrompt = msg.intent === 'insert_at_cursor' ? INSERT_SYSTEM_PROMPT : undefined;
        let context = msg.context;
        if (msg.attachments) {
          const incoming = Array.isArray(msg.attachments) ? msg.attachments : [msg.attachments];
          const existing = Array.isArray(context?.attachments)
            ? context.attachments
            : (context?.attachments ? [context.attachments] : []);
          context = { ...(context || {}), attachments: [...existing, ...incoming] };
        }
        if (c.seed) { context = { ...(context || {}), compactSummary: c.seed }; c.seed = null; }
        const ready = c.ready || Promise.resolve();
        const dispatchEpoch = c.dispatchEpoch;
        Promise.resolve(ready)
          .then(() => {
            if (!c.closed && c.dispatchEpoch === dispatchEpoch) {
              return c.adapter.sendMessage({ text: msg.text, context, systemPrompt });
            }
            return undefined;
          })
          .catch((e) => this.toClient({ type: OutMsg.ERROR, convId: c.convId,
            message: '发送消息失败: ' + (e?.message || e) }));
        break;
      }
      case InMsg.INTERRUPT: {
        const c = this.getConv(msg.convId);
        c.dispatchEpoch += 1; // 取消仍在等待配置重建完成的消息/斜杠命令
        Promise.resolve(c.ready).then(() => { if (!c.closed) c.adapter.interrupt(); });
        break;
      }
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
      case InMsg.CHANGE_RECORDER_CONTROL:
        this.handleChangeRecorder(msg.action, msg.projectRoot, msg.task);
        break;
      case InMsg.CHANGE_RECORDER_ENTRY:
        try { this.changeRecorder.addExternalEntry(msg.entry); }
        catch (error) { this.toClient({ type: OutMsg.ERROR, message: `模型变更记录写入失败: ${error?.message || error}` }); }
        break;
      case InMsg.CHANGE_RECORDER_ENRICH:
        try { this.changeRecorder.enrichEntry(msg.id, msg.sequence, msg.semantic); }
        catch (error) { this.toClient({ type: OutMsg.ERROR, message: `模型变更语义写入失败: ${error?.message || error}` }); }
        break;
      case InMsg.TRANSACTION_READY:
        this.resolveTransactionPreparation(msg.convId, msg.id, msg.ready === true);
        break;
      default:
        break;
    }
  }

  handleChangeRecorder(action, projectRoot, task) {
    Promise.resolve().then(async () => {
      let state;
      switch (action) {
        case 'start': state = await this.changeRecorder.start(projectRoot, task); break;
        case 'stop': state = await this.changeRecorder.stop(); break;
        case 'configure': state = this.changeRecorder.configureTask(task); break;
        case 'approve':
          if (task && Object.keys(task).length) this.changeRecorder.configureTask(task);
          state = this.changeRecorder.transitionWorkflow('approve');
          break;
        case 'execute': state = this.changeRecorder.transitionWorkflow('execute'); break;
        case 'validate': state = this.changeRecorder.transitionWorkflow('validate'); break;
        case 'export': {
          const report = await this.changeRecorder.exportReport();
          this.toClient({ type: OutMsg.CHANGE_REPORT, report });
          state = this.changeRecorder.status();
          break;
        }
        case 'status':
        default: state = this.changeRecorder.status(); break;
      }
      this.toClient({ type: OutMsg.CHANGE_RECORDER_STATE, state });
    }).catch((error) => this.toClient({
      type: OutMsg.ERROR, message: `模型变更记录器失败: ${error?.message || error}`,
    }));
  }

  handleSlash(msg) {
    const c = this.getConv(msg.convId, msg.config);
    const ready = c.ready || Promise.resolve();
    const dispatchEpoch = c.dispatchEpoch;
    Promise.resolve(ready).then(() => {
      if (c.closed || c.dispatchEpoch !== dispatchEpoch) return;
      const name = msg.name || '';
      if (name === '/compact') {
        // 真压缩:生成摘要(用户可见)→ 本轮结束后重置会话 → 摘要播种下一轮(见 onAdapterEvent)。
        c.compacting = true;
        c.compactBuf = '';
        return c.adapter.sendMessage({
          text: '请用要点总结我们到目前为止的对话:关键决策、约束、已完成、待办。控制在 300 字内。',
          context: msg.context,
        });
      }
      const cmd = resolveSlashCommand(name, this.cwd);
      if (cmd && cmd.kind === 'custom') {
        // 约定:命令体含 $ARGUMENTS 则替换为用户参数,否则把参数附在末尾。
        let text = cmd.body;
        if (/\$ARGUMENTS/.test(text)) text = text.replace(/\$ARGUMENTS/g, msg.args || '');
        else if (msg.args) text += '\n\n' + msg.args;
        return c.adapter.sendMessage({ text, context: msg.context });
      }
      // 其余内置命令(/model /mode /clear 等)由 UI 端直接处理(set_config / 本地动作)。
      return undefined;
    }).catch((e) => this.toClient({ type: OutMsg.ERROR, convId: c.convId,
      message: '斜杠命令失败: ' + (e?.message || e) }));
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
      for (const [key, p] of this.pendingPreparations) {
        if (p.sock === sock) {
          if (p.timer) clearTimeout(p.timer);
          this.pendingPreparations.delete(key);
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
    const convId = normalizeConvId(msg.convId);
    const mode = (this.convs.get(convId)?.config || this.config).mode;

    // 只读工具,或只读文档自省(help/which/exist/lookfor,文档兜底用):自动放行。
    if (isReadonlyTool(tool) || isSafeIntrospection(tool, input)) {
      this.controlReply(sock, id, true);
      return;
    }
    // 「自动」编辑模式:改模型/写文件自动放行;"运行代码/跑测试/执行 shell"仍需确认。
    if (mode === 'auto' && isAutoEditableTool(tool)) {
      if (this.changeRecorder.active && this.changeRecorder.workflow.stage !== 'executing') {
        this.controlReply(sock, id, false,
          `变更记录器当前处于 ${this.changeRecorder.workflow.stage} 阶段，请先确认范围并进入执行阶段。`);
        return;
      }
      if (!this.client || this.client.destroyed) {
        this.controlReply(sock, id, false, 'Panel is unavailable; transaction checkpoint was not created.');
        return;
      }
      const key = `${convId}::${id}`;
      const timer = setTimeout(() => {
        if (!this.pendingPreparations.has(key)) return;
        this.pendingPreparations.delete(key);
        this.controlReply(sock, id, false, 'Transaction checkpoint timed out.');
      }, this.transactionPrepareTimeoutMs);
      if (timer.unref) timer.unref();
      this.pendingPreparations.set(key, { sock, id, convId, timer });
      this.toClient({ type: OutMsg.TRANSACTION_PREPARE, convId, id, tool, input });
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
    const existing = this.pendingPermissions.get(key);
    if (existing) {
      if (existing.timer) clearTimeout(existing.timer);
      this.controlReply(existing.sock, existing.id, false, 'A newer permission request replaced this request.');
      this.pendingPermissions.delete(key);
    }
    const timer = setTimeout(() => {
      if (this.pendingPermissions.has(key)) {
        this.pendingPermissions.delete(key);
        this.controlReply(sock, id, false, '确认超时，已自动拒绝');
      }
    }, this.permissionTimeoutMs);
    if (timer.unref) timer.unref();   // 不阻止进程退出
    this.pendingPermissions.set(key, { sock, id, convId, timer });
    const diff = buildDiff(tool, input);
    this.toClient({ type: OutMsg.PERMISSION_REQUEST, convId, id, tool, input, destructive: true, diff });
  }

  resolvePermission(convId, id, approved) {
    const key = `${normalizeConvId(convId)}::${id}`;
    const p = this.pendingPermissions.get(key);
    if (!p) return;
    if (p.timer) clearTimeout(p.timer);
    this.pendingPermissions.delete(key);
    this.controlReply(p.sock, id, approved);
  }

  resolveTransactionPreparation(convId, id, ready) {
    const key = `${normalizeConvId(convId)}::${id}`;
    const p = this.pendingPreparations.get(key);
    if (!p) return;
    if (p.timer) clearTimeout(p.timer);
    this.pendingPreparations.delete(key);
    this.controlReply(p.sock, p.id, ready, ready ? undefined : 'MATLAB transaction checkpoint failed.');
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
    if (v != null && typeof v !== 'object') parts.push(`${k}=${redactAuditValue(k, v)}`);
  }
  if (parts.length) return parts.join(' · ');
  const s = JSON.stringify(redactAuditObject(input));
  return s.length > 140 ? s.slice(0, 140) + '…' : s;
}

const AUDIT_CODE_FIELDS = new Set(['code', 'command', 'matlab_code', 'matlabCode', 'expression', 'script', 'input']);
const SENSITIVE_KEY_RE = /(api[_-]?key|token|secret|authorization|auth|cookie|password|passwd|pwd|credential|app[_-]?secret)/i;
const SENSITIVE_VALUE_RE = /\b(sk-[A-Za-z0-9_-]{12,}|sk-proj-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]+=*|Authorization\s*:\s*\S+)\b/gi;

function redactAuditValue(key, value) {
  const s = String(value).replace(/\s+/g, ' ');
  if (AUDIT_CODE_FIELDS.has(key)) return `[已脱敏:${key},${s.length} chars]`;
  if (SENSITIVE_KEY_RE.test(key)) return '[已脱敏]';
  const redacted = s.replace(SENSITIVE_VALUE_RE, '[已脱敏]');
  return redacted.slice(0, 80);
}

function redactAuditObject(value) {
  if (Array.isArray(value)) return value.map(redactAuditObject);
  if (!value || typeof value !== 'object') return value;
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (SENSITIVE_KEY_RE.test(k)) out[k] = '[已脱敏]';
    else if (AUDIT_CODE_FIELDS.has(k) && typeof v === 'string') out[k] = `[已脱敏:${k},${v.length} chars]`;
    else if (typeof v === 'string') out[k] = v.replace(SENSITIVE_VALUE_RE, '[已脱敏]');
    else out[k] = redactAuditObject(v);
  }
  return out;
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
