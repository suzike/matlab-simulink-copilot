function report = release_acceptance(toolboxFile, opts)
% RELEASE_ACCEPTANCE  验收最终 .mltbx，而不是仓库源码。
%
%   report = release_acceptance("MATLAB-Copilot.mltbx")
%   report = release_acceptance("MATLAB-Copilot.mltbx", ReportFile="_verify/matlab-release-acceptance.json")
%
% 默认只解包到临时目录并验证包内 MATLAB/Node/UI 入口、checkcode、类加载、
% copilot_doctor 和 Echo TCP 全链路，不修改已安装 Add-On。只有显式设置
% InstallPackage=true 才执行安装；检测到同名工具箱时还需 AllowReplace=true。
    arguments
        toolboxFile (1,1) string
        opts.ReportFile (1,1) string = ""
        opts.ExpectedVersion (1,1) string = ""
        opts.InstallPackage (1,1) logical = false
        opts.AllowReplace (1,1) logical = false
        opts.RunDoctor (1,1) logical = true
    end

    toolboxFile = string(java.io.File(char(toolboxFile)).getCanonicalPath());
    gates = repmat(emptyGate(), 0, 1);
    started = datetime('now', 'TimeZone', 'local');
    unpackDir = string(tempname);
    mkdir(unpackDir);
    cleanupDir = onCleanup(@() cleanupPackage(unpackDir)); %#ok<NASGU>

    if ~isfile(toolboxFile)
        gates(end+1) = failGate("MAT-001", "安装包存在", "文件不存在: " + toolboxFile); %#ok<AGROW>
        report = finishReport();
        writeReport(report, opts.ReportFile);
        return;
    end
    gates(end+1) = passGate("MAT-001", "安装包存在", toolboxFile); %#ok<AGROW>

    try
        unzip(toolboxFile, unpackDir);
        packageRoot = fullfile(unpackDir, "fsroot");
        required = [
            "ui/index.html"
            "matlab/copilot.m"
            "matlab/copilot_doctor.m"
            "matlab/resources/icons/copilot_16.png"
            "matlab/resources/icons/copilot_24.png"
            "sidecar/src/index.js"
            "sidecar/src/permissionServer.js"
            "sidecar/src/matlabPermissionProxy.js"
            "sidecar/src/projectChangeRecorder.js"
            "matlab/+matlabcopilot/ChangeTransaction.m"
            "matlab/+matlabcopilot/ModelFileDiff.m"
        ];
        missing = required(~arrayfun(@(p) isfile(fullfile(packageRoot, p)), required));
        if isempty(missing)
            gates(end+1) = passGate("MAT-002", "安装包关键文件", strjoin(required, ", ")); %#ok<AGROW>
        else
            gates(end+1) = failGate("MAT-002", "安装包关键文件", "缺少: " + strjoin(missing, ", ")); %#ok<AGROW>
        end
    catch err
        gates(end+1) = failGate("MAT-002", "安装包解压", string(err.message)); %#ok<AGROW>
        report = finishReport();
        writeReport(report, opts.ReportFile);
        return;
    end

    [forbiddenOk, forbiddenDetail] = scanForbidden(packageRoot);
    if forbiddenOk
        gates(end+1) = passGate("MAT-003", "安装包污染扫描", "未发现 node_modules、临时目录或嵌套安装包"); %#ok<AGROW>
    else
        gates(end+1) = failGate("MAT-003", "安装包污染扫描", forbiddenDetail); %#ok<AGROW>
    end

    packageJson = jsondecode(fileread(fullfile(packageRoot, "sidecar", "package.json")));
    actualVersion = string(packageJson.version);
    expectedVersion = opts.ExpectedVersion;
    if strlength(expectedVersion) == 0; expectedVersion = actualVersion; end
    buildText = fileread(fullfile(packageRoot, "matlab", "build_toolbox.m"));
    token = regexp(buildText, 'ToolboxVersion\s*=\s*"([^"]+)"', 'tokens', 'once');
    buildVersion = "";
    if ~isempty(token); buildVersion = string(token{1}); end
    if actualVersion == expectedVersion && buildVersion == expectedVersion
        gates(end+1) = passGate("MAT-004", "安装包版本一致性", actualVersion); %#ok<AGROW>
    else
        gates(end+1) = failGate("MAT-004", "安装包版本一致性", ...
            "expected=" + expectedVersion + ", package=" + actualVersion + ", build=" + buildVersion); %#ok<AGROW>
    end

    matlabDir = fullfile(packageRoot, "matlab");
    addpath(matlabDir);
    try
        classes = dir(fullfile(matlabDir, "+matlabcopilot", "*.m"));
        failures = strings(0, 1);
        for i = 1:numel(classes)
            className = "matlabcopilot." + erase(string(classes(i).name), ".m");
            try
                if isempty(meta.class.fromName(className)); failures(end+1) = className; end %#ok<AGROW>
            catch err
                failures(end+1) = className + ": " + string(err.message); %#ok<AGROW>
            end
        end
        if isempty(failures)
            gates(end+1) = passGate("MAT-005", "MATLAB 类加载", string(numel(classes)) + " 个类"); %#ok<AGROW>
        else
            gates(end+1) = failGate("MAT-005", "MATLAB 类加载", strjoin(failures, "; ")); %#ok<AGROW>
        end
    catch err
        gates(end+1) = failGate("MAT-005", "MATLAB 类加载", string(err.message)); %#ok<AGROW>
    end

    try
        files = [dir(fullfile(matlabDir, "*.m")); dir(fullfile(matlabDir, "+matlabcopilot", "*.m"))];
        issues = 0;
        for i = 1:numel(files)
            messages = checkcode(fullfile(files(i).folder, files(i).name), '-id');
            issues = issues + numel(messages);
        end
        gates(end+1) = passGate("MAT-006", "MATLAB checkcode 可执行", ...
            string(numel(files)) + " 个文件，" + string(issues) + " 条静态建议"); %#ok<AGROW>
    catch err
        gates(end+1) = failGate("MAT-006", "MATLAB checkcode 可执行", string(err.message)); %#ok<AGROW>
    end

    if opts.RunDoctor
        try
            doctor = copilot_doctor();
            if doctor.ok
                gates(end+1) = passGate("MAT-007", "copilot_doctor", string(doctor.passed) + " 项通过"); %#ok<AGROW>
            else
                gates(end+1) = failGate("MAT-007", "copilot_doctor", ...
                    string(doctor.failed) + " 项失败"); %#ok<AGROW>
            end
        catch err
            gates(end+1) = failGate("MAT-007", "copilot_doctor", string(err.message)); %#ok<AGROW>
        end
    end

    try
        echoDetail = runEcho(packageRoot);
        gates(end+1) = passGate("MAT-008", "Echo TCP 全链路", echoDetail); %#ok<AGROW>
    catch err
        gates(end+1) = failGate("MAT-008", "Echo TCP 全链路", string(err.message)); %#ok<AGROW>
    end

    if opts.InstallPackage
        rmpath(matlabDir);
        sourceMatlabDir = fileparts(mfilename('fullpath'));
        if contains(path, sourceMatlabDir); rmpath(sourceMatlabDir); end
        clear('copilot');
        gates(end+1) = installPackage(toolboxFile, actualVersion, opts.AllowReplace); %#ok<AGROW>
    else
        gates(end+1) = waivedGate("MAT-009", "Add-On 注册安装", "未指定 InstallPackage=true，保持当前 MATLAB 环境不变"); %#ok<AGROW>
    end

    report = finishReport();
    writeReport(report, opts.ReportFile);

    function result = finishReport()
        statuses = string({gates.status});
        result = struct( ...
            'schema_version', 1, ...
            'generated_at', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX')), ...
            'started_at', char(started), ...
            'matlab_version', version, ...
            'toolbox_file', char(toolboxFile), ...
            'sha256', char(fileHash(toolboxFile)), ...
            'status', char(ternary(any(statuses == "FAIL"), "FAIL", "PASS")), ...
            'gates', gates);
    end
