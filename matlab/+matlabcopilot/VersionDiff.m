classdef VersionDiff
    % 模型版本语义对比:当前打开的模型 vs git 某个历史版本(如 HEAD~1 / 分支 / commit)。
    % slx 是二进制,GitLab MR 上看不出改了什么;这里把两版模型加载后做结构/参数级对比,
    % 复用 ModelDiff 的参数 dump 与截图,产出与 model_edit 核验同款的 model_diff 卡片。
    %
    % 流程:git archive <ref> <模型相对路径> → 临时目录另存为 <name>__ref.slx(Simulink 模型名
    % 随文件名,天然避免同名冲突)→ 两版各做全量块快照 → 对比 → 事件。全程只读不落库。

    methods (Static)
        function ev = compare(model, ref, cwd, convId)
            m = char(model);
            ref = matlabcopilot.VersionDiff.validateRef(ref);
            f = get_param(m, 'FileName');
            if isempty(f)
                error('模型 %s 尚未保存到文件,无法做版本对比。', m);
            end
            rel = matlabcopilot.VersionDiff.relPath(f, cwd);
            workDir = tempname;
            mkdir(workDir);
            tarFile = [tempname '.tar'];
            tmp = fullfile(workDir, [m '__ref' matlabcopilot.VersionDiff.extOf(f)]);
            cleanupObj = onCleanup(@() matlabcopilot.VersionDiff.cleanup([m '__ref'], workDir, tarFile));

            % git show 会把二进制模型走 stdout/重定向;archive 直接写 tar,避免文本通道破坏 slx。
            gitRel = strrep(rel, '\', '/');
            cmd = sprintf('git -C %s archive --format=tar -o %s %s -- %s', ...
                matlabcopilot.VersionDiff.cmdQuote(cwd), ...
                matlabcopilot.VersionDiff.cmdQuote(tarFile), ...
                matlabcopilot.VersionDiff.cmdQuote(ref), ...
                matlabcopilot.VersionDiff.cmdQuote(gitRel));
            [rc, out] = system(cmd);
            if rc ~= 0
                error('git archive 失败(ref=%s): %s', char(ref), strtrim(out));
            end
            untar(tarFile, workDir);
            archived = matlabcopilot.VersionDiff.archivedPath(workDir, gitRel);
            if ~isfile(archived)
                error('git archive 解包后未找到模型文件: %s', gitRel);
            end
            copyfile(archived, tmp);
            load_system(tmp);
            refName = [m '__ref'];

            cur = matlabcopilot.VersionDiff.snapModel(m);
            old = matlabcopilot.VersionDiff.snapModel(refName);
            d = matlabcopilot.VersionDiff.compareSnaps(old, cur);   % old→cur:视角是"这次改了什么"

            shots = {};
            pOld = matlabcopilot.ModelDiff.pngDataUrl(refName);
            pCur = matlabcopilot.ModelDiff.pngDataUrl(m);
            if strlength(pOld) > 0 || strlength(pCur) > 0
                shots{end+1} = struct('sys', string(m) + "(根层)", 'before', pOld, 'after', pCur);
            end
            ev = struct('type', "model_diff", 'convId', char(convId), 'id', 'vdiff', ...
                'title', ['版本对比 ' char(ref) ' → 工作区'], ...
                'changes', {num2cell(d.changes)}, ...
                'added', {cellstr(d.added)}, 'removed', {cellstr(d.removed)}, ...
                'shots', {shots});
        end

        function snap = snapModel(mdl)
            % 全量块快照(相对路径,便于跨模型名对比):路径 → 参数 dump。
            snap = struct('blocks', struct('path', {}, 'params', {}));
            blks = find_system(mdl, 'FollowLinks', 'off', 'LookUnderMasks', 'none', 'Type', 'Block');
            blks = blks(1:min(400, end));   % 超大模型封顶(对比重点是变更,不是全清单)
            base = strlength(string(mdl)) + 1;
            for i = 1:numel(blks)
                try
                    h = getSimulinkBlockHandle(blks{i});
                    rel = extractAfter(string(blks{i}), base);   % 去掉 "<模型名>/" 前缀
                    snap.blocks(end+1) = struct('path', rel, ...
                        'params', matlabcopilot.ModelDiff.dumpParams(h)); %#ok<AGROW>
                catch
                end
            end
        end

        function d = compareSnaps(old, cur)
            % 以相对路径对齐两版块集合:参数变更 / 新增 / 删除(封顶防刷屏)。
            d = struct();
            d.changes = struct('block', {}, 'param', {}, 'before', {}, 'after', {});
            oP = string({old.blocks.path}); cP = string({cur.blocks.path});
            d.removed = setdiff(oP, cP, 'stable');
            d.added   = setdiff(cP, oP, 'stable');
            common = intersect(oP, cP, 'stable');
            for i = 1:min(150, numel(common))
                bo = old.blocks(oP == common(i)).params;
                bc = cur.blocks(cP == common(i)).params;
                names = union(string({bo.name}), string({bc.name}), 'stable');
                for k = 1:numel(names)
                    bv = matlabcopilot.ModelDiff.paramValue(bo, names(k));
                    av = matlabcopilot.ModelDiff.paramValue(bc, names(k));
                    if ~isequal(bv, av)
                        d.changes(end+1) = struct('block', common(i), 'param', names(k), ...
                            'before', bv, 'after', av); %#ok<AGROW>
                    end
                    if numel(d.changes) >= 120; break; end
                end
                if numel(d.changes) >= 120; break; end
            end
            d.added = d.added(1:min(60, end));
            d.removed = d.removed(1:min(60, end));
        end

        % ── 内部 ────────────────────────────────────────────────────────
        function rel = relPath(f, cwd)
            if nargin < 2 || strlength(string(cwd)) == 0
                cwd = pwd;
            end
            filePath = strrep(char(f), '\', '/');
            rootPath = regexprep(strrep(char(cwd), '\', '/'), '/+$', '');
            prefix = [lower(rootPath) '/'];
            if startsWith(lower(filePath), prefix)
                rel = filePath(numel(rootPath) + 2:end);
            else
                error('模型文件不在当前 Git 工作目录内: %s', char(f));
            end
        end

        function p = archivedPath(workDir, gitRel)
            parts = strsplit(strrep(char(gitRel), '\', '/'), '/');
            p = fullfile(char(workDir), parts{:});
        end

        function q = cmdQuote(v)
            s = char(v);
            if contains(s, '"')
                error('命令参数包含不支持的双引号: %s', s);
            end
            q = ['"' s '"'];
        end

        function ref = validateRef(value)
            % 只接受常见 commit/branch/tree-ish 形式，且首字符不能是 '-'。
            % 引号无法阻止 git 把 "--remote=..." 当选项，因此必须在拼命令前做白名单。
            ref = strtrim(char(string(value)));
            if isempty(ref) || numel(ref) > 200 || ...
                    isempty(regexp(ref, '^[A-Za-z0-9][A-Za-z0-9._/~^+\-]*$', 'once'))
                error('无效 Git ref。仅支持 commit、分支名及 HEAD~N/HEAD^N 形式。');
            end
        end

        function e = extOf(f)
            [~, ~, e] = fileparts(char(f));
            if isempty(e); e = '.slx'; end
        end

        function cleanup(refName, workDir, tarFile)
            try
                if bdIsLoaded(refName)
                    close_system(refName, 0);
                end
            catch
            end
            try
                if isfile(tarFile)
                    delete(tarFile);
                end
            catch
            end
            try
                if isfolder(workDir)
                    rmdir(workDir, 's');
                end
            catch
            end
        end
    end
end
