import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { Server } from '../src/server.js';
import { BackendAdapter } from '../src/adapters/types.js';
import { ClaudeCodeAdapter } from '../src/adapters/claudeCode.js';
import { InMsg, OutMsg, serialize, createLineBuffer, parseLine } from '../src/protocol.js';
import { INSERT_SYSTEM_PROMPT } from '../src/config.js';

test('ClaudeCodeAdapter.buildArgs:默认用构造时的系统提示,可被本轮覆盖', () => {
  const a = new ClaudeCodeAdapter({ appendSystemPrompt: 'DEFAULT' });
  const def = a.buildArgs();
  const i = def.indexOf('--append-system-prompt');
  assert.ok(i >= 0 && def[i + 1] === 'DEFAULT');

  const over = a.buildArgs('OVERRIDE');
  const j = over.indexOf('--append-system-prompt');
  assert.ok(j >= 0 && over[j + 1] === 'OVERRIDE');
});

test('Server:intent=insert_at_cursor 时把 INSERT_SYSTEM_PROMPT 传给适配器', async () => {
  const calls = [];
  class CapturingAdapter extends BackendAdapter {
    async start() {}
    async sendMessage(p) { calls.push(p); }
  }
  const server = new Server({ makeAdapter: () => new CapturingAdapter(), config: {}, host: '127.0.0.1', clientPort: 0, controlPort: 0 });
  const { clientPort } = await server.start();

  const sock = net.createConnection({ host: '127.0.0.1', port: clientPort });
  sock.setEncoding('utf8');
  await new Promise((r) => sock.once('connect', r));

  sock.write(serialize({ type: InMsg.USER_MESSAGE, id: 'u1', text: '生成一个 for 循环', intent: 'insert_at_cursor', context: {} }) + '\n');
  sock.write(serialize({ type: InMsg.USER_MESSAGE, id: 'u2', text: '普通提问', context: {} }) + '\n');

  await waitUntil(() => calls.length >= 2);
  assert.equal(calls[0].systemPrompt, INSERT_SYSTEM_PROMPT);
  assert.equal(calls[1].systemPrompt, undefined);

  sock.destroy();
  await server.stop();
});

function waitUntil(pred, timeout = 2000) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const iv = setInterval(() => {
      if (pred()) { clearInterval(iv); resolve(); }
      else if (Date.now() - t0 > timeout) { clearInterval(iv); reject(new Error('timeout')); }
    }, 5);
  });
}