end

function detail = runEcho(packageRoot)
    ports = [freePort(), freePort()];
    while ports(2) == ports(1); ports(2) = freePort(); end
    events = {};
    bridge = matlabcopilot.Bridge(fullfile(packageRoot, "sidecar"), packageRoot, ...
        Backend="echo", Port=ports(1), ControlPort=ports(2));
    cleanupBridge = onCleanup(@() delete(bridge)); %#ok<NASGU>
    bridge.OnMessage = @capture;
    bridge.start();
    bridge.send(struct('type', 'user_message', 'id', 'release-smoke', ...
        'convId', 'release-smoke', 'text', 'release acceptance echo', ...
        'context', struct(), 'config', struct('backend', 'echo')));
    deadline = tic;
    while toc(deadline) < 15
        drawnow;
        pause(0.05);
        types = cellfun(@(x) string(x.type), events);
        if any(types == "result"); break; end
    end
    types = cellfun(@(x) string(x.type), events);
    required = ["ready", "assistant_start", "assistant_delta", "assistant_stop", "result"];
    missing = required(~arrayfun(@(x) any(types == x), required));
    if ~isempty(missing); error('matlabcopilot:releaseEcho', 'Echo 缺少事件: %s', strjoin(missing, ', ')); end
    results = events(types == "result");
    if ~logical(results{end}.ok); error('matlabcopilot:releaseEcho', 'Echo RESULT ok=false'); end
    detail = string(numel(events)) + " 个事件，收尾 RESULT ok=true";

    function capture(msg)
        events{end+1} = msg; %#ok<AGROW>
    end
