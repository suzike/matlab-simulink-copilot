classdef ParamSweep
    % 标定参数敏感度扫描:对 base workspace 里的一个标定参数,按给定取值批量仿真,
    % 汇总每个取值下模型各输出(root Outport)的 终值/峰值 成一张对照表。
    % 把"手工改参数→跑→看→再改"的循环变成一键批跑;哪个方向该调、调多敏感,AI 按需解读。
    % 用法:/sweep Kp 0.5,1,2,4(参数须是模型引用的 base workspace 变量)。

    methods (Static)
        function ev = sweep(model, varName, values, convId)
            m = char(model); vn = char(varName);
            values = double(values(:)');
            values = values(isfinite(values));
            values = values(1:min(8, end));   % 一次最多 8 个取值(串行仿真,时长可控)
            if isempty(values); error('没有可用的取值。用法:/sweep 变量名 0.5,1,2'); end
            if ~isvarname(vn); error('参数名必须是合法 MATLAB 变量名。'); end

            % 记住原值,扫完恢复(不存在则扫完清掉),不污染用户工作区。
            hadVar = evalin('base', sprintf('exist(''%s'', ''var'')', vn)) == 1;
            orig = [];
            if hadVar; orig = evalin('base', vn); end
            restore = onCleanup(@() matlabcopilot.ParamSweep.restoreVar(vn, hadVar, orig)); %#ok<NASGU>

            rows = {};
            outputName = "yout";
            try, outputName = string(get_param(m, 'OutputSaveName')); catch, end
            for i = 1:numel(values)
                assignin('base', vn, values(i));
                try
                    so = sim(m, 'ReturnWorkspaceOutputs', 'on', ...
                        'SaveOutput', 'on', 'SaveFormat', 'Dataset');
                    outs = matlabcopilot.ParamSweep.outStats(so, outputName);
                    if isempty(outs)
                        outs = {struct('name', "未读取到输出", ...
                            'final', "检查模型输出保存配置或信号类型", 'peak', "")};
                    end
                catch err
                    outs = {struct('name', "仿真失败", 'final', string(err.message), 'peak', "")};
                end
                rows{end+1} = struct('value', values(i), 'outs', {outs}); %#ok<AGROW>
            end
            ev = struct('type', "sweep_report", 'convId', char(convId), ...
                'model', m, 'param', vn, 'rows', {rows});
        end

        function outs = outStats(so, outputName)
            outs = {};
            try
                if nargin < 2 || strlength(string(outputName)) == 0; outputName = "yout"; end
                yout = so.get(char(outputName));
                if ~isa(yout, 'Simulink.SimulationData.Dataset'); return; end
                for k = 1:min(6, yout.numElements)
                    el = yout.getElement(k);
                    vals = el.Values;
                    data = double(vals.Data);
                    if isempty(data); continue; end
                    nTime = numel(vals.Time);
                    if nTime > 0 && mod(numel(data), nTime) == 0
                        samples = reshape(data, nTime, []);
                    else
                        samples = data(:);
                    end
                    final = matlabcopilot.ParamSweep.compactValue(samples(end, :));
                    peak = matlabcopilot.ParamSweep.compactValue(max(abs(samples), [], 'all', 'omitnan'));
                    nm = string(el.Name);
                    if strlength(nm) == 0; nm = "out" + k; end
                    outs{end+1} = struct('name', nm, ...
                        'final', final, 'peak', peak); %#ok<AGROW>
                end
            catch
            end
        end

        function v = compactValue(v)
            if isempty(v)
                v = "";
                return;
            end
            v = round(double(v), 4);
            if ~isscalar(v); v = string(mat2str(v)); end
        end

        function restoreVar(vn, hadVar, orig)
            try
                if hadVar
                    assignin('base', vn, orig);
                else
                    evalin('base', sprintf('clear %s', vn));
                end
            catch
            end
        end
    end
end
