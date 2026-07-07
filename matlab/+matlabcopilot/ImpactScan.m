classdef ImpactScan
    % 接口变更影响分析:改 信号/Bus/参数/变量 之前,先扫"谁在用它"。
    % 扫描范围 = 当前已加载的所有模型(块参数引用 + 命名信号线 + Goto/From tag),
    % 结果按 模型/位置/用途 列表,点击可跳画布。确定性扫描,零 token。
    % 多人共用接口库时,这是"改一处、崩一片"事故的事前防线。

    methods (Static)
        function ev = scan(token, convId)
            tk = char(strtrim(string(token)));
            hits = {};
            mdls = matlabcopilot.ImpactScan.loadedModels();
            for i = 1:numel(mdls)
                if numel(hits) >= 80; break; end
                hits = matlabcopilot.ImpactScan.scanModel(mdls(i), tk, hits);
            end
            ev = struct('type', "impact_report", 'convId', char(convId), ...
                'token', tk, 'models', {cellstr(mdls)}, 'hits', {hits});
        end

        function mdls = loadedModels()
            mdls = strings(0, 1);
            try
                bd = find_system('type', 'block_diagram');
                for i = 1:numel(bd)
                    try   % 排除库文件,只扫模型
                        if string(get_param(bd{i}, 'BlockDiagramType')) == "model"
                            mdls(end+1) = string(bd{i}); %#ok<AGROW>
                        end
                    catch
                    end
                end
            catch
            end
            mdls = mdls(1:min(6, end));
        end

        function hits = scanModel(mdl, tk, hits)
            m = char(mdl);
            esc = regexptranslate('escape', tk);
            % 1) 块对话参数引用(find_system 原生支持按对话参数正则匹配,快)
            try
                blks = find_system(m, 'RegExp', 'on', 'BlockDialogParams', esc);
                for i = 1:numel(blks)
                    if numel(hits) >= 80; return; end
                    detail = matlabcopilot.ImpactScan.whichParam(blks{i}, tk);
                    hits{end+1} = struct('model', string(m), 'path', string(blks{i}), ...
                        'kind', "参数引用", 'detail', detail); %#ok<AGROW>
                end
            catch
            end
            % 2) 命名信号线(信号名即接口名)
            try
                ln = find_system(m, 'FindAll', 'on', 'Type', 'line', 'Name', tk);
                for i = 1:numel(ln)
                    if numel(hits) >= 80; return; end
                    hits{end+1} = struct('model', string(m), ...
                        'path', string(get_param(ln(i), 'Parent')), ...
                        'kind', "命名信号", 'detail', string(tk)); %#ok<AGROW>
                end
            catch
            end
            % 3) Goto/From tag(跨层隐式连接,最容易被漏掉的一类)
            try
                gf = [find_system(m, 'BlockType', 'Goto', 'GotoTag', tk); ...
                      find_system(m, 'BlockType', 'From', 'GotoTag', tk)];
                for i = 1:numel(gf)
                    if numel(hits) >= 80; return; end
                    hits{end+1} = struct('model', string(m), 'path', string(gf{i}), ...
                        'kind', "Goto/From tag", 'detail', string(tk)); %#ok<AGROW>
                end
            catch
            end
        end

        function d = whichParam(blk, tk)
            % 找出具体是哪个参数引用了 token(截断展示)。
            d = "";
            try
                dp = get_param(blk, 'DialogParameters');
                if ~isstruct(dp); return; end
                f = fieldnames(dp);
                for i = 1:numel(f)
                    try
                        v = get_param(blk, f{i});
                        if (ischar(v) || isstring(v)) && contains(string(v), string(tk))
                            vs = string(v);
                            if strlength(vs) > 60; vs = extractBefore(vs, 61) + "…"; end
                            d = string(f{i}) + " = " + vs;
                            return;
                        end
                    catch
                    end
                end
            catch
            end
        end
    end
end
