#!/usr/bin/env node
// sidecar 入口:选后端、(claude 时)生成权限确认 MCP 配置、启动 TCP server。

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Server } from './server.js';
import { EchoAdapter } from './adapters/echo.js';
import { ClaudeCodeAdapter } from './adapters/claudeCode.js';
import { CodexAdapter } from './adapters/codex.js';
import * as cfg from './config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// effort(low/medium/high)→ claude 思考 token 预算。
const EFFORT_TOKENS = { low: 2000, medium: 8000, high: 16000 };
// mode(ask/auto/plan)→ claude permission-mode。
const CLAUDE_MODE = { ask: null, auto: 'acceptEdits', plan: 'plan' };
// mode → codex 沙箱(exec 非交互,ask/plan 只读以防意外改动;auto 允许写)。
const CODEX_SANDBOX_BY_MODE = { ask: 'read-only', auto: 'workspace-write', plan: 'read-only' };

function safeConvId(value) {
  const id = String(value || 'main');
  return /^[A-Za-z0-9_-]{1,96}$/.test(id) ? id : 'main';
}

function permissionWrappedMatlabMcp(actual, convId) {
  if (!actual) return null;
  const entry = path.join(__dirname, 'matlabPermissionProxy.js');
  const encoded = Buffer.from(JSON.stringify(actual), 'utf8').toString('base64url');
  return {
    command: process.execPath,
    args: [entry, String(cfg.CONTROL_PORT), safeConvId(convId), encoded],
  };
}

// 按当前运行时配置造一个后端适配器。state:{backend,model,effort,mode}
function makeAdapter(state) {
  const backend = state.backend || cfg.BACKEND;
  if (backend === 'echo') return new EchoAdapter();
  if (backend === 'codex') {
    const convId = safeConvId(state.convId);
    return new CodexAdapter({
      cwd: cfg.CWD,
      model: state.model || cfg.MODEL,
      effort: state.effort || cfg.CODEX_EFFORT,
      sandbox: CODEX_SANDBOX_BY_MODE[state.mode] || cfg.CODEX_SANDBOX,
      matlabMcp: permissionWrappedMatlabMcp(cfg.getMatlabMcpServer(), convId),
    });
  }
  // claude:注入 MATLAB MCP + 权限确认 MCP,--strict-mcp-config 只加载这两个。
  // 多会话:approval MCP 带上 convId,使权限确认卡能路由回对应标签页;mcp 配置文件按会话区分。
  const convId = safeConvId(state.convId);
  const approvalEntry = path.join(__dirname, 'permissionServer.js');
  const mcpServers = {
    approval: { command: process.execPath, args: [approvalEntry], env: {
      MATLAB_COPILOT_CONTROL_PORT: String(cfg.CONTROL_PORT),
      MATLAB_COPILOT_CONV: convId,
    } },
  };
  const matlabMcp = cfg.getMatlabMcpServer();
  if (matlabMcp) mcpServers.matlab = matlabMcp;
  else process.stderr.write('警告:未探测到 MATLAB MCP server,claude 将无 matlab/simulink 工具。\n');
  const mcpConfigPath = path.join(os.tmpdir(), `matlab-copilot-mcp-${process.pid}-${convId}.json`);
  fs.writeFileSync(mcpConfigPath, JSON.stringify({ mcpServers }, null, 2));

  return new ClaudeCodeAdapter({
    cwd: cfg.CWD,
    model: state.model || cfg.MODEL,
    thinkingTokens: state.effort ? (EFFORT_TOKENS[state.effort] ?? cfg.THINKING_TOKENS) : cfg.THINKING_TOKENS,
    permissionMode: CLAUDE_MODE[state.mode] || null,
    allowedTools: cfg.PREAPPROVED_TOOLS,
    mcpConfigPath,
    strictMcpConfig: true,
    permissionPromptTool: 'mcp__approval__approval',
    appendSystemPrompt: cfg.APPEND_SYSTEM_PROMPT,
    persistent: state.persistent,   // UI 开关;undefined 时 adapter 回退 env
  });
}

async function main() {
  const initialConfig = { backend: cfg.BACKEND, model: cfg.MODEL || null, effort: 'medium', mode: 'ask', persistent: cfg.PERSISTENT };
  const server = new Server({
    makeAdapter,
    config: initialConfig,
    cwd: cfg.CWD,
    host: cfg.HOST,
    clientPort: cfg.CLIENT_PORT,
    controlPort: cfg.CONTROL_PORT,
  });
  const { clientPort, controlPort } = await server.start();

  // 落一个发现文件,MATLAB 端可读到实际端口与状态。
  const infoPath = path.join(os.tmpdir(), 'matlab-copilot-sidecar.json');
  fs.writeFileSync(infoPath, JSON.stringify({
    pid: process.pid,
    host: cfg.HOST,
    clientPort,
    controlPort,
    backend: cfg.BACKEND,
    cwd: cfg.CWD,
    startedAt: new Date().toISOString(),
  }, null, 2));

  // 单行 ready 提示(MATLAB 端可解析 stdout 判断启动成功)。
  process.stdout.write(`SIDECAR_READY ${JSON.stringify({ host: cfg.HOST, clientPort, controlPort, backend: cfg.BACKEND })}\n`);

  const shutdown = async () => { await server.stop(); process.exit(0); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  process.stderr.write(`sidecar 启动失败: ${err?.stack || err}\n`);
  process.exit(1);
});
