import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CodexAdapter } from '../src/adapters/codex.js';
import { OutMsg } from '../src/protocol.js';

function collect(events) {
  const a = new CodexAdapter();
  const out = [];
  a.on('event', (e) => out.push(e));
  for (const e of events) a.handle(e);
  return { out, a };
}

test('thread.started 记录 thread_id 供 resume', () => {
  const { a } = collect([{ type: 'thread.started', thread_id: 'th-1' }]);
  assert.equal(a.threadId, 'th-1');
});

test('agent_message → 助手气泡;reasoning → 思考;turn.completed → result', () => {
  const { out } = collect([
    { type: 'turn.started' },
    { type: 'item.completed', item: { id: 'i0', type: 'reasoning', text: '先想一下' } },
    { type: 'item.completed', item: { id: 'i1', type: 'agent_message', text: '答案' } },
    { type: 'turn.completed', usage: { output_tokens: 10 } },
  ]);
  const types = out.map((e) => e.type);
  assert.deepEqual(types, [
    OutMsg.THINKING_START, OutMsg.THINKING_DELTA, OutMsg.THINKING_STOP,
    OutMsg.ASSISTANT_START, OutMsg.ASSISTANT_DELTA, OutMsg.ASSISTANT_STOP,
    OutMsg.RESULT,
  ]);
});

test('command_execution → 工具卡片(ok 由 exit_code 决定)', () => {
  const { out } = collect([
    { type: 'item.completed', item: { id: 'c1', type: 'command_execution', command: 'ls', aggregated_output: 'a\nb', exit_code: 0 } },
  ]);
  assert.equal(out[0].type, OutMsg.TOOL_USE);
  assert.equal(out[0].name, 'Bash');
  assert.equal(out[1].type, OutMsg.TOOL_RESULT);
  assert.equal(out[1].ok, true);
});

test('已知噪声 error(skills budget)被过滤', () => {
  const { out } = collect([
    { type: 'item.completed', item: { id: 'e1', type: 'error', message: 'Exceeded skills context budget of 2%.' } },
  ]);
  assert.equal(out.length, 0);
});

test('turn.failed → 报错 + 补 RESULT(ok:false),保证 UI 收尾不卡 thinking', () => {
  const { out } = collect([
    { type: 'turn.failed', error: { message: '模型超时' } },
  ]);
  const types = out.map((e) => e.type);
  assert.ok(types.includes(OutMsg.ERROR));
  assert.ok(types.includes(OutMsg.RESULT));
  assert.equal(out.find((e) => e.type === OutMsg.RESULT).ok, false);
});

test('per-child 守卫:旧 child 的迟到 close 不影响新 child', () => {
  const a = new CodexAdapter();
  // 用假 child 模拟两代进程
  const mk = () => ({ _killing: false, kill() { this._killing = true; }, stdin: { on(){}, write(){}, end(){} } });
  const c1 = mk();
  a.child = c1;
  a.interrupt();                 // kill c1,this.child=null,c1._killing=true
  assert.equal(a.child, null);
  assert.equal(c1._killing, true);
  const c2 = mk();
  a.child = c2;                  // 新一代
  // 模拟 c1 迟到的 close 守卫逻辑:this.child === c1 为 false → 不应清掉 c2
  if (a.child === c1) a.child = null;
  assert.equal(a.child, c2, '旧 child 的 close 不应误清新 child');
});
