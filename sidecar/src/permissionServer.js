#!/usr/bin/env node
// 权限确认 MCP server(stdio,**零第三方依赖**)。
// 由 Claude Code 通过 --permission-prompt-tool 调用:每当 agent 要用一个未预批的工具,
// Claude Code 就调用本 server 的 `approval` 工具。本 server 回连主 sidecar 的控制端口,
// 把确认请求转给 UI;用户点确认后返回放行/拒绝。
//
// 为什么手写而不用 @modelcontextprotocol/sdk:
//   sdk 拉入庞大的传递依赖(@hono/ajv/body-parser…),node_modules 相对路径就上百字符。
//   .mltbx 安装到 AppData\…\MATLAB Add-Ons\…\sidecar\node_modules\… 极易超 Windows 260 MAX_PATH,
//   导致这些文件丢失/损坏 → import 失败 → Claude 报「approval not found」。
//   MCP stdio 本质就是 newline-delimited JSON-RPC 2.0,approval 只暴露一个工具,手写即可,
//   于是整个 sidecar 零 npm 依赖,打包/安装不再受 node_modules 长路径问题影响。
//
// 返回格式遵循 Claude Code permission-prompt-tool 约定:
//   允许: {"behavior":"allow","updatedInput":<原 input>}
//   拒绝: {"behavior":"deny","message":"..."}

import net from 'node:net';
import { createLineBuffer, parseLine, serialize } from './protocol.js';

const HOST = '127.0.0.1';
const CONTROL_PORT = parseInt(process.env.MATLAB_COPILOT_CONTROL_PORT || '8766', 10);
const CONV_ID = process.env.MATLAB_COPILOT_CONV || 'main';  // 本会话(标签页)id,随确认请求带上
const TIMEOUT_MS = parseInt(process.env.MATLAB_COPILOT_APPROVAL_TIMEOUT_MS || '300000', 10);
const DEFAULT_PROTOCOL = '2024-11-05';

// ── 与主 sidecar 控制端口的连接(惰性建立 + 自动重连)────────────────────────
let socket = null;
let connecting = null;
const pending = new Map(); // reqId -> {resolve,timer}
let reqCounter = 0;

function settlePending(id, decision) {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  if (p.timer) clearTimeout(p.timer);
  p.resolve(decision);
}

function settleAllPending(decision) {
  for (const id of [...pending.keys()]) settlePending(id, decision);
}

function connect() {
  if (socket && !socket.destroyed) return Promise.resolve(socket);
  if (connecting) return connecting;
  connecting = new Promise((resolve, reject) => {
    const s = net.createConnection({ host: HOST, port: CONTROL_PORT }, () => {
      socket = s;
      connecting = null;
      resolve(s);
    });
    s.setEncoding('utf8');
    const feed = createLineBuffer((line) => {
      const msg = parseLine(line);
      if (!msg || msg.type !== 'permission_decision') return;
      settlePending(msg.id, { approved: msg.approved === true, message: msg.message });
    });
    s.on('data', feed);
    s.on('error', (err) => {
      connecting = null;
      if (socket === s) socket = null;
      settleAllPending({ approved: false, message: `确认通道异常: ${err.message}` });
      reject(err);
    });
    s.on('close', () => {
      connecting = null;
      if (socket === s) socket = null;
      settleAllPending({ approved: false, message: '确认通道断开,已拒绝' });
    });
  });
  return connecting;
}

async function askApproval(toolName, input) {
  const s = await connect();
  const id = `perm-${++reqCounter}`;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (pending.has(id)) {
        settlePending(id, { approved: false, message: '确认超时,已拒绝' });
      }
    }, TIMEOUT_MS);
    if (timer.unref) timer.unref();
    pending.set(id, { resolve, timer });
    s.write(serialize({ type: 'permission_request', id, convId: CONV_ID, tool: toolName, input }) + '\n');
  });
}

// ── 极简 MCP(JSON-RPC 2.0 over newline-delimited stdio)──────────────────────
function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

const APPROVAL_TOOL = {
  name: 'approval',
  description: '在执行可能有副作用的工具前请求用户确认',
  inputSchema: {
    type: 'object',
    properties: { tool_name: { type: 'string' }, input: {} },
    required: ['tool_name'],
  },
};

async function handleRpc(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;  // 通知不回复
  switch (method) {
    case 'initialize':
      // 回客户端请求的协议版本(兼容性最好),否则用默认。
      reply(id, {
        protocolVersion: (params && params.protocolVersion) || DEFAULT_PROTOCOL,
        capabilities: { tools: {} },
        serverInfo: { name: 'matlab-copilot-approval', version: '0.2.0' },
      });
      return;
    case 'notifications/initialized':
    case 'initialized':
      return;  // 通知,忽略
    case 'ping':
      if (!isNotification) reply(id, {});
      return;
    case 'tools/list':
      reply(id, { tools: [APPROVAL_TOOL] });
      return;
    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      if (name !== 'approval') { if (!isNotification) replyError(id, -32602, `未知工具: ${name}`); return; }
      let decision;
      try {
        decision = await askApproval(args.tool_name, args.input);
      } catch (err) {
        decision = { approved: false, message: `确认通道异常: ${err.message}` };
      }
      const payload = decision.approved
        ? { behavior: 'allow', updatedInput: args.input ?? {} }
        : { behavior: 'deny', message: decision.message || '用户拒绝' };
      reply(id, { content: [{ type: 'text', text: JSON.stringify(payload) }] });
      return;
    }
    default:
      // 其它请求回方法未实现;通知直接忽略。
      if (!isNotification) replyError(id, -32601, `未实现的方法: ${method}`);
      return;
  }
}

const feedStdin = createLineBuffer((line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }       // 跳过非 JSON 行
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return;
  Promise.resolve(handleRpc(msg)).catch((err) => {
    if (msg.id !== undefined && msg.id !== null) replyError(msg.id, -32603, `内部错误: ${err.message}`);
  });
});
process.stdin.setEncoding('utf8');
process.stdin.on('data', feedStdin);
process.stdin.on('error', () => {});
// stdin 关闭(Claude 退出)→ 本进程随之退出。
process.stdin.on('end', () => process.exit(0));
