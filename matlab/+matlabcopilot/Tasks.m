classdef Tasks
    % 预定义质量任务流(对标官方 Process Advisor 任务编排)。
    % 运行时探测本机能力:有 Process Advisor(padv)就用真的;否则用现有能力编排
    % 一条等价管线(编译/结构化诊断 → 标准检查 → Simulink Test → 汇总报告)。

    methods (Static)
        function c = capabilities()
            % 探测可用能力(license/exist),决定任务流各阶段怎么跑。
            c = struct('padv', false, 'check', false, 'test', false);
            try, c.padv  = (exist('runprocess', 'file') > 0) || (exist('padv.ProcessModel', 'class') > 0); catch, end
            try, c.check = license('test', 'Simulink_Check') == 1; catch, end
            try, c.test  = license('test', 'Simulink_Test')  == 1; catch, end
        end

        function text = prompt(model, c)
            % 按探测到的能力,拼一条自适应、分阶段的任务流提示。
            L = strings(0, 1);
            L(end+1) = "对当前 Simulink 模型「" + string(model) + "」执行一条预定义质量任务流," + ...
                "逐阶段进行并在每阶段报告结果,最后给出汇总表(各阶段 通过/警告/失败 + 优先修复项):";
            L(end+1) = "阶段1 编译检查:用 update diagram 更新模型,列出编译期错误/警告及涉及的 block。";
            if c.padv
                L(end+1) = "阶段2 Process Advisor:用 runprocess 运行 Process Advisor 预定义任务流,汇总各任务结果。";
            elseif c.check
                L(end+1) = "阶段2 标准检查:用 model_check 跑建模标准检查(Model Advisor / Simulink Check),按严重度汇总。";
            else
                L(end+1) = "阶段2 标准检查:Simulink Check 未授权,跳过 Model Advisor;改做基本静态检查" + ...
                    "(命名规范、未连接端口、代数环、未解析参数等,可用 model_read / model_check 力所能及地查)。";
            end
            if c.test
                L(end+1) = "阶段3 测试:用 model_test 运行该模型的 Simulink Test 测试,报告通过/失败用例与原因。";
            else
                L(end+1) = "阶段3 测试:Simulink Test 未授权,跳过(如需可改为生成测试建议)。";
            end
            L(end+1) = "阶段4 汇总:用一张表列出各阶段结论与按优先级排序的修复项。回答用简体中文。";
            L(end+1) = "注意:运行/修改类操作会按当前编辑模式触发确认并记入变更记录,请逐步执行。";
            text = strjoin(L, newline);
        end
    end
end
