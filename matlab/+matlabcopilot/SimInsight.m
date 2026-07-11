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
            plotted = 0;
            for k = 1:n
                s = run.getSignalByIndex(k);
                [st, t, y] = matlabcopilot.SimInsight.signalStats(s);
                if isempty(st); continue; end
                sigs{end+1} = st; %#ok<AGROW>
                if plotted < 6 && ~isempty(t)
                    plot(ax, t, y, 'DisplayName', char(st.name));
                    plotted = plotted + 1;
                end
            end
            if isempty(sigs)
                error('最近的 run(%s)里没有可分析的标量数值信号。', char(run.Name));
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
                data = double(v.Data); t = double(v.Time(:));
                % 多通道向量不能静默只取第一列，否则指标会冒充整个信号。
                if numel(data) ~= numel(t); return; end
                y = data(:);
                keep = isfinite(t) & isfinite(y);
                t = t(keep); y = y(keep);
                if isempty(y); return; end
                fin = y(end);
                pk = max(abs(y));
                ovs = 0;
                if abs(fin) > 1e-9
                    if fin > 0
                        excess = max(y) - fin;
                    else
                        excess = fin - min(y);
                    end
                    ovs = round(max(0, excess / abs(fin) * 100), 1);
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
                fid = fopen(f, 'rb');
                if fid < 0; error('matlabcopilot:SimInsight:OpenFailed', '无法读取临时曲线图。'); end
                cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
                b = fread(fid, inf, '*uint8');
                clear cleaner
                if numel(b) > 0 && numel(b) <= 400 * 1024
                    url = "data:image/png;base64," + string(matlab.net.base64encode(b));
                end
            catch
            end
            if isfile(f); try, delete(f); catch, end; end
        end
    end
end
