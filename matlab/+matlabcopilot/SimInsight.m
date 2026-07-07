classdef SimInsight
    % 仿真结果智能分析:读取 Simulink Data Inspector 里最近一次 run 的信号,
    % 本地算控制工程关心的指标(终值/超调/2% 稳定时间/极值),并把曲线画成一张 PNG。
    % 指标计算是确定性的;"为什么超调变大了"这类归因由卡片上的 AI 按钮按需触发。
    % 用法:跑完仿真(信号记录开着)→ /siminsight。

    methods (Static)
        function ev = analyze(convId)
            ids = Simulink.sdi.getAllRunIDs;
            if isempty(ids)
                error('SDI 里没有仿真 run。先跑一次仿真(开启信号记录),再 /siminsight。');
            end
            run = Simulink.sdi.getRun(ids(end));
            n = min(8, run.SignalCount);
            if n == 0
                error('最近的 run(%s)里没有记录任何信号。', char(run.Name));
            end
            sigs = {};
            fig = figure('Visible', 'off', 'Position', [0 0 720 380], 'Color', 'w');
            cleanupObj = onCleanup(@() close(fig)); %#ok<NASGU>
            ax = axes(fig); hold(ax, 'on'); grid(ax, 'on');
            for k = 1:n
                s = run.getSignalByIndex(k);
                [st, t, y] = matlabcopilot.SimInsight.signalStats(s);
                if isempty(st); continue; end
                sigs{end+1} = st; %#ok<AGROW>
                if k <= 6 && ~isempty(t); plot(ax, t, y, 'DisplayName', char(st.name)); end
            end
            legend(ax, 'Location', 'best', 'Interpreter', 'none');
            xlabel(ax, 't (s)');
            png = matlabcopilot.SimInsight.figPng(fig);
            ev = struct('type', "sim_insight", 'convId', char(convId), ...
                'run', char(run.Name), 'signals', {sigs}, 'png', png);
        end

        function [st, t, y] = signalStats(s)
            st = []; t = []; y = [];
            try
                v = s.Values;
                if isstruct(v); return; end          % 总线等复合信号 v1 跳过
                y = double(v.Data(:, 1)); t = double(v.Time(:));
                if isempty(y); return; end
                fin = y(end);
                pk = max(abs(y));
                ovs = 0;
                if abs(fin) > 1e-9
                    ovs = round((max(y) - fin) / abs(fin) * 100, 1);   % 相对终值的超调 %
                end
                % 2% 稳定时间:最后一次越出 ±2%|终值| 带的时刻
                settle = 0;
                if abs(fin) > 1e-9
                    out = abs(y - fin) > 0.02 * abs(fin);
                    li = find(out, 1, 'last');
                    if ~isempty(li) && li < numel(t); settle = round(t(min(li + 1, numel(t))), 3); end
                end
                st = struct('name', string(s.Name), ...
                    'min', round(min(y), 4), 'max', round(max(y), 4), ...
                    'final', round(fin, 4), 'peak', round(pk, 4), ...
                    'overshoot', ovs, 'settle', settle);
            catch
                st = [];
            end
        end

        function url = figPng(fig)
            url = "";
            f = [tempname '.png'];
            try
                print(fig, '-dpng', '-r84', f);
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
