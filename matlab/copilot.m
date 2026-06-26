function p = copilot(opts)
    % COPILOT  打开 MATLAB/Simulink 内嵌 Copilot 侧边栏。
    %
    %   copilot                 用默认设置(claude 后端,当前文件夹为工作目录)打开面板
    %   copilot(Backend="echo") 用 echo 后端联调(无需 claude / MATLAB MCP)
    %   p = copilot(...)        返回 Panel 句柄
    %
    % 选项:
    %   Backend     "claude"(默认) | "echo"
    %   Cwd         agent 工作目录,默认 pwd
    %   Port        sidecar 客户端端口,默认 8765
    %   ControlPort 权限确认端口,默认 8766
    %   NodeBin     node 可执行文件,默认 "node"
    arguments
        opts.Backend (1,1) string = "claude"
        opts.Cwd (1,1) string = string(pwd)
        opts.Port (1,1) double = 8765
        opts.ControlPort (1,1) double = 8766
        opts.NodeBin (1,1) string = "node"
    end

    % 确保包路径可见(从仓库根或 matlab/ 下任意位置调用都可用)。
    here = fileparts(mfilename('fullpath'));
    if exist(fullfile(here, '+matlabcopilot'), 'dir')
        addpath(here);
    end

    % claude 后端:把"当前这个 MATLAB 会话"共享给 MCP,使 matlab-mcp-server 能 attach
    % 到面板所在实例(多实例时避免 attach 歧义)。需已安装 MATLAB MCP Server Toolbox。
    if opts.Backend == "claude"
        try
            if exist('shareMATLABSession', 'file')
                shareMATLABSession();
                mirrorSessionDetails();   % 修正 server 与 toolbox 的会话文件路径不一致
            end
        catch err
            warning('matlabcopilot:shareSession', ...
                '共享 MATLAB 会话失败(matlab 工具可能不可用): %s', err.message);
        end
    end

    p = matlabcopilot.Panel(Backend=opts.Backend, Cwd=opts.Cwd, ...
        Port=opts.Port, ControlPort=opts.ControlPort, NodeBin=opts.NodeBin);
end

function mirrorSessionDetails()
    % matlab-mcp-server 读取 "...\MathWorks\MATLAB MCP Server\v1\sessionDetails.json",
    % 而 shareMATLABSession(core-server toolkit)写到 "...\MATLAB MCP Core Server\...",
    % 两者目录名因版本不一致。把活会话文件镜像到 server 期望路径,否则 attach 失败。
    appdata = getenv('APPDATA');
    if isempty(appdata); return; end
    base = fullfile(appdata, 'MathWorks');
    src = fullfile(base, 'MATLAB MCP Core Server', 'v1', 'sessionDetails.json');
    dst = fullfile(base, 'MATLAB MCP Server', 'v1', 'sessionDetails.json');
    if isfile(src)
        dstDir = fileparts(dst);
        if ~isfolder(dstDir); mkdir(dstDir); end
        copyfile(src, dst, 'f');
    end
end