end

function gate = installPackage(toolboxFile, expectedVersion, allowReplace)
    identifier = "7c5cff00-c0de-4a11-9a2b-0c0de1100001";
    try
        addons = matlab.addons.installedAddons;
        ids = strings(height(addons), 1);
        if any(strcmp(addons.Properties.VariableNames, 'Identifier')); ids = string(addons.Identifier); end
        names = strings(height(addons), 1);
        if any(strcmp(addons.Properties.VariableNames, 'Name')); names = string(addons.Name); end
        hit = find(ids == identifier | names == "MATLAB-Copilot", 1);
        if ~isempty(hit) && ~allowReplace
            gate = failGate("MAT-009", "Add-On 注册安装", ...
                "已安装 MATLAB-Copilot；如确认替换，请显式设置 AllowReplace=true");
            return;
        end
        if ~isempty(hit); matlab.addons.uninstall(char(ids(hit))); end
        matlab.addons.toolbox.installToolbox(char(toolboxFile), true);
        addons = matlab.addons.installedAddons;
        ids = string(addons.Identifier);
        hit = find(ids == identifier, 1);
        if isempty(hit); error('安装后未找到工具箱标识'); end
        installedVersion = string(addons.Version(hit));
        if installedVersion ~= expectedVersion
            error('安装版本 %s 与期望 %s 不一致', installedVersion, expectedVersion);
        end
        % Replacing an add-on with the same identifier can leave the path cache
        % registered as enabled but not mounted in a fresh MATLAB process.
        matlab.addons.disableAddon(char(identifier));
        matlab.addons.enableAddon(char(identifier));
        addons = matlab.addons.installedAddons;
        ids = string(addons.Identifier);
        hit = find(ids == identifier, 1);
        if any(strcmp(addons.Properties.VariableNames, 'Enabled'))
            enabled = addons.Enabled(hit);
            if iscell(enabled); enabled = enabled{1}; end
            if islogical(enabled); enabledOk = enabled;
            else; enabledOk = any(strcmpi(string(enabled), ["true", "on", "enabled", "1"]));
            end
            if ~enabledOk; error('工具箱已注册但未启用'); end
        end
        rehash toolboxcache;
        entry = string(which('copilot'));
        if strlength(entry) == 0 || ~contains(lower(entry), lower("MATLAB Add-Ons"))
            error('安装后 copilot 入口未解析到 Add-On 目录: %s', entry);
        end
        addpath(fileparts(entry));
        if savepath ~= 0
            error('无法把工具箱入口持久写入用户 MATLAB path');
        end
        gate = passGate("MAT-009", "Add-On 注册安装", "已安装 " + installedVersion + "，入口=" + entry);
    catch err
        gate = failGate("MAT-009", "Add-On 注册安装", string(err.message));
    end
