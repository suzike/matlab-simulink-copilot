import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { Server } from '../src/server.js';
import { BackendAdapter } from '../src/adapters/types.js';
import { OutMsg, InMsg, serialize, createLineBuffer, parseLine } from '../src/protocol.js';

class FakeAdapter extends BackendAdapter {
  constructor() { super(); this.calls = []; this.resets = 0; }
  async start() {}
  async sendMessage(p) {
    this.calls.push(p);
    this.emitEvent({ type: OutMsg.ASSISTANT_START, id: 'a' });
    this.emitEvent({ type: OutMsg.ASSISTANT_DELTA, id: 'a', text: '摘要内容' });
    this.emitEvent({ type: OutMsg.ASSISTANT_STOP, id: 'a' });
    this.emitEvent({ type: OutMsg.RESULT, id: 'a', ok: true, text: '摘要内容', costUsd: 0 });
  }
  resetSession() { this.resets++; }
}

function client(port) {
  const sock = net.createConnection({ host: '127.0.0.1', port });
  sock.setEncoding('utf8');
  const msgs = [], waiters = [];
  sock.on('data', createLineBuffer((line) => {
    const m = parseLine(line); if (!m) return; msgs.push(m);
    for (let i = waiters.length - 1; i >= 0; i--) if (waiters[i].pred(m)) waiters.splice(i, 1)[0].resolve(m);
  }));
  return {
    send: (o) => sock.write(serialize(o) + '\n'),
    waitFor: (pred) => new Promise((res) => { const h = msgs.find(pred); if (h) return res(h); waiters.push({ pred, resolve: res }); }),
    nResults: () => msgs.filter((m) => m.type === OutMsg.RESULT).length,
    close: () => sock.destroy(),
  };
}

test('/compact:生成摘要→重置会话→摘要播种到下一轮上下文', async () => {
  let adapter;
  const server = new Server({ makeAdapter: () => (adapter = new FakeAdapter()), config: { backend: 'x' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const c = client(clientPort);
  await c.waitFor((m) => m.type === OutMsg.READY);

  c.send({ type: InMsg.SLASH_COMMAND, name: '/compact', context: { currentModel: 'demo' } });
  await c.waitFor((m) => m.type === OutMsg.RESULT);
  await c.waitFor((m) => m.type === OutMsg.STATUS && /已压缩/.test(m.text || ''));
  assert.equal(adapter.resets, 1, '应重置后端会话');

  c.send({ type: InMsg.USER_MESSAGE, id: 'u2', text: '继续', context: { currentModel: 'demo' } });
  await c.waitFor(() => c.nResults() >= 2);
  const userCall = adapter.calls[1];
  assert.equal(userCall.context.compactSummary, '摘要内容', '下一轮应带上摘要');

  // 摘要只播种一次
  c.send({ type: InMsg.USER_MESSAGE, id: 'u3', text: '再继续', context: {} });
  await c.waitFor(() => c.nResults() >= 3);
  assert.ok(!adapter.calls[2].context || adapter.calls[2].context.compactSummary === undefined, '摘要不应重复播种');

  c.close(); await server.stop();
});
