function report = setupMATLABCopilot(action, opts)
% SETUPMATLABCOPILOT  检查或修复 MATLAB-Copilot 的持久化入口路径。
%
%   setupMATLABCopilot("status")
%   setupMATLABCopilot("repair")
%   setupMATLABCopilot("uninstall")
%
% 只管理 MATLAB-Copilot 自己的路径和 startup.m 标记块，不改写其他启动配置。
    arguments
        action (1,1) string {mustBeMember(action,["status","install","repair","uninstall"])} = "status"
        opts.Root (1,1) string = string(fileparts(mfilename('fullpath')))
        opts.StartupFile (1,1) string = ""
        opts.Persistence (1,1) string {mustBeMember(opts.Persistence,["auto","pathdef","startup"])} = "auto"
        opts.ApplyPath (1,1) logical = true
    end

    root = canonical(opts.Root);
    startupFile = opts.StartupFile;
    if strlength(startupFile) == 0
        startupFile = fullfile(primaryUserPath(), "startup.m");
    else
        startupFile = canonicalParent(opts.StartupFile);
    end

    switch action
        case {"install", "repair"}
            if ~isfolder(root)
                error('matlabcopilot:setupRoot', 'MATLAB-Copilot 路径不存在: %s', root);
            end
            if opts.ApplyPath && ~pathContains(root); addpath(root); end
            method = opts.Persistence;
            if method == "auto"
                % Add-On 替换后 savepath 可能返回成功，但新进程仍未挂载工具箱路径。
                % auto 始终使用可验证、可删除的用户 startup 标记块。
                method = "startup";
            elseif method == "pathdef"
                if savepath ~= 0
                    error('matlabcopilot:savePath', '无法写入 MATLAB pathdef，请改用 Persistence="startup"。');
                end
            end
            if method == "startup"; writeManagedStartup(startupFile, root); end
        case "uninstall"
            if pathContains(root); rmpath(root); end
            removeManagedStartup(startupFile);
            if opts.Persistence ~= "startup"; savepath; end
    end

    report = inspect(root, startupFile);
    report.action = char(action);
    if action ~= "status"
        if action == "uninstall" && ~report.onPath && ~report.startupManaged
            fprintf('MATLAB-Copilot 持久化路径已移除。\n');
        elseif report.ok
            fprintf('MATLAB-Copilot 路径状态正常: %s\n', root);
        else
            warning('matlabcopilot:setupIncomplete', '路径配置尚未生效，请重启 MATLAB 后运行 setupMATLABCopilot("status")。');
        end
    end
end

function report = inspect(root, startupFile)
    installed = false; installedVersion = "";
    try
        items = matlab.addons.toolbox.installedToolboxes;
        hit = strcmpi(string(items.Name), "MATLAB-Copilot");
        installed = any(hit);
        if installed; installedVersion = string(items.Version(find(hit, 1))); end
    catch
    end
    report = struct('schemaVersion', 1, 'root', char(root), ...
        'startupFile', char(startupFile), 'onPath', pathContains(root), ...
        'entryVisible', exist('copilot', 'file') == 2, ...
        'startupManaged', hasManagedStartup(startupFile), ...
        'toolboxInstalled', installed, 'toolboxVersion', char(installedVersion));
    report.ok = report.onPath && (report.entryVisible || isfile(fullfile(root, 'copilot.m')));
end

function tf = pathContains(root)
    parts = string(strsplit(path, pathsep));
    tf = any(strcmpi(parts, root));
end

function folder = primaryUserPath()
    raw = string(userpath);
    parts = split(raw, pathsep); parts(parts == "") = [];
    if isempty(parts); folder = string(fullfile(prefdir, "MATLAB")); else; folder = parts(1); end
    if ~isfolder(folder); mkdir(folder); end
end

function writeManagedStartup(file, root)
    beginMark = "% MATLAB-Copilot managed path begin";
    endMark = "% MATLAB-Copilot managed path end";
    text = readText(file);
    text = removeBlock(text, beginMark, endMark);
    escaped = replace(root, "'", "''");
    block = beginMark + newline + "if isfolder('" + escaped + "'); addpath('" + escaped + "'); end" + newline + endMark;
    if strlength(strtrim(text)) > 0; text = stripTrailingNewlines(text) + newline + newline; end
    writeText(file, text + block + newline);
end

function removeManagedStartup(file)
    if ~isfile(file); return; end
    beginMark = "% MATLAB-Copilot managed path begin";
    endMark = "% MATLAB-Copilot managed path end";
    text = removeBlock(readText(file), beginMark, endMark);
    writeText(file, stripTrailingNewlines(text) + newline);
end

function tf = hasManagedStartup(file)
    tf = isfile(file) && contains(readText(file), "% MATLAB-Copilot managed path begin");
end

function out = removeBlock(text, beginMark, endMark)
    pattern = "(?s)" + string(regexptranslate('escape', beginMark)) + ".*?" + ...
        string(regexptranslate('escape', endMark)) + "[\r\n]*";
    out = string(regexprep(char(text), char(pattern), ''));
end

function out = stripTrailingNewlines(text)
    out = string(regexprep(char(text), '[\r\n]+$', ''));
end

function text = readText(file)
    if isfile(file); text = string(fileread(file)); else; text = ""; end
end

function writeText(file, text)
    folder = fileparts(file); if ~isfolder(folder); mkdir(folder); end
    fid = fopen(file, 'w', 'n', 'UTF-8');
    if fid < 0; error('matlabcopilot:startupWrite', '无法写入 %s', file); end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fwrite(fid, char(text), 'char');
end

function value = canonical(value)
    value = string(java.io.File(char(value)).getCanonicalPath());
end

function value = canonicalParent(value)
    file = java.io.File(char(value));
    value = string(fullfile(char(file.getCanonicalFile().getParent()), char(file.getName())));
end
