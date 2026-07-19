import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { Server } from '../src/server.js';
import { EchoAdapter } from '../src/adapters/echo.js';
import { BackendAdapter } from '../src/adapters/types.js';
import { OutMsg, InMsg, serialize, createLineBuffer, parseLine } from '../src/protocol.js';
import { isSafeIntrospection } from '../src/config.js';

// 连一个 TCP 客户端,收集到第一个满足 predicate 的消息。
function connectClient(port) {
  const sock = net.createConnection({ host: '127.0.0.1', port });
  sock.setEncoding('utf8');
  const msgs = [];
  const waiters = [];
  const feed = createLineBuffer((line) => {
    const m = parseLine(line);
    if (!m) return;
    msgs.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(m)) { waiters.splice(i, 1)[0].resolve(m); }
    }
  });
  sock.on('data', feed);
  return {
    sock,
    send: (o) => sock.write(serialize(o) + '\n'),
    waitFor: (pred) => new Promise((resolve) => {
      const hit = msgs.find(pred);
      if (hit) return resolve(hit);
      waiters.push({ pred, resolve });
    }),
    all: msgs,
    close: () => sock.destroy(),
  };
}

test('EchoAdapter 全链路:user_message → 流式 delta → result', async () => {
  const server = new Server({ makeAdapter: () => new EchoAdapter({ delayMs: 1 }), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const c = connectClient(clientPort);

  await c.waitFor((m) => m.type === OutMsg.READY);
  c.send({ type: InMsg.USER_MESSAGE, id: 'u1', text: '你好', context: { currentModel: 'demo' } });

  await c.waitFor((m) => m.type === OutMsg.ASSISTANT_START);
  const result = await c.waitFor((m) => m.type === OutMsg.RESULT);
  assert.equal(result.ok, true);

  const text = c.all.filter((m) => m.type === OutMsg.ASSISTANT_DELTA).map((m) => m.text).join('');
  assert.match(text, /你好/);

  c.close();
  await server.stop();
});

test('ping/pong', async () => {
  const server = new Server({ makeAdapter: () => new EchoAdapter({ delayMs: 1 }), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const c = connectClient(clientPort);
  await c.waitFor((m) => m.type === OutMsg.READY);
  c.send({ type: InMsg.PING });
  await c.waitFor((m) => m.type === OutMsg.PONG);
  c.close();
  await server.stop();
});

test('USER_MESSAGE 顶层 attachments 会合并进 context.attachments', async () => {
  let captured;
  class CaptureAdapter extends BackendAdapter {
    async sendMessage(payload) {
      captured = payload;
      this.emitEvent({ type: OutMsg.RESULT, id: null, ok: true, text: '', costUsd: 0 });
    }
  }
  const server = new Server({ makeAdapter: () => new CaptureAdapter(), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const c = connectClient(clientPort);
  await c.waitFor((m) => m.type === OutMsg.READY);

  c.send({
    type: InMsg.USER_MESSAGE,
    id: 'u-attach',
    text: '看图',
    context: { currentModel: 'demo' },
    attachments: [{ name: 'demo.png', path: 'C:/tmp/demo.png', isImage: true }],
  });
  await c.waitFor((m) => m.type === OutMsg.RESULT);

  assert.equal(captured.context.currentModel, 'demo');
  assert.equal(captured.context.attachments[0].name, 'demo.png');
  assert.equal(captured.context.attachments[0].path, 'C:/tmp/demo.png');

  c.close();
  await server.stop();
});

test('新会话首条消息在创建 adapter 前应用其完整配置', async () => {
  const states = new Map();
  class CaptureAdapter extends BackendAdapter {
    async sendMessage() {
      this.emitEvent({ type: OutMsg.RESULT, id: null, ok: true, text: '', costUsd: 0 });
    }
  }
  const server = new Server({
    makeAdapter: (state) => { states.set(state.convId, state); return new CaptureAdapter(); },
    config: { backend: 'claude', model: 'default', effort: 'medium', mode: 'ask' },
    host: '127.0.0.1', clientPort: 0, controlPort: 0,
  });
  const { clientPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);

  ui.send({ type: InMsg.USER_MESSAGE, convId: 'fork-config', id: 'u-config', text: 'hi',
    config: { backend: 'codex', model: 'gpt-5', effort: 'high', mode: 'plan' } });
  await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 'fork-config');

  assert.deepEqual(
    { backend: states.get('fork-config').backend, model: states.get('fork-config').model,
      effort: states.get('fork-config').effort, mode: states.get('fork-config').mode },
    { backend: 'codex', model: 'gpt-5', effort: 'high', mode: 'plan' },
  );

  ui.send({ type: InMsg.SLASH_COMMAND, convId: 'slash-config', name: '/compact', args: '',
    config: { backend: 'codex', model: 'gpt-5-mini', effort: 'low', mode: 'auto' }, context: {} });
  await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 'slash-config');
  assert.deepEqual(
    { backend: states.get('slash-config').backend, model: states.get('slash-config').model,
      effort: states.get('slash-config').effort, mode: states.get('slash-config').mode },
    { backend: 'codex', model: 'gpt-5-mini', effort: 'low', mode: 'auto' },
  );

  ui.send({ type: InMsg.SET_CONFIG, convId: 'set-first',
    config: { backend: 'codex', model: 'gpt-5', effort: 'medium', mode: 'plan' } });
  const changed = await ui.waitFor((m) => m.type === OutMsg.CONFIG_CHANGED && m.convId === 'set-first');
  assert.equal(changed.config.mode, 'plan');
  assert.deepEqual(
    { backend: states.get('set-first').backend, model: states.get('set-first').model,
      effort: states.get('set-first').effort, mode: states.get('set-first').mode },
    { backend: 'codex', model: 'gpt-5', effort: 'medium', mode: 'plan' },
  );
  ui.close();
  await server.stop();
});

test('配置重建期间消息等待新 adapter；中断可取消等待派发且旧事件被丢弃', async () => {
  const sent = [];
  const adapters = [];
  class TrackingAdapter extends BackendAdapter {
    constructor(state) { super(); this.mode = state.mode; adapters.push(this); }
    async stop() { await new Promise((r) => setTimeout(r, 20)); }
    async sendMessage(payload) {
      sent.push({ mode: this.mode, text: payload.text });
      this.emitEvent({ type: OutMsg.RESULT, id: null, ok: true, text: '', costUsd: 0 });
    }
    interrupt() { this.interrupted = true; }
  }
  const server = new Server({
    makeAdapter: (state) => new TrackingAdapter(state),
    config: { backend: 'x', mode: 'ask' },
    host: '127.0.0.1', clientPort: 0, controlPort: 0,
  });
  const { clientPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  const old = adapters[0];

  ui.send({ type: InMsg.SET_CONFIG, convId: 'main', config: { mode: 'auto' } });
  ui.send({ type: InMsg.USER_MESSAGE, convId: 'main', id: 'race-1', text: 'use-new' });
  await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 'main');
  assert.deepEqual(sent, [{ mode: 'auto', text: 'use-new' }]);

  old.emitEvent({ type: OutMsg.ASSISTANT_DELTA, id: 'late-old', text: 'late-old' });
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(ui.all.some((m) => m.id === 'late-old'), false);

  ui.send({ type: InMsg.SET_CONFIG, convId: 'main', config: { mode: 'plan' } });
  ui.send({ type: InMsg.USER_MESSAGE, convId: 'main', id: 'race-2', text: 'cancel-me' });
  ui.send({ type: InMsg.INTERRUPT, convId: 'main' });
  await ui.waitFor((m) => m.type === OutMsg.CONFIG_CHANGED && m.convId === 'main' && m.config.mode === 'plan');
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(sent.some((x) => x.text === 'cancel-me'), false);
  assert.equal(adapters.at(-1).interrupted, true);

  ui.close();
  await server.stop();
});

test('权限路由:只读自动放行,破坏性转发 UI 并由响应解决', async () => {
  const server = new Server({ makeAdapter: () => new BackendAdapter(), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);

  // 模拟 permissionServer 回连控制端口。
  const ctrl = connectClient(controlPort);

  // 1) 只读工具 → 自动 allow,UI 不应收到 permission_request。
  ctrl.send({ type: 'permission_request', id: 'p1', tool: 'mcp__matlab__model_read', input: {} });
  const d1 = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'p1');
  assert.equal(d1.approved, true);

  // 2) 破坏性工具 → 转给 UI,UI 拒绝 → 控制端口收到 deny。
  ctrl.send({ type: 'permission_request', id: 'p2', tool: 'mcp__matlab__model_edit', input: { block: 'Gain' } });
  const req = await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'p2');
  assert.equal(req.destructive, true);
  assert.equal(req.tool, 'mcp__matlab__model_edit');
  ui.send({ type: InMsg.PERMISSION_RESPONSE, id: 'p2', approved: false });
  const d2 = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'p2');
  assert.equal(d2.approved, false);

  ui.close();
  ctrl.close();
  await server.stop();
});

test('自动模式:改模型自动放行,但运行代码仍需确认', async () => {
  const server = new Server({ makeAdapter: () => new BackendAdapter(), config: { mode: 'auto' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  const ctrl = connectClient(controlPort);
  // 1) 改模型(编辑类)→ 自动放行,不弹卡片。
  ctrl.send({ type: 'permission_request', id: 'pa', tool: 'mcp__matlab__model_edit', input: { block: 'Gain' } });
  const prepare = await ui.waitFor((m) => m.type === OutMsg.TRANSACTION_PREPARE && m.id === 'pa');
  assert.equal(prepare.tool, 'mcp__matlab__model_edit');
  ui.send({ type: InMsg.TRANSACTION_READY, id: 'pa', ready: true });
  const d = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'pa');
  assert.equal(d.approved, true);
  // 2) 运行代码(执行类)→ 仍转发 UI 确认。
  ctrl.send({ type: 'permission_request', id: 'pe', tool: 'mcp__matlab__run_matlab_file', input: {} });
  const req = await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'pe');
  assert.equal(req.tool, 'mcp__matlab__run_matlab_file');
  ui.send({ type: InMsg.PERMISSION_RESPONSE, id: 'pe', approved: true });
  const de = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'pe');
  assert.equal(de.approved, true);
  // Unknown tools are not edits: Auto must fail closed and ask the user.
  ctrl.send({ type: 'permission_request', id: 'pu', tool: 'mcp__matlab__future_unknown_tool', input: {} });
  await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'pu');
  ui.send({ type: InMsg.PERMISSION_RESPONSE, id: 'pu', approved: false });
  const du = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'pu');
  assert.equal(du.approved, false);
  assert.equal(ui.all.filter((m) => m.type === OutMsg.PERMISSION_REQUEST).length, 2);
  ui.close();
  ctrl.close();
  await server.stop();
});

