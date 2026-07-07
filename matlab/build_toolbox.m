function out = build_toolbox()
% BUILD_TOOLBOX  把本项目打包成可安装的 MATLAB 工具箱(.mltbx)。
%
% 用 matlab.addons.toolbox.ToolboxOptions + packageToolbox(R2023a+),免手写 .prj。
% 打包 matlab/(入路径)+ ui/ + sidecar(源码,**不含 node_modules**)+ 文档;
% 安装后会把 matlab/ 加入路径。接收者只需自备 Node.js + claude/codex CLI。
%
% 关键:sidecar **零 npm 依赖**(主进程与权限 MCP server 都只用 Node 内置 + 本地 JS),
% 所以**不打包 node_modules**。这避免了 node_modules 深层路径(@modelcontextprotocol/sdk 等)
% 装到 AppData\…\MATLAB Add-Ons\… 后超 Windows 260 MAX_PATH 而丢失/损坏,
% 导致权限 MCP(approval)起不来、Claude 报「approval not found」的问题。
% 使用前在 MATLAB 里运行一次 satk_initialize 共享会话。
%
%   build_toolbox            % 在仓库根生成 MATLAB-Copilot.mltbx

if exist('matlab.addons.toolbox.ToolboxOptions', 'class') ~= 8
    error('matlabcopilot:noPackager', '需 MATLAB R2023a 及以上(ToolboxOptions)。');
end

here = fileparts(mfilename('fullpath'));   % matlab/
root = fileparts(here);                    % 仓库根
identifier = '7c5cff00-c0de-4a11-9a2b-0c0de1100001';  % 固定工具箱标识

% ToolboxOptions 第一个参数只接受单一文件夹路径(字符串标量)。
% 收集需要的文件后赋给 ToolboxFiles 属性来控制打包范围。
% **排除 node_modules**:sidecar 零 npm 依赖,无需打包;且其深层路径会触发 Windows 260 MAX_PATH 问题。
excludeDirs = [".git", ".spec-workflow", "ModelandCode_EP2", "slprj", ".vscode", "tasks", "node_modules"];
files = gatherFiles(root, excludeDirs);
if isempty(files)
    error('matlabcopilot:noFiles', '未收集到任何文件。');
end

opts = matlab.addons.toolbox.ToolboxOptions(root, identifier);
opts.ToolboxFiles = files;                   % 覆盖为筛选后的文件列表
opts.ToolboxName = "MATLAB-Copilot";            % 纯 ASCII — 避免安装路径含 CJK 字符导致 Node.js 子进程问题
opts.ToolboxVersion = "0.9.0";
opts.Summary = "AI Copilot sidebar for MATLAB/Simulink";
opts.Description = ['Native AI Copilot sidebar for MATLAB/Simulink (Claude Code / Codex backend). ' ...
    'Sidecar has zero npm dependencies — no node_modules, no npm install needed.'];
opts.AuthorName = "jushenghuainango";
opts.ToolboxMatlabPath = string(here);       % 把 matlab/ 加入路径
opts.MinimumMatlabRelease = "R2023b";
opts.OutputFile = fullfile(root, "MATLAB-Copilot.mltbx");

matlab.addons.toolbox.packageToolbox(opts);
out = opts.OutputFile;
fprintf(['已打包: %s\n' ...
         '接收者安装后:① 确保 Node.js ≥ 20 在 PATH;' ...
         '② npm i -g @anthropic-ai/claude-code 然后 claude login;' ...
         '③ MATLAB 里运行 satk_initialize 共享会话;' ...
         '④ 运行 copilot_doctor() 自检。\n' ...
         '(sidecar 零 npm 依赖,不含 node_modules,无需 npm install)\n'], out);
end

% 递归收集文件,跳过 excludeDirs 命名的目录。
function files = gatherFiles(root, excludeDirs)
files = strings(0, 1);
stack = {root};
while ~isempty(stack)
    d = stack{end}; stack(end) = [];
    items = dir(d);
    for i = 1:numel(items)
        nm = items(i).name;
        if nm == "." || nm == ".."; continue; end
        full = fullfile(d, nm);
        if items(i).isdir
            if any(string(nm) == excludeDirs); continue; end
            stack{end+1} = full; %#ok<AGROW>
        else
            files(end+1, 1) = string(full); %#ok<AGROW>
        end
    end
end
end
