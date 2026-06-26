import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStreamTranslator } from '../src/streamJsonParser.js';
import { OutMsg } from '../src/protocol.js';

function run(objs) {
  const t = createStreamTranslator();
  const events = [];
  for (const o of objs) events.push(...t.handle(o));
  return events;
}

test('partial:思考块先于文本,产出 thinking_* 事件', () => {
  const events = run([
    { type: 'stream_event', event: { type: 'message_start', message: {} } },
    { type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'thinking' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: '先想一下…' } } },
    { type: 'stream_event', event: { type: 'content_block_stop', index: 0 } },
    { type: 'stream_event', event: { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: '答案' } } },
    { type: 'stream_event', event: { type: 'message_stop' } },
  ]);
  const types = events.map((e) => e.type);
  assert.deepEqual(types, [
    OutMsg.THINKING_START, OutMsg.THINKING_DELTA, OutMsg.THINKING_STOP,
    OutMsg.ASSISTANT_START, OutMsg.ASSISTANT_DELTA, OutMsg.ASSISTANT_STOP,
  ]);
  assert.equal(events[1].text, '先想一下…');
  // 思考与文本同属一条消息,共用同一 id
  assert.equal(events[0].id, events[3].id);
});

test('只有思考(无文本)不产生空文本气泡', () => {
  const events = run([
    { type: 'stream_event', event: { type: 'message_start', message: {} } },
    { type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'thinking' } } },
    { type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: '思考' } } },
    { type: 'stream_event', event: { type: 'content_block_stop', index: 0 } },
    { type: 'stream_event', event: { type: 'message_stop' } },
  ]);
  const types = events.map((e) => e.type);
  assert.deepEqual(types, [OutMsg.THINKING_START, OutMsg.THINKING_DELTA, OutMsg.THINKING_STOP]);
  assert.ok(!types.includes(OutMsg.ASSISTANT_START));
});

test('非 partial:完整消息里的 thinking 块也被还原', () => {
  const events = run([
    { type: 'assistant', message: { id: 'm1', role: 'assistant', content: [
      { type: 'thinking', thinking: '这是思考' },
      { type: 'text', text: '这是答案' },
    ] } },
  ]);
  const types = events.map((e) => e.type);
  assert.deepEqual(types, [
    OutMsg.THINKING_START, OutMsg.THINKING_DELTA, OutMsg.THINKING_STOP,
    OutMsg.ASSISTANT_START, OutMsg.ASSISTANT_DELTA, OutMsg.ASSISTANT_STOP,
  ]);
});
