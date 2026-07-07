classdef ModelDiff
    % 模型语义 diff:model_edit 工具执行前后,对目标块做参数快照与画布截图,
    % 生成「参数 改前→改后 / 新增块 / 删除块 / 前后截图」的结构化对比,推给 UI 渲染成卡片。
    % 目的:slx 是二进制,工程师看不见 AI 改了什么;这里把每次改动变成看得见、可核对的证据。
    %
    % 流程(Panel.trackModelDiff 驱动):
    %   tool_use(model_edit)   → candidatePaths(入参嗅探目标块) → snapshot(前)
    %   tool_result(同 id)     → snapshot(后,沿用前一次的目标) → compare → buildEvent → UI
    % Ask 模式下工具执行等待确认卡,前快照必然发生在执行前;全部操作只读,失败静默跳过。

    methods (Static)
        function tf = isEditTool(name)
            % 工具名可能是 'model_edit' 或 'mcp__matlab__model_edit' 等带前缀形态。
            tf = contains(string(name), "model_edit");
        end

        function paths = candidatePaths(input)
            % 从工具入参里嗅探"当前模型的 block 路径"(形如 model/子系统/Block)。
            paths = strings(0, 1);
            try
                model = matlabcopilot.Context.currentModel();
                if strlength(model) == 0; return; end
                strs = matlabcopilot.ModelSearch.collectStrings(input);
                for i = 1:numel(strs)
                    s = strtrim(strs(i));
                    if startsWith(s, model + "/") && strlength(s) > strlength(model) + 1
                        paths(end+1, 1) = s; %#ok<AGROW>
                    end
                end
                paths = unique(paths, 'stable');
                paths = paths(1:min(8, end));   % 一次 edit 涉及的块通常很少,截断防入参异常
            catch
            end
        end

        function snap = snapshot(paths, parentsOverride)
            % 对目标块做快照:每块的参数 dump + 其父系统的子块清单 + 父系统画布截图。
            % parentsOverride:后快照沿用前快照的父系统(目标块可能已被删除,推不出父级)。
            snap = struct();
            snap.paths = paths(:);
            snap.blocks = struct('path', {}, 'params', {});
            snap.parents = strings(0, 1);
            snap.kids = {};
            snap.shots = struct('sys', {}, 'png', {});

            parents = strings(0, 1);
            for i = 1:numel(paths)
                p = char(paths(i));
                try
                    h = getSimulinkBlockHandle(p);
                catch
                    h = -1;
                end
                if h > 0
                    snap.blocks(end+1) = struct('path', string(p), ...
                        'params', matlabcopilot.ModelDiff.dumpParams(h)); %#ok<AGROW>
                    try, parents(end+1) = string(get_param(h, 'Parent')); catch, end %#ok<AGROW>
                else
                    % 目标尚不存在(将被新建):父系统 = 路径去掉末段。
                    parents(end+1) = matlabcopilot.ModelDiff.parentOf(string(p)); %#ok<AGROW>
                end
            end
            if nargin > 1 && ~isempty(parentsOverride)
                parents = parentsOverride(:);
            end
            parents = unique(parents(strlength(parents) > 0), 'stable');
            parents = parents(1:min(2, end));   % 截图有成本,最多跟踪 2 个父系统
            for i = 1:numel(parents)
                snap.parents(end+1, 1) = parents(i);
                kids = matlabcopilot.ModelDiff.childBlocks(parents(i));
                snap.kids{end+1} = kids;
                % 大画布(>60 块)跳过截图:print 要秒级且阻塞主线程(连带拖慢 MCP 工具),
                % 而缩略图上也根本看不清;参数表/增删块清单仍完整生效。
                png = "";
                if numel(kids) <= 60
                    png = matlabcopilot.ModelDiff.pngDataUrl(parents(i));
                end
                snap.shots(end+1) = struct('sys', parents(i), 'png', png);
            end
        end

        function d = compare(before, after)
            % 前后快照对比:参数变更 + 新增/删除块(块级 + 父系统子块清单两路合并)。
            d = struct();
            d.changes = struct('block', {}, 'param', {}, 'before', {}, 'after', {});
            added = strings(0, 1); removed = strings(0, 1);

            bPaths = string({before.blocks.path});
            aPaths = string({after.blocks.path});
            for i = 1:numel(before.blocks)
                p = before.blocks(i).path;
                j = find(aPaths == p, 1);
                if isempty(j); removed(end+1) = p; continue; end %#ok<AGROW>
                bp = before.blocks(i).params; ap = after.blocks(j).params;
                names = union(string({bp.name}), string({ap.name}), 'stable');
                for k = 1:numel(names)
                    bv = matlabcopilot.ModelDiff.paramValue(bp, names(k));
                    av = matlabcopilot.ModelDiff.paramValue(ap, names(k));
                    if ~isequal(bv, av)
                        d.changes(end+1) = struct('block', p, 'param', names(k), ...
                            'before', bv, 'after', av); %#ok<AGROW>
                    end
                end
            end
            for j = 1:numel(after.blocks)
                if ~any(bPaths == after.blocks(j).path)
                    added(end+1) = after.blocks(j).path; %#ok<AGROW>
                end
            end
            % 父系统子块清单对比:捕获入参没点名的新建/删除块。
            for i = 1:numel(before.parents)
                j = find(after.parents == before.parents(i), 1);
                if isempty(j); continue; end
                kb = before.kids{i}; ka = after.kids{j};
                added   = [added;   setdiff(ka, kb)]; %#ok<AGROW>
                removed = [removed; setdiff(kb, ka)]; %#ok<AGROW>
            end
            d.added = unique(added, 'stable');
            d.removed = unique(removed, 'stable');
        end

        function ev = buildEvent(convId, id, d, before, after)
            % 组装推给 UI 的 model_diff 事件(jsonencode 友好:struct 数组用 cell 包)。
            shots = {};
            for i = 1:numel(before.shots)
                j = find(string({after.shots.sys}) == before.shots(i).sys, 1);
                aPng = ""; if ~isempty(j); aPng = after.shots(j).png; end
                if strlength(before.shots(i).png) == 0 && strlength(aPng) == 0; continue; end
                shots{end+1} = struct('sys', before.shots(i).sys, ...
                    'before', before.shots(i).png, 'after', aPng); %#ok<AGROW>
            end
            ev = struct('type', "model_diff", 'convId', char(convId), 'id', char(id), ...
                'changes', {num2cell(d.changes)}, ...
                'added', {cellstr(d.added)}, 'removed', {cellstr(d.removed)}, ...
                'shots', {shots});
        end

        % ── 内部工具 ─────────────────────────────────────────────────────
        function prm = dumpParams(h)
            % dump 一个块的对话参数(名称→字符串化取值),截断防超长。
            prm = struct('name', {}, 'value', {});
            try
                prm(end+1) = struct('name', "BlockType", ...
                    'value', string(get_param(h, 'BlockType')));
            catch
            end
            try
                dp = get_param(h, 'DialogParameters');
                if ~isstruct(dp); return; end
                f = fieldnames(dp);
                for i = 1:min(40, numel(f))
                    try
                        v = matlabcopilot.ModelDiff.stringify(get_param(h, f{i}));
                        prm(end+1) = struct('name', string(f{i}), 'value', v); %#ok<AGROW>
                    catch
                    end
                end
            catch
            end
        end

        function v = paramValue(prm, name)
            v = "";
            i = find(string({prm.name}) == name, 1);
            if ~isempty(i); v = prm(i).value; end
        end

        function s = stringify(v)
            % 参数值 → 可比较/可展示的短字符串。
            try
                if ischar(v) || isstring(v)
                    s = string(v);
                elseif isnumeric(v) || islogical(v)
                    s = string(mat2str(v, 6));
                else
                    s = string(class(v));   % 复杂对象只比类型(变化通常伴随其它参数变化)
                end
            catch
                s = "";
            end
            if strlength(s) > 200; s = extractBefore(s, 201) + "…"; end
        end

        function p = parentOf(path)
            % 路径去末段(保护块名里的转义斜杠 '//')。
            p = "";
            try
                safe = regexprep(string(path), '//', char(1));
                parts = split(safe, '/');
                if numel(parts) < 2; return; end
                p = regexprep(join(parts(1:end-1), '/'), char(1), '//');
            catch
            end
        end

        function kids = childBlocks(sys)
            % 父系统一层内的子块完整路径清单(不含自身)。
            kids = strings(0, 1);
            try
                c = find_system(char(sys), 'SearchDepth', 1, ...
                    'LookUnderMasks', 'all', 'Type', 'Block');
                kids = string(c(:));
                kids = kids(kids ~= string(sys));
            catch
            end
        end

        function url = pngDataUrl(sys)
            % 父系统画布截图 → base64 data URL(失败/超 400KB 返回 "",卡片退化为纯参数表)。
            url = "";
            f = [tempname '.png'];
            try
                print(['-s' char(sys)], '-dpng', '-r72', f);
                fid = fopen(f, 'rb'); b = fread(fid, inf, '*uint8'); fclose(fid);
                if numel(b) > 0 && numel(b) <= 400 * 1024
                    url = "data:image/png;base64," + string(matlab.net.base64encode(b));
                end
            catch
            end
            if isfile(f); try, delete(f); catch, end; end
        end
    end
end
