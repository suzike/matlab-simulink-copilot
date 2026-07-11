classdef Context
    % 上下文采集器:读取 MATLAB/Simulink 实时状态,打成一个结构体快照,
    % 随每轮用户消息发给 sidecar。所有读取都包在 try/catch 里,缺啥跳啥,
    % 绝不因为没开模型/没开编辑器而报错。

    methods (Static)
        function snap = snapshot()
            snap = struct();
            snap.activeFile       = matlabcopilot.Context.activeFile();
            snap.currentModel     = matlabcopilot.Context.currentModel();
            snap.currentModelFile = matlabcopilot.Context.currentModelFile(snap.currentModel);
            snap.currentSubsystem = matlabcopilot.Context.currentSubsystem();
            snap.selectedBlocks   = matlabcopilot.Context.selectedBlocks();
            snap.workspaceVars    = matlabcopilot.Context.workspaceVars();
            snap.lastError        = matlabcopilot.Context.lastError();
            seedPath = snap.activeFile.path;
            if strlength(string(seedPath)) == 0
                seedPath = snap.currentModelFile;
            end
            snap.projectInfo      = matlabcopilot.Context.projectInfo(seedPath);
            snap.userPaths        = matlabcopilot.Context.userPaths();
        end

        function p = userPaths()
            % 用户加载到 MATLAB 搜索路径的文件夹(排除 MATLAB 自带 toolbox 目录):
            % 让 agent 感知 addpath 进来的代码库/共享库在哪,直接读得到、引用得对。
            p = strings(0, 1);
            try
                mlroot = string(matlabroot);
                parts = string(split(string(path), pathsep));
                keep = parts(strlength(parts) > 0 & ~startsWith(parts, mlroot));
                p = keep(1:min(30, end));   % 封顶:路径极多时只带前 30 个(userpath/新加的都靠前)
            catch
            end
        end

        function f = activeFile()
            f = struct('path', "", 'name', "", 'selection', "", 'line', 0);
            try
                ed = matlab.desktop.editor.getActive();
                if isempty(ed); return; end
                f.path = string(ed.Filename);
                [~, nm, ext] = fileparts(f.path);
                f.name = string(nm) + string(ext);
                sel = ed.Selection;
                if numel(sel) >= 1; f.line = sel(1); end
                f.selection = matlabcopilot.Context.selectedText(ed);
            catch
            end
        end

        function s = currentSubsystem()
            % 当前所在子系统(可能比 bdroot 更深);无模型返回 ""。
            s = "";
            try
                sys = get_param(0, 'CurrentSystem');
                if ~isempty(sys); s = string(getfullname(sys)); end
            catch
            end
        end

        function s = selectedText(ed)
            % 从 Document 的 Selection([startLine startCol endLine endCol])
            % 与 Text 推导选中文本;无选区返回 ""。
            s = "";
            try
                sel = ed.Selection;
                if numel(sel) < 4; return; end
                if sel(1) == sel(3) && sel(2) == sel(4); return; end % 空选区
                lines = splitlines(string(ed.Text));
                sL = sel(1); sC = sel(2); eL = sel(3); eC = sel(4);
                if sL == eL
                    s = extractBetween(lines(sL), sC, eC-1);
                    if ~isempty(s); s = s(1); end
                else
                    parts = strings(0,1);
                    parts(end+1) = extractAfter(lines(sL), sC-1); %#ok<AGROW>
                    for k = sL+1:eL-1
                        parts(end+1) = lines(k); %#ok<AGROW>
                    end
                    parts(end+1) = extractBefore(lines(eL), eC); %#ok<AGROW>
                    s = strjoin(parts, newline);
                end
            catch
                s = "";
            end
        end

        function m = currentModel()
            m = "";
            try
                sys = get_param(0, 'CurrentSystem');
                if ~isempty(sys)
                    m = string(bdroot(sys));
                end
            catch
                m = "";
            end
        end

        function p = currentModelFile(model)
            % 当前模型对应的 .slx/.mdl 文件路径。只开模型、没开编辑器文件时用于推工程根。
            p = "";
            try
                model = string(model);
                if strlength(model) == 0; return; end
                fileName = get_param(char(model), 'FileName');
                if ~isempty(fileName); p = string(fileName); end
            catch
                p = "";
            end
        end

        function blocks = selectedBlocks()
            blocks = strings(0,1);
            try
                sys = get_param(0, 'CurrentSystem');
                if isempty(sys); return; end
                h = find_system(bdroot(sys), 'FindAll', 'on', 'type', 'block', ...
                    'Selected', 'on');
                for k = 1:numel(h)
                    blocks(end+1) = string(getfullname(h(k))); %#ok<AGROW>
                end
            catch
            end
        end

        function vars = workspaceVars()
            % 返回 "name (size class)" 字符串数组,只列名与规模,不带数据。
            vars = strings(0,1);
            try
                w = evalin('base', 'whos');
                for k = 1:numel(w)
                    sz = strjoin(string(w(k).size), 'x');
                    vars(end+1) = sprintf('%s (%s %s)', w(k).name, sz, w(k).class); %#ok<AGROW>
                end
            catch
            end
        end

        function e = lastError()
            e = "";
            try
                msg = lasterr();
                if ~isempty(msg)
                    e = string(msg);
                    lasterr('');  % 读取后清除,避免旧错误在不同消息间反复上报
                end
            catch
            end
        end

        function info = projectInfo(filePath)
            % 工程级上下文:项目根 + git 分支/状态 + 全工程文件索引。
            % 整体按 root 缓存 + 15s TTL:每轮 snapshot 复用,避免重复 git 双进程与递归扫描;
            % TTL 到期自动刷新,工程内文件/分支变化最多 15s 后反映。
            persistent cInfo cRoot cStamp
            info = struct('root', "", 'gitBranch', "", 'gitStatus', "", 'files', "");
            try
                root = matlabcopilot.Context.findProjectRoot(filePath);
                if isempty(root) || strlength(root) == 0; return; end
                rootC = char(root);
                ttl = 15 / 86400;   % datenum 单位为天 → 15 秒
                if ~isempty(cRoot) && strcmp(cRoot, rootC) && ~isempty(cStamp) && (now - cStamp) < ttl
                    info = cInfo; return;
                end
                info.root = root;
                [~, b] = system(sprintf('git -C "%s" branch --show-current 2>&1', root));
                b = strtrim(string(b));
                if ~startsWith(b, "fatal") && ~startsWith(b, "error")
                    info.gitBranch = b;
                end
                [~, s] = system(sprintf('git -C "%s" status -s 2>&1', root));
                s = strtrim(string(s));
                if ~startsWith(s, "fatal") && ~startsWith(s, "error")
                    lines = splitlines(s);
                    if numel(lines) > 20
                        lines = [lines(1:20); string(sprintf("… 另有 %d 个改动文件", numel(lines)-20))];
                    end
                    info.gitStatus = strjoin(lines, newline);
                end
                info.files = matlabcopilot.Context.projectFiles(root);
                cInfo = info; cRoot = rootC; cStamp = now;
            catch
            end
        end

        function txt = projectFiles(root)
            % 全工程文件索引:优先 MATLAB Project API(有内容时),否则文件系统扫描。
            % 不再单独缓存——由 projectInfo 的 TTL 缓存统一兜住。
            txt = "";
            try
                [models, code, data, src] = matlabcopilot.Context.collectProjectFiles(root);
                total = numel(models) + numel(code) + numel(data);
                if total == 0; return; end
                parts = strings(0,1);
                parts(end+1) = sprintf("来源: %s(共 %d 个文件)", src, total);
                parts(end+1) = matlabcopilot.Context.fmtClass("模型(slx/mdl)", models, 30);
                parts(end+1) = matlabcopilot.Context.fmtClass("代码(m)", code, 40);
                parts(end+1) = matlabcopilot.Context.fmtClass("数据(sldd/mat)", data, 20);
                parts = parts(strlength(parts) > 0);
                txt = strjoin(parts, newline);
            catch
            end
        end

        function [models, code, data, src] = collectProjectFiles(root)
            % 收集三类工程文件。MATLAB Project 有内容则用之;否则(含工程为空/异常)降级文件系统扫描。
            models = strings(0,1); code = strings(0,1); data = strings(0,1);
            proj = [];
            try, proj = matlab.project.rootProject; catch, end
            if ~isempty(proj)
                try
                    paths = string({proj.Files.Path});
                    for i = 1:numel(paths)
                        [~, ~, e] = fileparts(paths(i)); e = lower(e);
                        rel = matlabcopilot.Context.relPath(root, paths(i));
                        if any(e == [".slx", ".mdl"]);      models(end+1) = rel; %#ok<AGROW>
                        elseif e == ".m";                   code(end+1)   = rel; %#ok<AGROW>
                        elseif any(e == [".sldd", ".mat"]); data(end+1)   = rel; %#ok<AGROW>
                        end
                    end
                    if (numel(models) + numel(code) + numel(data)) > 0
                        src = "MATLAB Project"; return;   % 有内容才用 Project,否则继续降级
                    end
                catch
                    % Project 读取异常 → 落到下方文件系统兜底(会无条件重新赋值)
                end
            end
            % 文件系统兜底(工程未打开/为空/读取异常):递归剪枝扫描。
            models = matlabcopilot.Context.listByExt(root, [".slx", ".mdl"]);
            code   = matlabcopilot.Context.listByExt(root, ".m");
            data   = matlabcopilot.Context.listByExt(root, [".sldd", ".mat"]);
            src = "文件系统";
        end

        function rels = listByExt(root, exts)
            % 递归扫描指定扩展名,每次调用上限 150。进入子目录前按目录名精确剪枝,
            % 不会递归遍历 slprj/codegen 等生成目录(避免大工程下全树枚举撑爆耗时/内存)。
            rels = strings(0,1);
            try
                rels = matlabcopilot.Context.scanDir(char(root), char(root), lower(string(exts)), 150);
            catch
            end
        end

        function rels = scanDir(root, d, exts, cap)
            % 深度优先递归;skip 列表按「目录名整段相等」剪枝(非子串,避免误杀 codegen_utils 等)。
            skip = ["slprj", ".git", ".svn", "codegen", "+sfun", "resources", "node_modules"];
            rels = strings(0,1);
            items = dir(d);
            for i = 1:numel(items)
                nm = items(i).name;
                if nm == "." || nm == ".."; continue; end
                if items(i).isdir
                    if any(string(nm) == skip); continue; end
                    rels = [rels; matlabcopilot.Context.scanDir(root, fullfile(d, nm), exts, cap)]; %#ok<AGROW>
                    if numel(rels) >= cap; rels = rels(1:cap); return; end
                else
                    [~, ~, e] = fileparts(nm);
                    if any(lower(string(e)) == exts)
                        % 必须 (end+1,1) 强制列向量,否则标量后退化成行向量,与 [rels; sub] 纵向拼接维度冲突。
                        rels(end+1, 1) = matlabcopilot.Context.relPath(root, string(fullfile(d, nm))); %#ok<AGROW>
                        if numel(rels) >= cap; return; end
                    end
                end
            end
        end

        function r = relPath(root, full)
            % 把绝对路径转成相对工程根的路径。先把 \ 与 / 归一化为 /(root 与 fullfile 结果
            % 常斜杠方向不一致),Windows 再忽略大小写比较。输出统一用 / 分隔。
            rn = replace(string(full), '\', '/');
            rootn = replace(string(root), '\', '/');
            matched = (ispc && startsWith(lower(rn), lower(rootn))) || (~ispc && startsWith(rn, rootn));
            if matched
                r = extractAfter(rn, strlength(rootn));
                r = regexprep(r, '^/+', '');
            else
                r = rn;
            end
        end

        function s = fmtClass(label, arr, n)
            % 格式化一类文件:label [总数]: 前 n 个文件名 … +剩余。
            s = "";
            if isempty(arr); return; end
            shown = arr(1:min(n, numel(arr)));
            s = sprintf("%s [%d]: %s", label, numel(arr), strjoin(shown, ", "));
            if numel(arr) > n
                s = s + sprintf(" … +%d", numel(arr) - n);
            end
        end

        function root = findProjectRoot(filePath)
            % 从当前文件向上找到含 .git 目录或 .prj 文件的工程根。
            root = "";
            try
                d = fileparts(char(filePath));
                if isempty(d); return; end
                for k = 1:10
                    if exist(fullfile(d, '.git'), 'dir')
                        root = string(d); return;
                    end
                    prjs = dir(fullfile(d, '*.prj'));
                    if ~isempty(prjs)
                        root = string(d); return;
                    end
                    parent = fileparts(d);
                    if strcmp(parent, d); break; end
                    d = parent;
                end
            catch
            end
        end
    end
end