test('计划模式:破坏性工具强制拒绝,不弹 UI 确认', async () => {
  const server = new Server({ makeAdapter: () => new BackendAdapter(), config: { mode: 'plan' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  const ctrl = connectClient(controlPort);
  // 只读工具在 plan 模式下仍放行(探索需要)。
  ctrl.send({ type: 'permission_request', id: 'pr', tool: 'mcp__matlab__model_read', input: {} });
  const dr = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'pr');
  assert.equal(dr.approved, true);
  // 破坏性工具一律拒绝,且不弹卡片。
  ctrl.send({ type: 'permission_request', id: 'pe', tool: 'mcp__matlab__model_edit', input: { block: 'Gain' } });
  const de = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'pe');
  assert.equal(de.approved, false);
  assert.equal(ui.all.some((m) => m.type === OutMsg.PERMISSION_REQUEST), false);
  ui.close();
  ctrl.close();
  await server.stop();
});

test('多会话:消息按 convId 路由、回包带 convId、配置各自独立、可关闭', async () => {
  const server = new Server({ makeAdapter: () => new EchoAdapter({ delayMs: 1 }), config: { backend: 'echo', mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  // 给标签页 t2 发消息 → 回包带 convId=t2
  ui.send({ type: InMsg.USER_MESSAGE, id: 'u1', text: 'hi', convId: 't2' });
  const r2 = await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 't2');
  assert.equal(r2.convId, 't2');
  // 给 main 发消息 → 回包带 convId=main(各自独立的流)
  ui.send({ type: InMsg.USER_MESSAGE, id: 'u2', text: 'yo', convId: 'main' });
  const rm = await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 'main');
  assert.equal(rm.convId, 'main');
  // t2 改配置 → config_changed 带 convId=t2(每页独立配置)
  ui.send({ type: InMsg.SET_CONFIG, convId: 't2', config: { mode: 'auto' } });
  const cc = await ui.waitFor((m) => m.type === OutMsg.CONFIG_CHANGED && m.convId === 't2');
  assert.equal(cc.config.mode, 'auto');
  // 关闭 t2(main 不受影响,仍可用)
  ui.send({ type: InMsg.CLOSE_CONV, convId: 't2' });
  ui.send({ type: InMsg.USER_MESSAGE, id: 'u3', text: 'still here', convId: 'main' });
  await ui.waitFor((m) => m.type === OutMsg.RESULT && m.convId === 'main' && m !== rm);
  ui.close();
  await server.stop();
});

test('操作审计:破坏性工具留痕并随结果更新,只读不记', async () => {
  let adapter;
  const server = new Server({ makeAdapter: () => (adapter = new BackendAdapter()), config: { backend: 'x', mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  // 只读工具 → 不记审计。
  adapter.emitEvent({ type: OutMsg.TOOL_USE, id: 'r1', name: 'mcp__matlab__model_read', input: {} });
  // 破坏性工具 → 记一条(pending,待结果),action 含改了什么。
  adapter.emitEvent({ type: OutMsg.TOOL_USE, id: 'e1', name: 'mcp__matlab__model_edit', input: { block: 'Gain', value: '2' } });
  const a1 = await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'e1');
  assert.equal(a1.entry.status, 'pending');
  assert.match(a1.entry.action, /Gain/);
  // 结果回来 → 状态更新为 ok。
  adapter.emitEvent({ type: OutMsg.TOOL_RESULT, id: 'e1', ok: true });
  await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'e1' && m.entry.status === 'ok');
  // 只读那条始终不产生 audit。
  assert.equal(ui.all.filter((m) => m.type === OutMsg.AUDIT && m.entry.id === 'r1').length, 0);
  ui.close();
  await server.stop();
});

test('操作审计:动作摘要脱敏代码与凭据形态', async () => {
  let adapter;
  const server = new Server({ makeAdapter: () => (adapter = new BackendAdapter()), config: { backend: 'x', mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);

  adapter.emitEvent({
    type: OutMsg.TOOL_USE,
    id: 'secret1',
    name: 'mcp__matlab__evaluate_matlab_code',
    input: { code: "disp(getenv('OPENAI_API_KEY'))", value: 'Bearer abc.def.ghi', model: 'demo' },
  });
  const a = await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'secret1');
  assert.match(a.entry.action, /code=\[已脱敏:code,/);
  assert.doesNotMatch(a.entry.action, /OPENAI_API_KEY|Bearer abc/);

  ui.close();
  await server.stop();
});

test('操作审计:相同 tool id 按 convId 更新,不串标签页', async () => {
  const adapters = {};
  const server = new Server({
    makeAdapter: (state) => (adapters[state.convId || 'main'] = new BackendAdapter()),
    config: { backend: 'x', mode: 'ask' },
    host: '127.0.0.1',
    clientPort: 0,
    controlPort: 0,
  });
  const { clientPort } = await server.start();
  server.ensureConv('t2');
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);

  adapters.main.emitEvent({ type: OutMsg.TOOL_USE, id: 'same', name: 'mcp__matlab__model_edit', input: { block: 'A' } });
  adapters.t2.emitEvent({ type: OutMsg.TOOL_USE, id: 'same', name: 'mcp__matlab__model_edit', input: { block: 'B' } });
  await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'same' && m.entry.convId === 'main');
  await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'same' && m.entry.convId === 't2');

  adapters.t2.emitEvent({ type: OutMsg.TOOL_RESULT, id: 'same', ok: false });
  await ui.waitFor((m) => m.type === OutMsg.AUDIT && m.entry.id === 'same' && m.entry.convId === 't2' && m.entry.status === 'failed');

  const mainUpdates = ui.all.filter((m) => m.type === OutMsg.AUDIT && m.entry.id === 'same' && m.entry.convId === 'main');
  assert.equal(mainUpdates.at(-1).entry.status, 'pending');

  ui.close();
  await server.stop();
});

test('安全自省判定:只放过 help/which/exist/lookfor 只读调用,其余仍受门控', () => {
  const T = 'mcp__matlab__evaluate_matlab_code';
  // 放行(文档兜底用的只读自省)
  for (const code of ["help('tf')", 'help tf', "which('lsim')", 'which lsim', "exist('pid','file')", 'lookfor filter', "HELP('plot')"]) {
    assert.equal(isSafeIntrospection(T, { code }), true, `应放行: ${code}`);
  }
  // 拒绝(任何能改状态/跑任意代码/链式/嵌套的都不放过 → 仍走确认)
  for (const code of [
    "set_param('m/G','Gain','2')",
    "help('tf'); delete('x.m')",
    "system('rm -rf /')",
    "evalin('base','x=1')",
    "help(badcall())",
    "doc('tf')",            // doc 会弹浏览器,不在白名单
    "x = 1",
  ]) {
    assert.equal(isSafeIntrospection(T, { code }), false, `应拒绝: ${code}`);
  }
  // 非 evaluate 工具即便内容像 help 也不走此通道
  assert.equal(isSafeIntrospection('mcp__matlab__model_edit', { code: "help('tf')" }), false);
  // 多代码字段(校验对象与执行对象可能错位)→ 不放行,避免绕过自动放行门控。
  assert.equal(isSafeIntrospection(T, { code: "help('tf')", command: "delete('x.m')" }), false);
});

test('破坏性工具但无 UI 连接 → 自动拒绝', async () => {
  const server = new Server({ makeAdapter: () => new BackendAdapter(), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { controlPort } = await server.start();
  const ctrl = connectClient(controlPort);
  ctrl.send({ type: 'permission_request', id: 'p3', tool: 'mcp__matlab__run_matlab_file', input: {} });
  const d = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'p3');
  assert.equal(d.approved, false);
  ctrl.close();
  await server.stop();
});

test('control 连接断开 → 清理该连接的悬挂权限请求(防 Map 泄漏)', async () => {
  let adapter;
  const server = new Server({ makeAdapter: () => (adapter = new BackendAdapter()), config: { mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);          // UI 在线 → 破坏性工具会转发 UI 等确认
  await ui.waitFor((m) => m.type === OutMsg.READY);
  const ctrl = connectClient(controlPort);
  ctrl.send({ type: 'permission_request', id: 'pX', tool: 'mcp__matlab__model_edit', input: { block: 'G' } });
  await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'pX');
  assert.equal(server.pendingPermissions.size, 1, '请求应进入待确认表');
  ctrl.close();                                  // control 断开
  await new Promise((r) => setTimeout(r, 50));   // 等 close 事件传播
  assert.equal(server.pendingPermissions.size, 0, 'control 断开后悬挂条目应被清理');
  ui.close();
  await server.stop();
});

test('关闭会话 → 立即拒绝该会话的悬挂权限并释放 adapter', async () => {
  const adapters = new Map();
  class TrackingAdapter extends BackendAdapter {
    async stop() { this.stopped = true; }
  }
  const server = new Server({
    makeAdapter: ({ convId }) => {
      const a = new TrackingAdapter(); adapters.set(convId, a); return a;
    },
    config: { mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0,
  });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  server.ensureConv('close-me');
  const ctrl = connectClient(controlPort);
  ctrl.send({ type: 'permission_request', convId: 'close-me', id: 'p-close',
    tool: 'mcp__matlab__model_edit', input: { block: 'G' } });
  await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'p-close');

  ui.send({ type: InMsg.CLOSE_CONV, convId: 'close-me' });
  const d = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'p-close');
  assert.equal(d.approved, false);
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(server.pendingPermissions.size, 0);
  assert.equal(server.convs.has('close-me'), false);
  assert.equal(adapters.get('close-me').stopped, true);

  ctrl.close(); ui.close(); await server.stop();
});

test('UI 断开 → 立即拒绝所有悬挂权限', async () => {
  const server = new Server({ makeAdapter: () => new BackendAdapter(), config: { mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort, controlPort } = await server.start();
  const ui = connectClient(clientPort);
  await ui.waitFor((m) => m.type === OutMsg.READY);
  const ctrl = connectClient(controlPort);
  ctrl.send({ type: 'permission_request', id: 'p-disconnect', tool: 'mcp__matlab__model_edit', input: { block: 'G' } });
  await ui.waitFor((m) => m.type === OutMsg.PERMISSION_REQUEST && m.id === 'p-disconnect');
  ui.close();
  const d = await ctrl.waitFor((m) => m.type === 'permission_decision' && m.id === 'p-disconnect');
  assert.equal(d.approved, false);
  assert.equal(server.pendingPermissions.size, 0);
  ctrl.close(); await server.stop();
});
