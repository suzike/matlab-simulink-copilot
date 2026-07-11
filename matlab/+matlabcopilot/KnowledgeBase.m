classdef KnowledgeBase
    % 团队经验库:把"好的一问一答"沉淀成项目里的 Markdown 条目(可进 git 共享),
    % 之后任何人再问到相似问题/报错时,自动召回并附进上下文——个人经验变团队复利。
    %
    % 存储:<项目根>/.copilot_kb/NNN.md(人读)+ index.json(机器检索:关键 token 指纹)。
    % 召回:对新消息抽同样的 token 指纹,与条目求交集;错误标识符(xxx:yyy)直配加权。
    % 纯本地、确定性、零 token;召回内容只作为上下文参考注入,不替 AI 下结论。

    methods (Static)
        function ok = save(cwd, question, answer)
            ok = false;
            entryFile = ""; indexTmp = "";
            try
                d = fullfile(char(cwd), '.copilot_kb');
                if ~isfolder(d); mkdir(d); end
                [idx, valid] = matlabcopilot.KnowledgeBase.loadIndex(d);
                if ~valid; return; end   % 索引损坏时拒绝覆盖任何既有条目
                file = matlabcopilot.KnowledgeBase.nextFile(d, idx);
                entryFile = string(fullfile(d, file));
                fid = fopen(entryFile, 'w', 'n', 'UTF-8');
                if fid < 0; return; end
                cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
                fprintf(fid, '# %s\n\n%s\n', char(question), char(answer));
                clear cleaner
                keys = matlabcopilot.KnowledgeBase.fingerprint(string(question) + " " + string(answer));
                idx{end+1} = struct('file', file, 'q', char(question), 'keys', {cellstr(keys)});
                indexTmp = string([tempname(d) '.json']);
                fid = fopen(indexTmp, 'w', 'n', 'UTF-8');
                if fid < 0; error('matlabcopilot:KnowledgeBase:OpenFailed', '无法写入经验库索引。'); end
                cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
                fprintf(fid, '%s', char(jsonencode(idx)));
                clear cleaner
                [ok, ~] = movefile(indexTmp, fullfile(d, 'index.json'), 'f');
                if ok; indexTmp = ""; entryFile = ""; end
            catch
            end
            if strlength(indexTmp) > 0 && isfile(indexTmp); try, delete(indexTmp); catch, end; end
            if strlength(entryFile) > 0 && isfile(entryFile); try, delete(entryFile); catch, end; end
        end

        function hits = recall(cwd, text, maxN)
            % 相似度 = token 指纹交集数;错误标识符直配 +3 加权;≥3 分才算命中。
            hits = {};
            try
                d = fullfile(char(cwd), '.copilot_kb');
                [idx, valid] = matlabcopilot.KnowledgeBase.loadIndex(d);
                if ~valid || isempty(idx); return; end
                keys = matlabcopilot.KnowledgeBase.fingerprint(string(text));
                errIds = regexp(lower(char(text)), '\w+:\w+(:\w+)*', 'match');   % MException 标识符(小写,与指纹一致)
                scores = zeros(1, numel(idx));
                for i = 1:numel(idx)
                    ek = string(idx{i}.keys);
                    scores(i) = numel(intersect(keys, ek));
                    for e = 1:numel(errIds)
                        if any(ek == string(errIds{e})); scores(i) = scores(i) + 3; end
                    end
                end
                [sv, si] = sort(scores, 'descend');
                for k = 1:min(maxN, numel(si))
                    if sv(k) < 3; break; end
                    entry = idx{si(k)};
                    body = "";
                    try
                        body = string(fileread(fullfile(d, entry.file)));
                        if strlength(body) > 700; body = extractBefore(body, 701) + "…"; end
                    catch
                    end
                    hits{end+1} = struct('q', string(entry.q), 'body', body, ...
                        'file', string(entry.file)); %#ok<AGROW>
                end
            catch
            end
        end

        function [idx, valid] = loadIndex(d)
            idx = {};
            valid = true;
            try
                f = fullfile(d, 'index.json');
                if ~isfile(f); return; end
                raw = jsondecode(fileread(f));
                if isempty(raw); return; end
                if isstruct(raw); raw = num2cell(raw); end
                if ~iscell(raw); valid = false; return; end
                idx = raw(:)';
                for i = 1:numel(idx)
                    e = idx{i};
                    if ~isstruct(e) || ~isfield(e, 'file') || ~isfield(e, 'q') || ~isfield(e, 'keys')
                        idx = {}; valid = false; return;
                    end
                    [~, n, x] = fileparts(char(string(e.file)));
                    if string([n x]) ~= string(e.file) || ~strcmpi(x, '.md')
                        idx = {}; valid = false; return;
                    end
                end
            catch
                idx = {};
                valid = false;
            end
        end

        function file = nextFile(d, idx)
            % 编号同时参考索引和磁盘文件；孤儿条目也绝不覆盖。
            used = zeros(0, 1);
            fs = dir(fullfile(d, '*.md'));
            for i = 1:numel(fs)
                t = regexp(fs(i).name, '^(\d+)\.md$', 'tokens', 'once');
                if ~isempty(t); used(end+1, 1) = str2double(t{1}); end %#ok<AGROW>
            end
            n = max([0; used; numel(idx)]) + 1;
            file = sprintf('%03d.md', n);
            while isfile(fullfile(d, file))
                n = n + 1;
                file = sprintf('%03d.md', n);
            end
        end

        function keys = fingerprint(text)
            % token 指纹:标识符风格的 ASCII 词(≥4 字符,含 xxx:yyy 错误 ID),去重、小写、封顶 24。
            keys = strings(0, 1);
            try
                toks = regexp(lower(char(text)), '[a-z][a-z0-9_]{3,}(:[a-z0-9_]+)*', 'match');
                stop = ["with", "that", "this", "from", "have", "matlab", "simulink", ...
                        "error", "using", "when", "then", "please", "model"];
                toks = string(toks);
                toks = toks(~ismember(toks, stop));
                keys = unique(toks, 'stable');
                keys = keys(1:min(24, end));
            catch
            end
        end
    end
end
