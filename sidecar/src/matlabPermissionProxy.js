#!/usr/bin/env node
import { spawn } from 'node:child_process';
import net from 'node:net';
import { createLineBuffer, parseLine, serialize } from './protocol.js';

const [, , portArg, convArg, encodedServer] = process.argv;
const controlPort = Number(portArg);
const convId = /^[A-Za-z0-9_-]{1,96}$/.test(convArg || '') ? convArg : 'main';
const actual = decodeServer(encodedServer);
let requestSeq = 0;

if (!actual?.command || !Number.isInteger(controlPort) || controlPort <= 0) {
  process.stderr.write('Invalid MATLAB permission proxy configuration.\n');
  process.exit(2);
}

const child = spawn(actual.command, actual.args || [], {
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
  env: { ...process.env, ...(actual.env || {}) },
});

child.stdout.on('data', (chunk) => process.stdout.write(chunk));
child.stderr.on('data', (chunk) => process.stderr.write(chunk));
child.on('error', (err) => {
  process.stderr.write(`MATLAB MCP proxy spawn failed: ${err.message}\n`);
  process.exitCode = 1;
});
child.on('close', (code) => process.exit(code || 0));
child.stdin.on('error', () => {});

const feed = createLineBuffer(async (line) => {
  const message = parseLine(line);
  if (!isToolCall(message)) {
    child.stdin.write(line + '\n');
    return;
  }

  const tool = `mcp__matlab__${message.params.name}`;
  const decision = await requestPermission(tool, message.params.arguments || {});
  if (decision.approved) {
    child.stdin.write(line + '\n');
    return;
  }

  process.stdout.write(serialize({
    jsonrpc: '2.0',
    id: message.id,
    result: {
      content: [{ type: 'text', text: decision.message || 'Permission denied.' }],
      isError: true,
    },
  }) + '\n');
}, {
  onOverflow: () => process.stderr.write('MATLAB MCP proxy dropped an oversized request.\n'),
});

process.stdin.on('data', feed);
process.stdin.on('end', () => child.stdin.end());
process.stdin.on('error', () => child.kill());

function decodeServer(value) {
  try {
    return JSON.parse(Buffer.from(value || '', 'base64url').toString('utf8'));
  } catch {
    return null;
  }
}

function isToolCall(message) {
  return message?.jsonrpc === '2.0'
    && message.method === 'tools/call'
    && message.id !== undefined
    && typeof message.params?.name === 'string';
}

function requestPermission(tool, input) {
  return new Promise((resolve) => {
    const id = `codex-${process.pid}-${++requestSeq}`;
    const socket = net.createConnection({ host: '127.0.0.1', port: controlPort });
    let settled = false;
    const finish = (decision) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(decision);
    };
    const timer = setTimeout(() => finish({ approved: false, message: 'Permission request timed out.' }), 180000);
    if (timer.unref) timer.unref();
    const feedDecision = createLineBuffer((line) => {
      const msg = parseLine(line);
      if (msg?.type !== 'permission_decision' || msg.id !== id) return;
      clearTimeout(timer);
      finish({ approved: msg.approved === true, message: msg.message });
    });
    socket.on('connect', () => socket.write(serialize({
      type: 'permission_request', id, convId, tool, input,
    }) + '\n'));
    socket.on('data', feedDecision);
    socket.on('error', () => {
      clearTimeout(timer);
      finish({ approved: false, message: 'Permission broker is unavailable.' });
    });
    socket.on('close', () => {
      clearTimeout(timer);
      finish({ approved: false, message: 'Permission broker disconnected.' });
    });
  });
}
