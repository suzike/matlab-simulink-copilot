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
            trans  = chart.find('-isa', 'Stateflow.Transition');
            names = arrayfun(@(s) string(s.Name), states);

            % 邻接与入度:src/dst 是 State 才计(经由 junction 的链路对可达性近似处理:
            % junction 视为透明——用其入/出迁移拼接;v1 用直接 State→State 边 + 默认迁移目标)。
            edges = strings(0, 2);      % [srcName dstName](仅 State→State,供可达 BFS)
            outSrc = strings(0, 1);     % 有任何出向迁移的状态(含指到 junction 的,供无出口判定)
            reach0 = strings(0, 1);     % 默认迁移(无源)直达的状态 = BFS 种子
            lines = strings(0, 1);      % mermaid 行
            for t = 1:numel(trans)
                src = trans(t).Source; dst = trans(t).Destination;
                dstIsState = ~isempty(dst) && isa(dst, 'Stateflow.State');
                srcIsState = ~isempty(src) && isa(src, 'Stateflow.State');
                lbl = strtrim(string(trans(t).LabelString));
                lbl = regexprep(lbl, '\s+', ' ');
                if strlength(lbl) > 40; lbl = extractBefore(lbl, 41) + "…"; end
                if srcIsState; outSrc(end+1) = string(src.Name); end %#ok<AGROW>
                if isempty(src) && dstIsState
                    reach0(end+1) = string(dst.Name); %#ok<AGROW>
                    lines(end+1) = "[*] --> " + matlabcopilot.SfExplain.mid(dst.Name); %#ok<AGROW>
                elseif srcIsState && dstIsState
                    edges(end+1, :) = [string(src.Name), string(dst.Name)]; %#ok<AGROW>
                    ln = matlabcopilot.SfExplain.mid(src.Name) + " --> " + matlabcopilot.SfExplain.mid(dst.Name);
                    if strlength(lbl) > 0; ln = ln + " : " + lbl; end
                    lines(end+1) = ln; %#ok<AGROW>
                end
            end

            % BFS 可达
            reach = unique(reach0);
            grew = true;
            while grew
                grew = false;
                for e = 1:size(edges, 1)
                    if any(reach == edges(e, 1)) && ~any(reach == edges(e, 2))
                        reach(end+1) = edges(e, 2); %#ok<AGROW>
                        grew = true;
                    end
                end
            end
            % 子状态(有父状态的)不参与顶层可达判定的误报:父可达即视为可达。
            unreachable = strings(0, 1);
            deadEnd = strings(0, 1);
            for s = 1:numel(states)
                nm = names(s);
                isSub = isa(states(s).getParent, 'Stateflow.State');
                if ~isSub && ~any(reach == nm) && ~isempty(reach)   % 无默认迁移的 chart 不误报
                    unreachable(end+1) = nm; %#ok<AGROW>
                end
                % 无出口:该状态没有任何出向迁移(含指向 junction 的);chart 完全无迁移时不判(还没画完)。
                if ~any(outSrc == nm) && ~isempty(trans)
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
    end
end