end

function [ok, detail] = scanForbidden(root)
    all = dir(fullfile(root, "**", "*"));
    rels = strings(0, 1);
    for i = 1:numel(all)
        rel = erase(string(fullfile(all(i).folder, all(i).name)), string(root) + filesep);
        rels(end+1, 1) = replace(rel, "\\", "/"); %#ok<AGROW>
    end
    bad = rels(contains("/" + rels + "/", ["/node_modules/", "/_verify/", "/_nm_bak/", ...
        "/.git/", "/.github/", "/.playwright-mcp/", "/scripts/", "/test/", "/test-ui/", "/slprj/"]) | ...
        endsWith(rels, ["playwright.config.mjs", ".log", ".tmp", ".slxc", ".mltbx"], IgnoreCase=true));
    ok = isempty(bad);
    detail = strjoin(bad, ", ");
end

function p = freePort()
    socket = java.net.ServerSocket(0);
    cleanup = onCleanup(@() socket.close()); %#ok<NASGU>
    p = socket.getLocalPort();
end

function hash = fileHash(file)
    hash = "";
    if ~isfile(file); return; end
    fid = fopen(file, 'rb');
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    bytes = fread(fid, Inf, '*uint8');
    digest = java.security.MessageDigest.getInstance('SHA-256');
    digest.update(bytes);
    raw = typecast(digest.digest(), 'uint8');
    hash = upper(string(reshape(dec2hex(raw, 2).', 1, [])));
end

function writeReport(report, reportFile)
    if strlength(reportFile) == 0; return; end
    reportFile = string(java.io.File(char(reportFile)).getCanonicalPath());
    folder = fileparts(reportFile);
    if ~isfolder(folder); mkdir(folder); end
    fid = fopen(reportFile, 'w', 'n', 'UTF-8');
    if fid < 0; error('matlabcopilot:releaseReport', '无法写报告: %s', reportFile); end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fwrite(fid, jsonencode(report, PrettyPrint=true), 'char');
end

function cleanupPackage(folder)
    try
        matlabDir = fullfile(folder, "fsroot", "matlab");
        entries = string(strsplit(path, pathsep));
        if any(entries == matlabDir); rmpath(matlabDir); end
        if isfolder(folder); rmdir(folder, 's'); end
    catch
    end
end

function gate = emptyGate()
    gate = struct('gate_id', '', 'gate_name', '', 'status', '', 'blocking', true, ...
        'evidence', '', 'failure_reason', '', 'required_action', '');
end

function gate = passGate(id, name, evidence)
    gate = emptyGate(); gate.gate_id = char(id); gate.gate_name = char(name);
    gate.status = 'PASS'; gate.evidence = char(evidence);
end

function gate = failGate(id, name, reason)
    gate = emptyGate(); gate.gate_id = char(id); gate.gate_name = char(name);
    gate.status = 'FAIL'; gate.failure_reason = char(reason); gate.required_action = '修复后重新运行 release_acceptance';
end

function gate = waivedGate(id, name, reason)
    gate = emptyGate(); gate.gate_id = char(id); gate.gate_name = char(name);
    gate.status = 'WAIVED'; gate.blocking = false; gate.evidence = char(reason);
end

function out = ternary(condition, yesValue, noValue)
    if condition; out = yesValue; else; out = noValue; end
end
