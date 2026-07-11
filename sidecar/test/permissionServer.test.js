import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createLineBuffer, parseLine } from '../src/protocol.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function waitForServer(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
}

function waitForStdout(child, pred, timeoutMs = 2000) {
  const msgs = [];
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('stdout wait timeout')), timeoutMs);
    const feed = createLineBuffer((line) => {
      let msg;
      try { msg = JSON.parse(line); } catch { return; }
      msgs.push(msg);
      if (pred(msg)) {
        clearTimeout(timer);
        resolve(msg);
      }
    });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', feed);
    child.on('exit', () => {
      clearTimeout(timer);
      reject(new Error(`permission server exited before reply; seen=${JSON.stringify(msgs)}`));
    });
  });
}

test('permissionServer:control 断开会立即拒绝悬挂 approval 请求', async () => {
  const control = net.createServer((sock) => {
    sock.setEncoding('utf8');
    const feed = createLineBuffer((line) => {
      const msg = parseLine(line);
      if (msg?.type === 'permission_request') sock.destroy();
    });
    sock.on('data', feed);
  });
  await waitForServer(control);
  const port = control.address().port;

  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'permissionServer.js')], {
    env: {
      ...process.env,
      MATLAB_COPILOT_CONTROL_PORT: String(port),
      MATLAB_COPILOT_APPROVAL_TIMEOUT_MS: '30000',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  try {
    const replyP = waitForStdout(child, (m) => m.id === 1);
    child.stdin.write(JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: {
        name: 'approval',
        arguments: {
          tool_name: 'mcp__matlab__model_edit',
          input: { block: 'demo/Gain' },
        },
      },
    }) + '\n');
    const reply = await replyP;
    const payload = JSON.parse(reply.result.content[0].text);
    assert.equal(payload.behavior, 'deny');
    assert.match(payload.message, /断开|异常|拒绝/);
  } finally {
    child.kill();
    await new Promise((resolve) => control.close(resolve));
  }
});
