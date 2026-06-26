function copilot_doctor()
% COPILOT_DOCTOR  MATLAB Copilot 环境自诊断。
%   逐项 PASS/FAIL + 可操作的一行修复指令；统计失败项并给出结论。
%
%   用法: copilot_doctor()

fprintf('\n=== MATLAB Copilot 环境自检 ===\n\n');

results = {};
results{end+1} = checkNode();
results{end+1} = checkCLI();
results{end+1} = checkMcpServer();
results{end+1} = checkSatkInit();
results{end+1} = checkSidecarDeps();
results{end+1} = checkPort();

fails = sum(cellfun(@(r) ~r.ok, results));
fprintf('\n');
if fails == 0
    fprintf('结论: 全部通过，运行 copilot() 即可。\n');
else
    fprintf('结论: %d 项需修复（见上方指令）。\n', fails);
end
fprintf('================================\n\n');
end

% ── 检查项 ────────────────────────────────────────────────────────────────

function r = checkNode()
r.name = 'Node.js ≥ 20';
[st, out] = system('node --version 2>&1');
if st ~= 0
    r = fail(r, 'PATH 中未找到 node', ...
        '访问 https://nodejs.org 安装 Node.js LTS，或将其加入系统 PATH。');
    return;
end
ver = strtrim(out);
% 提取第一段纯数字(跳过前缀 "v" 等任意字符)
tok = regexp(ver, '(\d+)', 'tokens', 'once');
if isempty(tok)
    r = fail(r, sprintf('无法解析版本号: %s', ver), ...
        '请确认 node --version 返回如 v20.x.x 的格式。');
    return;
end
major = str2double(tok{1});
if major < 20
    r = fail(r, sprintf('版本过低: %s (需 ≥ 20)', ver), ...
        '请升级 Node.js 到 v20+ (https://nodejs.org)。');
else
    r = pass(r, ver);
end
end

function r = checkCLI()
r.name = '后端 CLI (claude / codex)';
[s1, o1] = system('claude --version 2>&1');
if s1 == 0
    r = pass(r, strtrim(o1));
    return;
end
[s2, o2] = system('codex --version 2>&1');
if s2 == 0
    r = pass(r, ['codex ' strtrim(o2)]);
    return;
end
r = fail(r, '未找到 claude 也未找到 codex', ...
    'npm i -g @anthropic-ai/claude-code  →  claude login   或   npm i -g @openai/codex  →  codex login');
end

function r = checkMcpServer()
r.name = 'MATLAB MCP Server';
% 1. 检查 satk_initialize 是否在 MATLAB 路径(最可靠指标)
if exist('satk_initialize', 'file') > 0
    r = pass(r, 'satk_initialize 在 MATLAB 路径(Simulink Agentic Toolkit 已装)');
    return;
end
% 2. 宽松检查 Add-Ons(名称可能含 MCP / Agentic / Simulink 等关键词)
try
    addons = matlab.addons.installedAddons();
    names  = lower(string(addons.Name));
    if any(contains(names, 'agentic')) || any(contains(names, 'mcp')) ...
            || any(contains(names, 'mcp-core'))
        r = pass(r, 'Add-Ons 中检测到 MCP 相关工具箱');
        return;
    end
catch
end
% 3. 检查可执行文件(PATH 可能较窄,仅作参考)
for name = ["matlab-mcp-server", "matlab-mcp-core-server"]
    [s, ~] = system(name + " --help 2>&1");
    if s == 0
        r = pass(r, name + ' 在 PATH');
        return;
    end
end
r = fail(r, 'matlab-mcp-server 未找到', ...
    ['MATLAB Add-Ons 安装 "Simulink Agentic Toolkit"，' ...
     '然后在 MATLAB 里运行: satk_initialize']);
end

function r = checkSatkInit()
r.name = 'MATLAB 会话共享 (satk_initialize)';
% 检查 sessionDetails.json 是否存在于标准路径(两个可能位置)
candidates = { ...
    fullfile(getenv('APPDATA'), 'MathWorks', 'MATLAB MCP Core Server', 'v1', 'sessionDetails.json'), ...
    fullfile(getenv('APPDATA'), 'MathWorks', 'MATLAB MCP Server', 'v1', 'sessionDetails.json') ...
};
for i = 1:numel(candidates)
    if isfile(candidates{i})
        r = pass(r, 'sessionDetails.json 已存在');
        return;
    end
end
r = fail(r, 'sessionDetails.json 缺失 — 会话未共享', ...
    'MATLAB 命令窗口运行: satk_initialize');
end

function r = checkSidecarDeps()
% sidecar 已零 npm 依赖,不再需要 node_modules;改为检查源码入口与权限 MCP server 文件是否完整。
r.name = 'Sidecar 源码 (零依赖)';
here = fileparts(mfilename('fullpath'));
root = fileparts(here);
entry = fullfile(root, 'sidecar', 'src', 'index.js');
approval = fullfile(root, 'sidecar', 'src', 'permissionServer.js');
if isfile(entry) && isfile(approval)
    r = pass(r, 'sidecar 源码完整 (零 npm 依赖,无需 node_modules / npm install)');
else
    missing = '';
    if ~isfile(entry); missing = [missing ' index.js']; end
    if ~isfile(approval); missing = [missing ' permissionServer.js']; end
    r = fail(r, ['sidecar 源码缺失:' missing], ...
        '重新安装 .mltbx,或确认 sidecar/src 目录完整。');
end
end

function r = checkPort()
r.name = '端口 8765 (sidecar 通信端口)';
try
    srv = tcpserver('127.0.0.1', 8765);
    delete(srv);
    r = pass(r, '端口空闲');
catch
    r = fail(r, '端口已被占用', ...
        '先关闭占用 8765 的进程，或修改 sidecar/src/server.js 里的 PORT 常量。');
end
end

% ── 工具函数 ──────────────────────────────────────────────────────────────

function r = pass(r, detail)
fprintf('  ✓ %-32s %s\n', r.name, detail);
r.ok = true;
end

function r = fail(r, reason, fix)
fprintf('  ✗ %-32s %s\n', r.name, reason);
fprintf('    → 修复: %s\n', fix);
r.ok = false;
end
