import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { Server } from '../src/server.js';
import { EchoAdapter } from '../src/adapters/echo.js';
import { OutMsg, InMsg, serialize, createLineBuffer, parseLine } from '../src/protocol.js';

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
    close: () => sock.destroy(),
  };
}

test('GET_CAPABILITIES 返回后端/模式/思考强度', async () => {
  const server = new Server({ makeAdapter: () => new EchoAdapter({ delayMs: 1 }), config: { backend: 'echo' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  const c = client(clientPort);
  await c.waitFor((m) => m.type === OutMsg.READY);
  c.send({ type: InMsg.GET_CAPABILITIES });
  const caps = await c.waitFor((m) => m.type === OutMsg.CAPABILITIES);
  assert.ok(caps.backends.some((b) => b.id === 'claude'));
  assert.ok(caps.backends.some((b) => b.id === 'codex'));
  assert.deepEqual(caps.efforts, ['low', 'medium', 'high']);
  assert.ok(caps.modes.some((m) => m.id === 'plan'));
  c.close(); await server.stop();
});

test('SET_CONFIG 重建适配器并回 config_changed', async () => {
  let built = 0;
  const server = new Server({ makeAdapter: (cfg) => { built++; return new EchoAdapter({ delayMs: 1 }); }, config: { backend: 'echo', mode: 'ask' }, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();
  assert.equal(built, 1);
  const c = client(clientPort);
  await c.waitFor((m) => m.type === OutMsg.READY);
  c.send({ type: InMsg.SET_CONFIG, config: { mode: 'auto' } });
  const ch = await c.waitFor((m) => m.type === OutMsg.CONFIG_CHANGED);
  assert.equal(ch.config.mode, 'auto');
  assert.equal(built, 2); // 已重建
  c.close(); await server.stop();
});
