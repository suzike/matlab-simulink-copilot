classdef ReqTrace
    % 需求双向追溯(锚定真实需求 ID,非 LLM 反推):
    %   需求源:项目根 requirements.csv(飞书多维表格原生「导出 CSV」即可)或 requirements.json;
    %   锚定关系:项目根 req_links.json —— { "<model>": { "<block完整路径>": ["REQ-001", ...] } }。
    % 两个文件都是纯文本:可进 git、可 code review、团队可协作维护——追溯证据本身可审计。
    %
    % CSV 约定:含表头,前三列依次为 需求ID / 标题 / 描述(飞书导出时把这三列排前面即可;
    % 也兼容表头名含 id/标题/title/描述/desc 的自动识别)。
    % 锚定操作:面板里选中 block → 追溯卡上输入需求 ID → 写入 req_links.json(本地文件,即时生效)。

    methods (Static)
        function [reqs, src] = loadRequirements(cwd)
            % 读需求清单。返回 struct 数组 {id,title,text} 与来源文件名;无文件 → 空。
            reqs = struct('id', {}, 'title', {}, 'text', {});
            src = "";
            base = char(cwd);
            fj = fullfile(base, 'requirements.json');
            fc = fullfile(base, 'requirements.csv');
            try
                if isfile(fj)
                    raw = jsondecode(fileread(fj));
                    if isstruct(raw); raw = num2cell(raw); end
                    for i = 1:numel(raw)
                        r = raw{i};
                        reqs(end+1) = struct( ...
                            'id', string(matlabcopilot.ReqTrace.pick(r, ["id", "ID", "reqId"])), ...
                            'title', string(matlabcopilot.ReqTrace.pick(r, ["title", "标题", "name"])), ...
                            'text', string(matlabcopilot.ReqTrace.pick(r, ["text", "描述", "desc", "description"]))); %#ok<AGROW>
                    end
                    src = "requirements.json";
                elseif isfile(fc)
                    T = readtable(fc, 'Delimiter', ',', 'TextType', 'string', ...
                        'VariableNamingRule', 'preserve');
                    vn = string(T.Properties.VariableNames);
                    ci = matlabcopilot.ReqTrace.colOf(vn, ["id", "ID", "需求ID", "编号"], 1);
                    ct = matlabcopilot.ReqTrace.colOf(vn, ["title", "标题", "名称", "name"], 2);
                    cd = matlabcopilot.ReqTrace.colOf(vn, ["text", "描述", "desc", "description", "内容"], 3);
                    for i = 1:height(T)
                        id = strtrim(string(T{i, ci}));
                        if strlength(id) == 0; continue; end
                        ti = ""; if ct <= width(T); ti = string(T{i, ct}); end
                        de = ""; if cd <= width(T); de = string(T{i, cd}); end
                        reqs(end+1) = struct('id', id, 'title', ti, 'text', de); %#ok<AGROW>
                    end
                    src = "requirements.csv";
                end
            catch
                if isfile(fj)
                    src = "requirements.json(读取失败)";
                elseif isfile(fc)
                    src = "requirements.csv(读取失败)";
                end
            end
            if ~isempty(reqs)
                ids = strtrim(string({reqs.id}));
                reqs = reqs(strlength(ids) > 0);
                [~, keep] = unique(strtrim(string({reqs.id})), 'stable');
                reqs = reqs(sort(keep));
            end
            reqs = reqs(1:min(300, end));   % 封顶,防超大需求库刷爆 UI
        end

        function [links, valid] = loadLinks(cwd)
            % 读锚定关系(containers.Map: blockPath → reqIds string 数组;按当前接口扁平存)。
            links = struct();
            valid = true;
            f = fullfile(char(cwd), 'req_links.json');
            try
                if isfile(f)
                    links = jsondecode(fileread(f));
                    valid = matlabcopilot.ReqTrace.validLinks(links);
                    if ~valid; links = struct(); end
                end
            catch
                links = struct();
                valid = false;
            end
        end

        function ok = linkBlock(cwd, model, blockPath, reqId, unlink)
            % 把一个 block 锚定到/解除锚定一个需求 ID,写回 req_links.json。
            ok = false;
            try
                [links, valid] = matlabcopilot.ReqTrace.loadLinks(cwd);
                if ~valid; return; end   % 损坏文件必须人工修复，禁止当空文件覆盖
                mf = matlab.lang.makeValidName(char(model));      % jsondecode/encode 字段名安全
                if ~isfield(links, mf); links.(mf) = struct(); end
                [bf, found] = matlabcopilot.ReqTrace.blockField(links.(mf), blockPath);
                if unlink && ~found; ok = true; return; end
                entry = struct('path', char(blockPath), 'reqs', {{}});
                if found; entry = links.(mf).(bf); end
                ids = string(entry.reqs);
                if unlink
                    ids = ids(ids ~= string(reqId));
                else
                    ids = unique([ids(:); string(reqId)], 'stable');
                end
                if unlink && isempty(ids)
                    links.(mf) = rmfield(links.(mf), bf);
                    if isempty(fieldnames(links.(mf))); links = rmfield(links, mf); end
                else
                    entry.reqs = cellstr(ids);
                    entry.path = char(blockPath);
                    links.(mf).(bf) = entry;
                end
                ok = matlabcopilot.ReqTrace.writeJsonAtomic( ...
                    fullfile(char(cwd), 'req_links.json'), links);
            catch
            end
        end

        function ev = matrix(model, cwd, convId)
            % 组装双向追溯矩阵事件:每条需求 → 锚定的块;统计覆盖率;未知需求 ID 的锚定单列。
            [reqs, src] = matlabcopilot.ReqTrace.loadRequirements(cwd);
            [links, valid] = matlabcopilot.ReqTrace.loadLinks(cwd);
            if ~valid
                error('matlabcopilot:ReqTrace:InvalidLinks', ...
                    'req_links.json 无法解析或结构无效，请先修复该文件。');
            end
            mf = matlab.lang.makeValidName(char(model));
            % 展平当前模型的 block→reqs 映射
            blockOf = containers.Map('KeyType', 'char', 'ValueType', 'any');  % reqId → block 路径列表
            unknown = {};
            if isfield(links, mf)
                bfs = fieldnames(links.(mf));
                knownIds = string({reqs.id});
                for i = 1:numel(bfs)
                    e = links.(mf).(bfs{i});
                    for k = 1:numel(e.reqs)
                        rid = char(string(e.reqs{k}));
                        if isKey(blockOf, rid)
                            blockOf(rid) = [blockOf(rid), {e.path}];
                        else
                            blockOf(rid) = {e.path};
                        end
                        if ~any(knownIds == string(rid))
                            unknown{end+1} = struct('req', string(rid), 'block', string(e.path)); %#ok<AGROW>
                        end
                    end
                end
            end
            rows = {};
            covered = 0;
            for i = 1:numel(reqs)
                blks = {};
                if isKey(blockOf, char(reqs(i).id)); blks = blockOf(char(reqs(i).id)); end
                if ~isempty(blks); covered = covered + 1; end
                rows{end+1} = struct('id', reqs(i).id, 'title', reqs(i).title, ...
                    'blocks', {blks}); %#ok<AGROW>
            end
            ev = struct('type', "req_matrix", 'convId', char(convId), 'model', char(model), ...
                'source', char(src), 'total', numel(reqs), 'covered', covered, ...
                'rows', {rows}, 'unknown', {unknown});
        end

        % ── 内部 ────────────────────────────────────────────────────────
        function v = pick(s, names)
            v = "";
            for i = 1:numel(names)
                if isfield(s, names(i)); v = s.(names(i)); return; end
            end
        end

        function c = colOf(varNames, cands, dflt)
            % 按候选名找列号(大小写不敏感、允许部分包含),找不到用默认列号。
            c = dflt;
            for i = 1:numel(cands)
                hit = find(contains(lower(varNames), lower(cands(i))), 1);
                if ~isempty(hit); c = hit; return; end
            end
        end

        function [field, found] = blockField(entries, blockPath)
            % 先按原始 path 查找；makeValidName 碰撞时追加稳定序号，避免串联两个块。
            found = false;
            fs = fieldnames(entries);
            for i = 1:numel(fs)
                e = entries.(fs{i});
                if isstruct(e) && isfield(e, 'path') && string(e.path) == string(blockPath)
                    field = fs{i}; found = true; return;
                end
            end
            base = matlab.lang.makeValidName(char(blockPath));
            field = base; n = 2;
            while isfield(entries, field)
                suffix = ['_' num2str(n)];
                field = [base(1:min(numel(base), namelengthmax - numel(suffix))) suffix];
                n = n + 1;
            end
        end

        function tf = validLinks(links)
            tf = isstruct(links) && isscalar(links);
            if ~tf; return; end
            mfs = fieldnames(links);
            for i = 1:numel(mfs)
                entries = links.(mfs{i});
                if ~isstruct(entries) || ~isscalar(entries); tf = false; return; end
                bfs = fieldnames(entries);
                for k = 1:numel(bfs)
                    e = entries.(bfs{k});
                    if ~isstruct(e) || ~isscalar(e) || ~isfield(e, 'path') || ~isfield(e, 'reqs')
                        tf = false; return;
                    end
                end
            end
        end

        function ok = writeJsonAtomic(file, value)
            ok = false;
            tmp = string([tempname(fileparts(file)) '.json']);
            try
                fid = fopen(tmp, 'w', 'n', 'UTF-8');
                if fid < 0; return; end
                cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
                fprintf(fid, '%s', char(jsonencode(value, 'PrettyPrint', true)));
                clear cleaner
                [ok, ~] = movefile(tmp, file, 'f');
            catch
            end
            if isfile(tmp); try, delete(tmp); catch, end; end
        end
    end
end
