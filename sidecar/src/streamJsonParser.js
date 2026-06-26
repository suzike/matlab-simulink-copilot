// 把 Claude Code 的 stream-json 输出(每行一个对象)翻译成 UI 事件(OutMsg)。
//
// Claude Code 在 `--output-format stream-json --include-partial-messages` 下会发出:
//   1. {type:"system", subtype:"init", session_id, ...}
//   2. {type:"stream_event", event:{...Anthropic SSE...}}   ← 逐 token 流式(partial 模式)
//   3. {type:"assistant", message:{content:[...]}}           ← 完整助手消息(含 tool_use)
//   4. {type:"user", message:{content:[{type:"tool_result", ...}]}}
//   5. {type:"result", subtype, is_error, result, total_cost_usd, session_id}
//
// 设计:文本走 partial 流式;tool_use 一律从完整 assistant 消息取(input 此时才完整);
// 若没开 partial(从未见到 stream_event),则文本也从完整 assistant 消息一次性给出。

import { OutMsg } from './protocol.js';

export function createStreamTranslator() {
  let sessionId = null;
  let partialMode = false;   // 见过 stream_event 即为 true
  let msgCounter = 0;
  let currentMsgId = null;   // 当前 partial 助手消息 id
  let textStarted = false;   // 当前消息是否已发过 ASSISTANT_START(懒发)
  let curBlockType = null;   // 当前 content block 类型(text/thinking/tool_use)

  function newMsgId() {
    return `m${++msgCounter}`;
  }

  // 输入:一个已解析的 stream-json 对象。返回:UI 事件数组(可能为空)。
  function handle(obj) {
    if (!obj || typeof obj !== 'object') return [];
    switch (obj.type) {
      case 'system':
        if (obj.session_id) sessionId = obj.session_id;
        return [];

      case 'stream_event':
        return handleStreamEvent(obj.event);

      case 'assistant':
        return handleAssistant(obj.message);

      case 'user':
        return handleUser(obj.message);

      case 'result':
        if (obj.session_id) sessionId = obj.session_id;
        return [{
          type: OutMsg.RESULT,
          id: currentMsgId,
          ok: obj.is_error !== true,
          text: typeof obj.result === 'string' ? obj.result : '',
          costUsd: obj.total_cost_usd ?? null,
        }];

      default:
        return [];
    }
  }

  function handleStreamEvent(event) {
    if (!event || typeof event !== 'object') return [];
    partialMode = true;
    switch (event.type) {
      case 'message_start': {
        currentMsgId = newMsgId();
        textStarted = false;
        // 不在此处发 ASSISTANT_START:等到真有文本 delta 再发(懒发),
        // 这样「只有思考/工具调用」的消息不会留下空文本气泡。
        return [];
      }
      case 'content_block_start': {
        curBlockType = event.content_block && event.content_block.type;
        if (curBlockType === 'thinking' || curBlockType === 'redacted_thinking') {
          return [{ type: OutMsg.THINKING_START, id: currentMsgId }];
        }
        return [];
      }
      case 'content_block_delta': {
        const d = event.delta;
        if (!d) return [];
        if (d.type === 'text_delta' && d.text) {
          const evs = [];
          if (!textStarted) { textStarted = true; evs.push({ type: OutMsg.ASSISTANT_START, id: currentMsgId }); }
          evs.push({ type: OutMsg.ASSISTANT_DELTA, id: currentMsgId, text: d.text });
          return evs;
        }
        if (d.type === 'thinking_delta' && d.thinking) {
          return [{ type: OutMsg.THINKING_DELTA, id: currentMsgId, text: d.thinking }];
        }
        return [];
      }
      case 'content_block_stop': {
        const wasThinking = curBlockType === 'thinking' || curBlockType === 'redacted_thinking';
        curBlockType = null;
        return wasThinking ? [{ type: OutMsg.THINKING_STOP, id: currentMsgId }] : [];
      }
      case 'message_stop': {
        const id = currentMsgId;
        return id && textStarted ? [{ type: OutMsg.ASSISTANT_STOP, id }] : [];
      }
      default:
        return [];
    }
  }

  function handleAssistant(message) {
    if (!message || !Array.isArray(message.content)) return [];
    const events = [];
    // 非 partial 模式:思考与文本都要从这里一次性给出。
    if (!partialMode) {
      const id = newMsgId();
      const thinking = message.content
        .filter((b) => (b.type === 'thinking' && b.thinking) || (b.type === 'redacted_thinking'))
        .map((b) => b.thinking || '[已隐藏的思考]')
        .join('');
      if (thinking) {
        events.push({ type: OutMsg.THINKING_START, id });
        events.push({ type: OutMsg.THINKING_DELTA, id, text: thinking });
        events.push({ type: OutMsg.THINKING_STOP, id });
      }
      const text = message.content
        .filter((b) => b.type === 'text' && b.text)
        .map((b) => b.text)
        .join('');
      if (text) {
        events.push({ type: OutMsg.ASSISTANT_START, id });
        events.push({ type: OutMsg.ASSISTANT_DELTA, id, text });
        events.push({ type: OutMsg.ASSISTANT_STOP, id });
      }
    }
    // tool_use 一律从完整消息取(input 此时才完整)。
    for (const block of message.content) {
      if (block.type === 'tool_use') {
        events.push({
          type: OutMsg.TOOL_USE,
          id: block.id,
          name: block.name,
          input: block.input ?? {},
        });
      }
    }
    return events;
  }

  function handleUser(message) {
    if (!message || !Array.isArray(message.content)) return [];
    const events = [];
    for (const block of message.content) {
      if (block.type === 'tool_result') {
        events.push({
          type: OutMsg.TOOL_RESULT,
          id: block.tool_use_id,
          ok: block.is_error !== true,
          summary: summarizeToolResult(block.content),
        });
      }
    }
    return events;
  }

  return {
    handle,
    getSessionId: () => sessionId,
  };
}

// 把 tool_result 的 content(字符串或块数组)压成一段简短摘要供 UI 展示。
export function summarizeToolResult(content, max = 600) {
  let text = '';
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    text = content
      .map((c) => (typeof c === 'string' ? c : c?.type === 'text' ? c.text : ''))
      .filter(Boolean)
      .join('\n');
  }
  if (text.length > max) return text.slice(0, max) + `\n…(+${text.length - max} chars)`;
  return text;
}
