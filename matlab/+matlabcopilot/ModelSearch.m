classdef ModelSearch
    % Simulink 模型组件搜索与高亮辅助。
    % 配合「查找模块」:agent 语义定位出模块的完整路径,并在回答末尾输出隐藏标记
    % <<HILITE: 完整路径>>;面板抽取该路径,用 MATLAB 原生 hilite_system 在画布上高亮。
    % 高亮是纯视觉只读操作,不改模型,因此无需走权限确认。

    methods (Static)
        function path = parseMarker(text)
            % 从 agent 回答里抽取 <<HILITE: 模块完整路径>> 标记,返回路径;无则 ""。
            path = "";
            try
                tok = regexp(string(text), '<<HILITE:\s*(.*?)>>', 'tokens', 'once');
                if isempty(tok); return; end
                p = strtrim(string(tok{1}));
                p = erase(p, '`');                          % 去掉可能的反引号
                p = regexprep(p, '^["'']+|["'']+$', '');     % 去掉首尾引号
                path = strtrim(p);
            catch
            end
        end

        function ok = highlight(path)
            % 在画布上高亮指定模块(只读视觉操作)。成功返回 true。
            ok = false;
            if strlength(string(path)) == 0; return; end
            try
                root = bdroot(char(path));      % 由完整路径推出所属模型
                open_system(root);              % 确保模型窗口可见
                hilite_system(char(path), 'find');  % 'find' 为内置高亮方案(橙色)
                ok = true;
            catch
            end
        end

        function out = collectStrings(x)
            % 递归收集结构体/元胞/字符串里的所有字符串叶子(用于从工具入参里嗅探 block 路径)。
            out = strings(0, 1);
            try
                if isstring(x) || ischar(x)
                    out = string(x);
                    out = out(:);
                elseif iscell(x)
                    for i = 1:numel(x)
                        out = [out; matlabcopilot.ModelSearch.collectStrings(x{i})]; %#ok<AGROW>
                    end
                elseif isstruct(x)
                    f = fieldnames(x);
                    for k = 1:numel(x)
                        for i = 1:numel(f)
                            out = [out; matlabcopilot.ModelSearch.collectStrings(x(k).(f{i}))]; %#ok<AGROW>
                        end
                    end
                end
            catch
            end
            out = out(:);
        end

        function leaf = leafName(path)
            % 取完整路径的末段名(用作状态提示),兼顾名字里的转义斜杠 '//'。
            leaf = string(path);
            try
                safe = regexprep(string(path), '//', char(1)); % 临时保护转义斜杠
                parts = split(safe, '/');
                leaf = regexprep(parts(end), char(1), '/');
            catch
            end
        end
    end
end
