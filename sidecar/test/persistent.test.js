import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { ClaudeCodeAdapter } from '../src/adapters/claudeCode.js';

// 用假 child 替换真实 spawn,验证常驻模式的并发/竞态修复(不真正拉起 claude)。
function makeFakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter(); child.stdout.setEncoding = () => {};
  child.stderr = new EventEmitter(); child.stderr.setEncoding = () => {};
  child.stdin = new EventEmitter();
  child.stdin.write = () => true;
  child.stdin.end = () => {};
  child.kill = () => { child._killedCalled = true; };
  return child;
}
function resultLine(sid) {
  return JSON.stringify({ type: 'result', is_error: false, result: 'done', session_id: sid }) + '\n';
}

// 常驻模式开关与参数构造(纯逻辑,不真正 spawn claude)。

test('persistent:默认关闭(走可靠的 resume 模式)', () => {
  const a = new ClaudeCodeAdapter({});
  assert.equal(a.persistent, false);
});

test('persistent:opts.persistent=true 显式开启', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  assert.equal(a.persistent, true);
});

test('buildArgs:stream=true 注入 --input-format stream-json(常驻模式)', () => {
  const a = new ClaudeCodeAdapter({});
  const args = a.buildArgs(null, { stream: true });
  const i = args.indexOf('--input-format');
  assert.ok(i >= 0 && args[i + 1] === 'stream-json', '常驻模式应带 --input-format stream-json');
});

test('buildArgs:默认(resume 模式)不带 --input-format', () => {
  const a = new ClaudeCodeAdapter({});
  const args = a.buildArgs();
  assert.equal(args.indexOf('--input-format'), -1);
});

test('buildArgs:有 sessionId 时带 --resume(常驻崩溃后续接上下文)', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  a.sessionId = 'sess-abc';
  const args = a.buildArgs(null, { stream: true });
  const i = args.indexOf('--resume');
  assert.ok(i >= 0 && args[i + 1] === 'sess-abc');
});

test('sendMessage:persistent 模式把 per-turn systemPrompt 并入消息文本', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  let captured = null;
  a.sendPersistent = (p) => { captured = p; };   // 截获分派,不真正 spawn
  a.sendMessage({ text: 'foo', systemPrompt: 'ONLY_CODE' });
  assert.ok(captured && captured.text.includes('ONLY_CODE'), 'systemPrompt 应并入消息文本');
  assert.ok(captured.text.includes('foo'));
});

test('sendMessage:非 persistent 模式走 sendOneShot 并保留 systemPrompt', () => {
  const a = new ClaudeCodeAdapter({});
  let captured = null;
  a.sendOneShot = (p) => { captured = p; };
  a.sendMessage({ text: 'foo', systemPrompt: 'ONLY_CODE' });
  assert.equal(captured.systemPrompt, 'ONLY_CODE');
});

test('resetSession:常驻模式无活动子进程时安全清空 sessionId', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  a.sessionId = 'x';
  a.resetSession();   // child 为 null → 不应抛错
  assert.equal(a.sessionId, null);
});

// ── 并发/竞态修复(C1/C2/H5/M7)──────────────────────────────────────────────
test('C1 常驻:上一轮未结束时再发被拒(busy 保护,不靠 child 判忙)', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  a.spawnChild = () => makeFakeChild();
  const events = [];
  a.on('event', (e) => events.push(e));
  a.sendPersistent({ text: 'first' });
  assert.equal(a.busy, true);
  a.sendPersistent({ text: 'second' });   // 应被拒
  const errs = events.filter((e) => e.type === 'error' && /上一轮/.test(e.message));
  assert.equal(errs.length, 1, '第二条应被 busy 保护拒绝');
});

test('C1 常驻:result 事件清 busy 并回写 sessionId', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  const fake = makeFakeChild();
  a.spawnChild = () => fake;
  a.sendPersistent({ text: 'x' });
  assert.equal(a.busy, true);
  fake.stdout.emit('data', resultLine('sess-1'));   // 模拟本轮结束
  assert.equal(a.busy, false, 'result 应清 busy');
  assert.equal(a.sessionId, 'sess-1');
});

test('M7 resetSession:在途 child 被 kill 且禁止 close 回写 session', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  const fake = makeFakeChild();
  a.spawnChild = () => fake;
  a.sendPersistent({ text: 'x' });
  a.resetSession();
  assert.equal(fake._killing, true);
  assert.equal(fake._noSession, true);
  assert.equal(a.child, null);
  assert.equal(a.busy, false);
  // 旧 child 的 close 携带 session,但 _noSession 应抑制回写
  fake.emit('close', 0);
  assert.equal(a.sessionId, null, 'reset 后 session 不应被旧进程 close 覆盖');
});

test('C2 per-child:旧 child 的异步 close 不误清/误报新 child', () => {
  const a = new ClaudeCodeAdapter({ persistent: true });
  const children = [];
  a.spawnChild = () => { const c = makeFakeChild(); children.push(c); return c; };
  const events = [];
  a.on('event', (e) => events.push(e));
  a.sendPersistent({ text: '1' });   // child0
  a.interrupt();                      // kill child0, this.child=null
  a.sendPersistent({ text: '2' });   // child1
  assert.equal(a.child, children[1], '当前应为 child1');
  assert.equal(a.busy, true);
  children[0].emit('close', 0);       // 旧 child0 迟到的 close
  assert.equal(a.child, children[1], '旧 close 不应清空新 child');
  assert.equal(a.busy, true, '旧 close 不应清新 child 的 busy');
});

test('resume 模式:上一轮收尾(child 未 close)时发新消息 → 排队,close 后自动发(不报「上一轮尚未结束」)', () => {
  const a = new ClaudeCodeAdapter({});   // 非 persistent = resume 模式
  const children = [];
  a.spawnChild = () => { const c = makeFakeChild(); children.push(c); return c; };
  const events = [];
  a.on('event', (e) => events.push(e));

  a.sendMessage({ text: 'first' });
  assert.equal(children.length, 1, '第一条 spawn 一个进程');
  assert.equal(a.child, children[0]);

  // 上一轮还没 close 就发第二条(result 已出、进程未退出)→ 应排队
  a.sendMessage({ text: 'second' });
  assert.equal(children.length, 1, '第二条不立即 spawn(排队中)');
  assert.ok(a._pending && a._pending.text === 'second', 'second 进入 _pending');
  assert.ok(!events.some((e) => e.type === 'error'), '不报「上一轮尚未结束」');

  // 第一轮进程退出 → 自动发第二条
  children[0].emit('close', 0);
  assert.equal(children.length, 2, 'close 后自动 spawn 第二条');
  assert.equal(a._pending, null, '_pending 已清');
});

test('resume 模式:主动 kill(中断)时丢弃排队,不自动发', () => {
  const a = new ClaudeCodeAdapter({});
  const children = [];
  a.spawnChild = () => { const c = makeFakeChild(); children.push(c); return c; };
  a.sendMessage({ text: 'first' });
  a.sendMessage({ text: 'queued' });
  assert.ok(a._pending);
  a.interrupt();                       // 主动中断 → child._killing=true
  children[0].emit('close', 0);
  assert.equal(a._pending, null, '中断后排队被丢弃');
  assert.equal(children.length, 1, '不自动发排队消息');
});
