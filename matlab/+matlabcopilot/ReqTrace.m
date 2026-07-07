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
                    T = readtable(fc, 'TextType', 'string', 'VariableNamingRule', 'preserve');
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
            end
            reqs = reqs(1:min(300, end));   % 封顶,防超大需求库刷爆 UI
        end

        function links = loadLinks(cwd)
            % 读锚定关系(containers.Map: blockPath → reqIds string 数组;按当前接口扁平存)。
            links = struct();
            f = fullfile(char(cwd), 'req_links.json');
            try
                if isfile(f); links = jsondecode(fileread(f)); end
            catch
            end
        end

        function ok = linkBlock(cwd, model, blockPath, reqId, unlink)
            % 把一个 block 锚定到/解除锚定一个需求 ID,写回 req_links.json。
            ok = false;
            try
                links = matlabcopilot.ReqTrace.loadLinks(cwd);
                mf = matlab.lang.makeValidName(char(model));      % jsondecode/encode 字段名安全
                bf = matlab.lang.makeValidName(char(blockPath));  % 原始路径存 value,字段名只作索引
                if ~isfield(links, mf); links.(mf) = struct(); end
                entry = struct('path', char(blockPath), 'reqs', {{}});
                if isfield(links.(mf), bf); entry = links.(mf).(bf); end
                ids = string(entry.reqs);
                if unlink
                    ids = ids(ids ~= string(reqId));
                else
                    ids = unique([ids(:); string(reqId)], 'stable');
                end
                entry.reqs = cellstr(ids);
                entry.path = char(blockPath);
                links.(mf).(bf) = entry;
                fid = fopen(fullfile(char(cwd), 'req_links.json'), 'w');
                fwrite(fid, jsonencode(links, 'PrettyPrint', true));
                fclose(fid);
                ok = true;
            catch
            end
        end

        function ev = matrix(model, cwd, convId)
            % 组装双向追溯矩阵事件:每条需求 → 锚定的块;统计覆盖率;未知需求 ID 的锚定单列。
            [reqs, src] = matlabcopilot.ReqTrace.loadRequirements(cwd);
            links = matlabcopilot.ReqTrace.loadLinks(cwd);
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
    end
end
