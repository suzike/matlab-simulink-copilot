import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStreamTranslator, summarizeToolResult } from '../src/streamJsonParser.js';
import { OutMsg } from '../src/protocol.js';

// 把一组 stream-json 对象喂给 translator,收集所有 UI 事件。
function run(objs) {
  const t = createStreamTranslator();
  const events = [];
  for (const o of objs) events.push(...t.handle(o));
  return { events, sessionId: t.getSessionId() };
}

test('partial 模式:逐 token 流式文本', () => {
  const { events, sessionId } = run([
    { type: 'system', subtype: 'init', session_id: 'sess-1', tools: [] },
    { type: 'stream_event', event: { type: 'message_start', message: {} } },
    { type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '你好' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: ',世界' } } },
    { type: 'stream_event', event: { type: 'message_stop' } },
    // 完整 assistant 消息(partial 模式下文本应被忽略,避免重复)
    { type: 'assistant', message: { id: 'msg_1', role: 'assistant', content: [{ type: 'text', text: '你好,世界' }] } },
    { type: 'result', subtype: 'success', is_error: false, result: '你好,世界', session_id: 'sess-1', total_cost_usd: 0.01 },
  ]);

  assert.equal(sessionId, 'sess-1');
  const types = events.map((e) => e.type);
  assert.deepEqual(types, [
    OutMsg.ASSISTANT_START,
    OutMsg.ASSISTANT_DELTA,
    OutMsg.ASSISTANT_DELTA,
    OutMsg.ASSISTANT_STOP,
    OutMsg.RESULT,
  ]);
  const text = events.filter((e) => e.type === OutMsg.ASSISTANT_DELTA).map((e) => e.text).join('');
  assert.equal(text, '你好,世界');
  const result = events.at(-1);
  assert.equal(result.ok, true);
  assert.equal(result.costUsd, 0.01);
});

test('非 partial 模式:文本从完整 assistant 消息一次性给出', () => {
  const { events } = run([
    { type: 'system', subtype: 'init', session_id: 'sess-2' },
    { type: 'assistant', message: { id: 'msg_1', role: 'assistant', content: [{ type: 'text', text: 'Hello' }] } },
    { type: 'result', subtype: 'success', is_error: false, result: 'Hello' },
  ]);
  const types = events.map((e) => e.type);
  assert.deepEqual(types, [
    OutMsg.ASSISTANT_START,
    OutMsg.ASSISTANT_DELTA,
    OutMsg.ASSISTANT_STOP,
    OutMsg.RESULT,
  ]);
  assert.equal(events[1].text, 'Hello');
});

test('工具调用:tool_use 来自完整消息且 input 完整,tool_result 配对', () => {
  const { events } = run([
    { type: 'system', subtype: 'init', session_id: 's' },
    { type: 'stream_event', event: { type: 'message_start', message: {} } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '我来读模型' } } },
    { type: 'stream_event', event: { type: 'message_stop' } },
    {
      type: 'assistant',
      message: {
        id: 'msg_1',
        role: 'assistant',
        content: [
          { type: 'text', text: '我来读模型' },
          { type: 'tool_use', id: 'toolu_1', name: 'model_overview', input: { model: 'foo' } },
        ],
      },
    },
    {
      type: 'user',
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'toolu_1', is_error: false, content: 'blocks: 12' }],
      },
    },
    { type: 'result', subtype: 'success', is_error: false, result: '完成' },
  ]);

  const toolUse = events.find((e) => e.type === OutMsg.TOOL_USE);
  assert.ok(toolUse, 'should emit tool_use');
  assert.equal(toolUse.id, 'toolu_1');
  assert.equal(toolUse.name, 'model_overview');
  assert.deepEqual(toolUse.input, { model: 'foo' });

  const toolResult = events.find((e) => e.type === OutMsg.TOOL_RESULT);
  assert.ok(toolResult, 'should emit tool_result');
  assert.equal(toolResult.id, 'toolu_1');
  assert.equal(toolResult.ok, true);
  assert.equal(toolResult.summary, 'blocks: 12');

  // partial 模式下不应从完整 assistant 消息重复发文本
  const deltas = events.filter((e) => e.type === OutMsg.ASSISTANT_DELTA);
  assert.equal(deltas.map((d) => d.text).join(''), '我来读模型');
});

test('tool_result 失败标记 ok=false', () => {
  const { events } = run([
    {
      type: 'user',
      message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', is_error: true, content: [{ type: 'text', text: 'boom' }] }] },
    },
  ]);
  const tr = events.find((e) => e.type === OutMsg.TOOL_RESULT);
  assert.equal(tr.ok, false);
  assert.equal(tr.summary, 'boom');
});

test('summarizeToolResult 截断超长内容', () => {
  const long = 'x'.repeat(1000);
  const s = summarizeToolResult(long, 100);
  assert.ok(s.length < 1000);
  assert.match(s, /\+900 chars/);
});

test('未知/空对象安全忽略', () => {
  const t = createStreamTranslator();
  assert.deepEqual(t.handle(null), []);
  assert.deepEqual(t.handle({ type: 'whatever' }), []);
  assert.deepEqual(t.handle({ type: 'stream_event', event: { type: 'ping' } }), []);
});
