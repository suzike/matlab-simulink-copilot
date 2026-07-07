classdef DocGen
    % SWDD(软件详细设计)骨架生成:从模型确定性提取"事实部分"——
    % 接口表(Inport/Outport + 类型/维度)、引用的标定参数、子系统树(含 Description)、
    % Stateflow 模式表(复用 SfExplain)——写成 Markdown 骨架落盘;
    % "为什么这么设计"的文字描述由 AI 按骨架补全(卡片按钮触发)。
    % 事实由代码保证准确,文笔交给 LLM——文档跟着模型走,不再手工维护两份真相。

    methods (Static)
        function ev = generate(model, cwd, convId)
            m = char(model);
            md = strings(0, 1);
            md(end+1) = "# " + string(m) + " 软件详细设计(SWDD 草稿)";
            md(end+1) = "";
            md(end+1) = "> 本文骨架由 MATLAB Copilot 从模型自动提取(接口/参数/结构为事实数据);";
            md(end+1) = "> 【待补】段落请用面板的「AI 补全描述」完成后人工复核。";
            md(end+1) = "";
            md(end+1) = "## 1. 模块概述";
            md(end+1) = "【待补:本模块的职责、在整车/系统中的位置、与上下游模块的关系】";

            % ── 2. 接口 ──
            md(end+1) = "";
            md(end+1) = "## 2. 外部接口";
            pt = matlabcopilot.DocGen.portTable(m, 'Inport', "输入");
            md = [md(:); pt(:)];   % 统一列向量:string(end+1) 从标量增长会变行向量,直接 vertcat 会维度不符
            pt = matlabcopilot.DocGen.portTable(m, 'Outport', "输出");
            md = [md(:); pt(:)];

            % ── 3. 标定参数(块参数里引用的工作区标识符) ──
            md(end+1) = "";
            md(end+1) = "## 3. 标定参数";
            vars = matlabcopilot.DocGen.referencedVars(m);
            if isempty(vars)
                md(end+1) = "(未发现引用的工作区参数)";
            else
                md(end+1) = "| 参数 | 引用位置(示例) | 含义 |";
                md(end+1) = "|---|---|---|";
                for i = 1:numel(vars)
                    md(end+1) = "| `" + vars(i).name + "` | " + vars(i).where + " | 【待补】 |"; %#ok<AGROW>
                end
            end

            % ── 4. 内部结构(子系统树) ──
            md(end+1) = "";
            md(end+1) = "## 4. 内部结构";
            st = matlabcopilot.DocGen.subsysTree(m);
            md = [md(:); st(:)];

            % ── 5. 模式管理(Stateflow) ──
            md(end+1) = "";
            md(end+1) = "## 5. 模式管理(Stateflow)";
            try
                sf = matlabcopilot.SfExplain.report(m, convId);
                if isempty(sf.charts)
                    md(end+1) = "(本模型无 Stateflow chart)";
                else
                    for i = 1:numel(sf.charts)
                        c = sf.charts{i};
                        md(end+1) = "### " + string(c.name); %#ok<AGROW>
                        md(end+1) = string(c.nStates) + " 个状态 / " + string(c.nTrans) + " 条迁移。【待补:各模式职责与切换策略】"; %#ok<AGROW>
                        md(end+1) = "```mermaid"; %#ok<AGROW>
                        md(end+1) = string(c.mermaid); %#ok<AGROW>
                        md(end+1) = "```"; %#ok<AGROW>
                    end
                end
            catch
                md(end+1) = "(Stateflow 解析失败,跳过)";
            end

            md(end+1) = "";
            md(end+1) = "## 6. 设计约束与安全考虑";
            md(end+1) = "【待补:限幅/防饱和/故障降级/时序约束】";

            % 落盘 + 组事件
            text = strjoin(md, newline);
            file = fullfile(char(cwd), [m '_SWDD.md']);
            fid = fopen(file, 'w', 'n', 'UTF-8');
            fwrite(fid, char(text));
            fclose(fid);
            ev = struct('type', "swdd_draft", 'convId', char(convId), 'model', m, ...
                'file', file, 'content', text);
        end

        function rows = portTable(m, blockType, label)
            rows = strings(0, 1);
            rows(end+1) = "### " + label + "端口";
            blks = find_system(m, 'SearchDepth', 1, 'BlockType', blockType);
            if isempty(blks)
                rows(end+1) = "(无)";
                return;
            end
            rows(end+1) = "| 端口 | 数据类型 | 维度 | 含义 |";
            rows(end+1) = "|---|---|---|---|";
            for i = 1:numel(blks)
                nm = string(get_param(blks{i}, 'Name'));
                dt = "auto"; dim = "-1";
                try, dt = string(get_param(blks{i}, 'OutDataTypeStr')); catch, end
                try, dim = string(get_param(blks{i}, 'PortDimensions')); catch, end
                rows(end+1) = "| `" + nm + "` | " + dt + " | " + dim + " | 【待补】 |"; %#ok<AGROW>
            end
        end

        function vars = referencedVars(m)
            % 从块对话参数里嗅探"标识符风格"的取值(引用工作区/字典变量的标定参数)。
            vars = struct('name', {}, 'where', {});
            seen = strings(0, 1);
            try
                blks = find_system(m, 'FollowLinks', 'off', 'Type', 'Block');
                for i = 1:numel(blks)
                    if numel(vars) >= 40; break; end
                    try
                        dp = get_param(blks{i}, 'DialogParameters');
                        if ~isstruct(dp); continue; end
                        f = fieldnames(dp);
                        for k = 1:numel(f)
                            v = get_param(blks{i}, f{k});
                            if ~(ischar(v) || isstring(v)); continue; end
                            % 纯标识符(非数字/非表达式)才算参数引用
                            if ~isempty(regexp(char(v), '^[A-Za-z]\w*$', 'once')) ...
                                    && ~any(strcmpi(char(v), {'on', 'off', 'auto', 'inherit'}))
                                nm = string(v);
                                if any(seen == nm); continue; end
                                seen(end+1) = nm; %#ok<AGROW>
                                vars(end+1) = struct('name', nm, ...
                                    'where', matlabcopilot.ModelSearch.leafName(blks{i}) + "." + string(f{k})); %#ok<AGROW>
                            end
                        end
                    catch
                    end
                end
            catch
            end
        end

        function rows = subsysTree(m)
            rows = strings(0, 1);
            subs = find_system(m, 'FollowLinks', 'off', 'BlockType', 'SubSystem');
            if isempty(subs)
                rows(end+1) = "(单层模型,无子系统)";
                return;
            end
            base = count(string(m), '/');
            for i = 1:min(40, numel(subs))
                d = count(regexprep(string(subs{i}), '//', ''), '/') - base;
                desc = "";
                try, desc = strtrim(string(get_param(subs{i}, 'Description'))); catch, end
                if strlength(desc) == 0; desc = "【待补:职责】"; end
                indent = string(repmat(' ', 1, 2 * max(0, d - 1)));
                rows(end+1) = indent + "- **" + ...
                    matlabcopilot.ModelSearch.leafName(subs{i}) + "**:" + desc; %#ok<AGROW>
            end
        end
    end
end
