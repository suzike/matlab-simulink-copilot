import { BackendAdapter, renderContextPreamble } from './types.js';
import { OutMsg } from '../protocol.js';

/**
 * 联调用后端:把用户消息按词流式回显。无需 claude / MATLAB,用于验证
 * uihtml ⇄ MATLAB ⇄ tcpclient ⇄ sidecar 的整条链路与流式渲染。
 */
export class EchoAdapter extends BackendAdapter {
  constructor(opts = {}) {
    super();
    this.delayMs = opts.delayMs ?? 30;
    this.turn = 0;
  }

  async start() {
    this.emitEvent({ type: OutMsg.READY });
  }

  async sendMessage({ text, context } = {}) {
    const id = `echo-${++this.turn}`;
    const preamble = renderContextPreamble(context);
    // 思考流 + 富文本(Markdown)回复,用于演示「思考过程 + 流式 + 富渲染」整条体验。
    const thinking = `分析用户输入「${text || ''}」…\n这是 echo 后端,不接真模型,直接回显并演示渲染。`;
    const reply =
      `### 已收到你的消息\n你说的是:**${text || ''}**\n\n` +
      `我能做的(示例):\n- 解释代码 / Simulink 模型\n- 生成测试用例\n- 直接修改模型\n\n` +
      '```matlab\nx = 12 * 13;\ndisp(x)   % 156\n```' +
      (preamble ? `\n\n> 已附带上下文 ${preamble.length} 字符` : '');
    const chunk = (s) => s.match(/[\s\S]{1,3}/g) || [s];
    const tChunks = chunk(thinking), rChunks = chunk(reply);

    this.emitEvent({ type: OutMsg.STATUS, text: 'thinking' });

    let phase = 'think', i = 0;
    this.emitEvent({ type: OutMsg.THINKING_START, id });
    const tick = () => {
      if (phase === 'think') {
        if (i < tChunks.length) { this.emitEvent({ type: OutMsg.THINKING_DELTA, id, text: tChunks[i++] }); }
        else { this.emitEvent({ type: OutMsg.THINKING_STOP, id }); this.emitEvent({ type: OutMsg.ASSISTANT_START, id }); phase = 'answer'; i = 0; }
      } else {
        if (i < rChunks.length) { this.emitEvent({ type: OutMsg.ASSISTANT_DELTA, id, text: rChunks[i++] }); }
        else {
          this.emitEvent({ type: OutMsg.ASSISTANT_STOP, id });
          this.emitEvent({ type: OutMsg.RESULT, id, ok: true, text: reply, costUsd: 0 });
          return;
        }
      }
      this._timer = setTimeout(tick, this.delayMs);
    };
    tick();
  }

  interrupt() {
    if (this._timer) clearTimeout(this._timer);
    this.emitEvent({ type: OutMsg.STATUS, text: 'interrupted' });
  }

  async stop() {
    if (this._timer) clearTimeout(this._timer);
  }
}
