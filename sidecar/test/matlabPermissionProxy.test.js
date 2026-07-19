import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createLineBuffer, parseLine, serialize } from '../src/protocol.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

test('Codex MATLAB proxy denies before forwarding tools/call', async (t) => {
  let permissionRequest;
  const control = net.createServer((socket) => {
    socket.on('data', createLineBuffer((line) => {
      const msg = parseLine(line);
      permissionRequest = msg;
      socket.write(serialize({
        type: 'permission_decision', id: msg.id, approved: false, message: 'denied by test',
      }) + '\n');
    }));
  });
  await new Promise((resolve) => control.listen(0, '127.0.0.1', resolve));
  t.after(() => control.close());

  const fakeServerCode = [
    "process.stdin.on('data', () => {",
    "  process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:99,result:{content:[{type:'text',text:'EXECUTED'}]}})+'\\n');",
    "});",
  ].join('');
  const encoded = Buffer.from(JSON.stringify({
    command: process.execPath, args: ['-e', fakeServerCode],
  }), 'utf8').toString('base64url');
  const proxy = spawn(process.execPath, [
    path.join(__dirname, '..', 'src', 'matlabPermissionProxy.js'),
    String(control.address().port), 'test-conv', encoded,
  ], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  t.after(() => proxy.kill());

  const reply = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('proxy reply timeout')), 5000);
    proxy.stdout.on('data', createLineBuffer((line) => {
      clearTimeout(timer);
      resolve(parseLine(line));
    }));
  });
  proxy.stdin.write(serialize({
    jsonrpc: '2.0', id: 7, method: 'tools/call',
    params: { name: 'model_edit', arguments: { model: 'demo' } },
  }) + '\n');

  const result = await reply;
  assert.equal(permissionRequest.convId, 'test-conv');
  assert.equal(permissionRequest.tool, 'mcp__matlab__model_edit');
  assert.equal(result.id, 7);
  assert.equal(result.result.isError, true);
  assert.match(result.result.content[0].text, /denied by test/);
  assert.doesNotMatch(JSON.stringify(result), /EXECUTED/);
});
