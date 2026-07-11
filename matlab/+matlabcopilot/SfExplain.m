classdef SfExplain
    % Stateflow 深度解析:遍历模型内的 chart,提取 状态/迁移/条件,做两项确定性死逻辑检测:
    %   unreachable — 从默认迁移出发 BFS 不可达的状态(永远进不去);
    %   deadEnd     — 没有任何出向迁移的状态(进得去出不来;对模式管理型 chart 通常是缺陷)。
    % 另生成 mermaid stateDiagram 文本(结构化迁移表),供 AI 解释或粘到支持 mermaid 的工具渲染。
    % Stateflow(除霜/制冷/采暖等模式切换)是模型里最难"读"的部分——把它变成一张说明书。

    methods (Static)
        function ev = report(model, convId)
            m = char(model);
            charts = {};
            rt = sfroot;
            machine = rt.find('-isa', 'Stateflow.Machine', 'Name', m);
            if isempty(machine)
                ev = struct('type', "sf_report", 'convId', char(convId), 'model', m, 'charts', {{}});
                return;
            end
            cs = machine.find('-isa', 'Stateflow.Chart');
            for c = 1:min(5, numel(cs))
                charts{end+1} = matlabcopilot.SfExplain.chartInfo(cs(c)); %#ok<AGROW>
            end
            ev = struct('type', "sf_report", 'convId', char(convId), 'model', m, 'charts', {charts});
        end

        function info = chartInfo(chart)
            states = chart.find('-isa', 'Stateflow.State');
            junctions = chart.find('-isa', 'Stateflow.Junction');
            trans  = chart.find('-isa', 'Stateflow.Transition');
            names = arrayfun(@(s) string(s.Name), states);

            % State 与 Junction 统一用局部编号建图，避免重名状态碰撞；junction 作为普通
            % 图节点参与 BFS，因此默认迁移/条件链经过 junction 时仍能正确传播可达性。
            nodes = cell(numel(states) + numel(junctions), 1);
            for i = 1:numel(states); nodes{i} = states(i); end
            for i = 1:numel(junctions); nodes{numel(states) + i} = junctions(i); end
            edges = zeros(0, 2);
            seeds = zeros(0, 1);
            outState = false(numel(states), 1);
            lines = strings(0, 1);
            quote = string(char(34));
            for i = 1:numel(states)
                label = replace(string(states(i).Name), quote, "'");
                lines(end+1) = "state " + quote + label + quote + " as n" + i; %#ok<AGROW>
            end
            for i = 1:numel(junctions)
                lines(end+1) = "state n" + (numel(states) + i) + " <<choice>>"; %#ok<AGROW>
            end
            for t = 1:numel(trans)
                src = trans(t).Source; dst = trans(t).Destination;
                si = matlabcopilot.SfExplain.nodeIndex(nodes, src);
                di = matlabcopilot.SfExplain.nodeIndex(nodes, dst);
                lbl = strtrim(string(trans(t).LabelString));
                lbl = regexprep(lbl, '\s+', ' ');
                if strlength(lbl) > 40; lbl = extractBefore(lbl, 41) + "…"; end
                if si >= 1 && si <= numel(states); outState(si) = true; end
                if isempty(src) && di > 0
                    seeds(end+1, 1) = di; %#ok<AGROW>
                    lines(end+1) = "[*] --> n" + di; %#ok<AGROW>
                elseif si > 0 && di > 0
                    edges(end+1, :) = [si, di]; %#ok<AGROW>
                    ln = "n" + si + " --> n" + di;
                    if strlength(lbl) > 0; ln = ln + " : " + lbl; end
                    lines(end+1) = ln; %#ok<AGROW>
                end
            end

            % BFS 可达；子状态可达时同步把父状态视为可达，再继续传播父状态的出边。
            reach = false(numel(nodes), 1);
            reach(unique(seeds)) = true;
            grew = true;
            while grew
                before = reach;
                for e = 1:size(edges, 1)
                    if reach(edges(e, 1)); reach(edges(e, 2)) = true; end
                end
                for s = 1:numel(states)
                    if ~reach(s); continue; end
                    parent = states(s).getParent;
                    while isa(parent, 'Stateflow.State')
                        pi = matlabcopilot.SfExplain.nodeIndex(nodes, parent);
                        if pi == 0; break; end
                        reach(pi) = true;
                        parent = parent.getParent;
                    end
                end
                grew = ~isequal(before, reach);
            end
            % 子状态(有父状态的)不参与顶层可达判定的误报:父可达即视为可达。
            unreachable = strings(0, 1);
            deadEnd = strings(0, 1);
            for s = 1:numel(states)
                nm = names(s);
                isSub = isa(states(s).getParent, 'Stateflow.State');
                if ~isSub && ~reach(s) && ~isempty(seeds)   % 无默认迁移的 chart 不误报
                    unreachable(end+1) = nm; %#ok<AGROW>
                end
                % 无出口:该状态没有任何出向迁移(含指向 junction 的);chart 完全无迁移时不判(还没画完)。
                if ~outState(s) && ~isempty(trans)
                    deadEnd(end+1) = nm; %#ok<AGROW>
                end
            end
            mermaid = "stateDiagram-v2" + newline + strjoin(lines, newline);
            info = struct('path', string(chart.Path), 'name', string(chart.Name), ...
                'nStates', numel(states), 'nTrans', numel(trans), ...
                'unreachable', {cellstr(unreachable)}, 'deadEnd', {cellstr(deadEnd)}, ...
                'mermaid', mermaid);
        end

        function s = mid(name)
            % mermaid 状态标识:空格/特殊字符换下划线。
            s = regexprep(string(name), '[^A-Za-z0-9_一-龥]', '_');
        end

        function idx = nodeIndex(nodes, obj)
            idx = 0;
            if isempty(obj); return; end
            for i = 1:numel(nodes)
                try
                    if isequal(nodes{i}, obj); idx = i; return; end
                catch
                end
            end
        end
    end
end
