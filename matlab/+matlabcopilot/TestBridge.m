classdef TestBridge
    % Simulink Test / Coverage 深度集成(确定性部分):
    %   - 发现并运行项目里真正的 Test Manager 用例文件(*.mldatx),结构化汇总结果;
    %   - 对当前模型跑一次覆盖率仿真,产出 决策/条件/MCDC 百分比 + 块级缺口清单。
    % AI 只做下游:失败根因分析、按缺口建议补例。跑测试/收集覆盖都是本地确定性操作,
    % 结果可复现、可审计——这与 StandardsChecker 的"确定性检查 + LLM 解释"是同一设计哲学。
    % 无 Simulink Test / Coverage license 时各入口优雅降级(探测见 caps)。

    methods (Static)
        function c = caps()
            c = struct();
            try, c.sltest = exist('sltest.testmanager.TestFile', 'class') == 8; catch, c.sltest = false; end
            try
                hasCoverage = license('test', 'Simulink_Coverage') == 1 || license('test', 'SL_Coverage') == 1;
                c.coverage = logical(hasCoverage) && exist('cvtest', 'file') > 0;
            catch
                c.coverage = false;
            end
        end

        function files = findTestFiles(cwd)
            % 项目目录下(两层内)的 Test Manager 文件。
            files = strings(0, 1);
            try
                d = [dir(fullfile(char(cwd), '*.mldatx')); dir(fullfile(char(cwd), '*', '*.mldatx'))];
                for i = 1:numel(d)
                    files(end+1, 1) = string(fullfile(d(i).folder, d(i).name)); %#ok<AGROW>
                end
            catch
            end
        end

        function ev = runTestFiles(files, convId)
            % 运行一批 .mldatx,汇总为 testrun_report 事件(用例级:名称/结果/用时)。
            cases = {};
            passed = 0; failed = 0;
            sltest.testmanager.clear;
            sltest.testmanager.clearResults;
            for i = 1:numel(files)
                sltest.testmanager.load(char(files(i)));
            end
            rs = sltest.testmanager.run;
            frs = rs.getTestFileResults;
            for i = 1:numel(frs)
                srs = frs(i).getTestSuiteResults;
                for j = 1:numel(srs)
                    tcr = srs(j).getTestCaseResults;
                    for k = 1:numel(tcr)
                        oc = string(tcr(k).Outcome);
                        if oc == "Passed"; passed = passed + 1; else; failed = failed + 1; end
                        dur = 0; try, dur = double(tcr(k).Duration); catch, end
                        cases{end+1} = struct('file', string(frs(i).Name), ...
                            'name', string(tcr(k).Name), 'outcome', oc, ...
                            'duration', round(dur, 1)); %#ok<AGROW>
                    end
                end
            end
            names = arrayfun(@(f) string(matlabcopilot.ModelSearch.leafName(f)), files);
            ev = struct('type', "testrun_report", 'convId', char(convId), ...
                'files', {cellstr(names)}, 'passed', passed, 'failed', failed, ...
                'cases', {cases});
        end

        function ev = coverageGaps(model, convId)
            % 对模型跑一次覆盖率仿真(模型当前配置),汇总三项指标 + 块级缺口。
            m = char(model);
            tst = cvtest(m);
            tst.settings.decision = 1;
            tst.settings.condition = 1;
            tst.settings.mcdc = 1;
            data = cvsim(tst);
            dec = matlabcopilot.TestBridge.pairOf(@() decisioninfo(data, m));
            cnd = matlabcopilot.TestBridge.pairOf(@() conditioninfo(data, m));
            mcd = matlabcopilot.TestBridge.pairOf(@() mcdcinfo(data, m));
            % 块级缺口:决策/条件覆盖未满的块(封顶 40 条)。
            gaps = {};
            blks = find_system(m, 'FollowLinks', 'off', 'Type', 'Block');
            for i = 1:numel(blks)
                if numel(gaps) >= 40; break; end
                gd = matlabcopilot.TestBridge.pairOf(@() decisioninfo(data, blks{i}));
                if ~isempty(gd) && gd(2) > 0 && gd(1) < gd(2)
                    gaps{end+1} = struct('path', string(blks{i}), 'metric', "decision", ...
                        'hit', gd(1), 'total', gd(2)); %#ok<AGROW>
                end
                if numel(gaps) >= 40; break; end
                gc = matlabcopilot.TestBridge.pairOf(@() conditioninfo(data, blks{i}));
                if ~isempty(gc) && gc(2) > 0 && gc(1) < gc(2)
                    gaps{end+1} = struct('path', string(blks{i}), 'metric', "condition", ...
                        'hit', gc(1), 'total', gc(2)); %#ok<AGROW>
                end
            end
            ev = struct('type', "coverage_report", 'convId', char(convId), 'model', m, ...
                'decision', dec, 'condition', cnd, 'mcdc', mcd, 'gaps', {gaps});
        end

        function p = pairOf(fn)
            % 统一取 [覆盖数 总数];该指标不适用(返回空/报错)→ []。
            p = [];
            try
                v = fn();
                if isnumeric(v) && numel(v) >= 2; p = double(v(1:2)); end
            catch
            end
        end
    end
end
