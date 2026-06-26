classdef Panel < handle
    % MATLAB 内嵌 Copilot 侧边栏面板。
    % 一个(尽量可停靠的)uifigure 内放一个铺满的 uihtml,渲染本地聊天界面。
    % uihtml ⇄ MATLAB 走事件桥;MATLAB ⇄ sidecar 走 Bridge(tcpclient)。

    properties
        Figure        matlab.ui.Figure
        HTML          matlab.ui.control.HTML
        Bridge        matlabcopilot.Bridge
        RootDir       string   % 仓库根目录
        PendingInsert logical = false  % 是否处于「生成到光标」模式
        PendingDoc                     % 暂存的活动文档
        PendingSel                     % 暂存的光标 Selection
        Attachments cell = {}          % 本地文件上下文:{struct('name','content')}
        PendingFind logical = false    % 「查找模块」:等 agent 返回路径后原生高亮
        PendingFindText string = ""    % 累积本轮助手文本(从中解析 <<HILITE:>> 标记)
        PendingFindHits string = strings(0,1)  % 嗅探到的、属于当前模型的 block 路径(兜底高亮)
        Diag                           % matlabcopilot.Diagnostics:结构化诊断采集
        ActiveConv string = "main"     % 当前活动标签页 convId(随每个 UI 事件更新)
    end

    methods
        function obj = Panel(opts)
            arguments
                opts.Backend (1,1) string = "claude"
                opts.Cwd (1,1) string = string(pwd)
                opts.Port (1,1) double = 8765
                opts.ControlPort (1,1) double = 8766
                opts.NodeBin (1,1) string = "node"
            end

            obj.RootDir = matlabcopilot.Panel.repoRoot();
            obj.buildUI();
            obj.Figure.UserData = obj;  % 把面板存到图窗,供 Simulink 右键菜单按窗口查找(不留 persistent)
            obj.Diag = matlabcopilot.Diagnostics();  % 常驻诊断采集(前向捕获后续模型操作的诊断)

            sidecarDir = fullfile(obj.RootDir, "sidecar");
            obj.Bridge = matlabcopilot.Bridge(sidecarDir, opts.Cwd, ...
                Backend=opts.Backend, Port=opts.Port, ...
                ControlPort=opts.ControlPort, NodeBin=opts.NodeBin);
            obj.Bridge.OnMessage = @(m) obj.onSidecarMessage(m);
            obj.Bridge.OnStatus  = @(s) obj.pushToUi(struct('type', "status", 'text', s));

            try
                obj.Bridge.start();
            catch err
                obj.pushToUi(struct('type', "error", 'message', string(err.message)));
            end
        end

        function pushContext(obj)
            % 把最新上下文快照推给 UI 顶栏(在发送消息时调用,保证顶栏是当前状态)。
            try
                if isempty(obj.HTML) || ~isvalid(obj.HTML); return; end
                obj.pushToUi(struct('type', "context", 'context', matlabcopilot.Context.snapshot()));
            catch
            end
        end

        function buildUI(obj)
            fig = uifigure('Name', 'MATLAB Copilot', 'Position', [100 100 440 820]);
            % 尝试停靠进 MATLAB 桌面(R2025a+);失败则保持浮动窗口。
            try
                fig.WindowStyle = 'docked';
            catch
            end
            fig.CloseRequestFcn = @(~,~) obj.onClose();

            g = uigridlayout(fig, [1 1], 'Padding', [0 0 0 0], ...
                'RowHeight', {'1x'}, 'ColumnWidth', {'1x'});

            htmlFile = fullfile(obj.RootDir, "ui", "index.html");
            h = uihtml(g, 'HTMLSource', char(htmlFile));
            h.HTMLEventReceivedFcn = @(src, evt) obj.onHtmlEvent(evt);

            obj.Figure = fig;
            obj.HTML = h;
        end

        % ── JS → MATLAB ────────────────────────────────────────────────────
        function onHtmlEvent(obj, evt)
            name = string(evt.HTMLEventName);
            data = evt.HTMLEventData;
            % 跟踪当前活动标签页(UI 每个事件都带 convId),供转发后端消息时路由。
            obj.ActiveConv = string(getfieldor(data, 'convId', obj.ActiveConv));
            try
            switch name
                case "ui_ready"
                    obj.pushToUi(struct('type', "status", 'text', "面板已就绪"));
                case "user_message"
                    obj.handleUserMessage(data);
                case "interrupt"
                    obj.Bridge.send(struct('type', "interrupt", 'convId', char(obj.ActiveConv)));
                case "permission_response"
                    obj.Bridge.send(struct('type', "permission_response", ...
                        'id', data.id, 'approved', logical(data.approved), ...
                        'convId', char(getfieldor(data, 'convId', obj.ActiveConv))));
                case "close_conv"
                    obj.Bridge.send(struct('type', "close_conv", ...
                        'convId', char(getfieldor(data, 'convId', obj.ActiveConv))));
                case "diagnose_error"
                    obj.handleDiagnose();
                case "find_block"
                    obj.handleFindBlock(data);
                case "explain_selected"
                    obj.explainSelected();
                case "jump_block"
                    matlabcopilot.ModelSearch.highlight(getfieldor(data, 'path', ""));
                case "copy_text"
                    try, clipboard('copy', char(getfieldor(data, 'text', ""))); catch, end
                case "run_tasks"
                    obj.handleRunTasks();
                case "self_heal"
                    obj.handleSelfHeal();
                case "capture_model"
                    obj.handleCaptureModel();
                case "requirements"
                    obj.handleRequirements();
                case "codegen_review"
                    obj.handleCodeGenReview();
                case "batch_edit"
                    obj.handleBatchEdit(data);
                case "test_orchestrate"
                    obj.handleTestOrchestrate();
                case "ask_at_cursor"
                    obj.handleAskAtCursor(data);
                case "request_context"
                    obj.pushToUi(struct('type', "context", 'context', matlabcopilot.Context.snapshot()));
                case "request_theme"
                    obj.pushToUi(struct('type', "theme", 'mode', matlabcopilot.Panel.detectTheme()));
                case "set_config"
                    obj.Bridge.send(struct('type', "set_config", 'config', data.config, ...
                        'convId', char(obj.ActiveConv)));
                case "get_capabilities"
                    obj.Bridge.send(struct('type', "get_capabilities"));
                case "slash_command"
                    obj.Bridge.send(struct('type', "slash_command", ...
                        'name', getfieldor(data, 'name', ""), ...
                        'args', getfieldor(data, 'args', ""), ...
                        'convId', char(obj.ActiveConv), ...
                        'context', matlabcopilot.Context.snapshot()));
                case "attach_file"
                    obj.handleAttachFile();
                case "attach_image"
                    obj.handleAttachImage(data);
                case "clear_attachments"
                    obj.Attachments = {};
                    obj.pushToUi(struct('type', "attachments", 'files', {{}}));
                case "remove_attachment"
                    idx = double(getfieldor(data, 'index', -1)) + 1; % JS 0-based → MATLAB 1-based
                    if idx >= 1 && idx <= numel(obj.Attachments)
                        obj.Attachments(idx) = [];
                    end
                    obj.pushToUi(struct('type', "attachments", 'files', {obj.attachmentNames()}));
                otherwise
            end
            catch err
                % 任何未捕获的处理错误都在 UI 里显示并解除 busy(error 类型在 JS 里会调 setBusy(false))。
                % 复位 pending 标志:否则 send 抛错后残留的 PendingFind/PendingInsert 会吞掉后续正常回包,卡死消息路由。
                obj.PendingFind = false;
                obj.PendingInsert = false;
                obj.pushToUi(struct('type', "error", 'convId', char(obj.ActiveConv), ...
                    'message', "操作失败 [" + name + "]: " + string(err.message)));
            end
        end

        function handleAttachFile(obj)
            % 选本地文件作上下文,支持任意文件类型(默认显示所有文件)。
            % 图片 → 走视觉(给路径,agent 用 Read 读图);其余 → 读为文本(超大截断)。
            [f, p] = uigetfile({'*.*', '所有文件 (*.*)'; ...
                '*.m;*.mlx;*.txt;*.md;*.csv;*.json;*.xml;*.slx;*.png;*.jpg', '常用文件'}, ...
                '选择要作为上下文的文件');
            if isequal(f, 0); return; end
            full = fullfile(p, f);
            [~, ~, ext] = fileparts(f);
            if any(strcmpi(ext, {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff', '.webp'}))
                obj.Attachments{end+1} = struct('name', string(f), 'content', "", ...
                    'path', string(full), 'isImage', true);
            else
                content = "";
                try
                    raw = fileread(full);
                    content = string(raw);
                    if strlength(content) > 20000
                        content = extractBefore(content, 20000) + newline + "…(已截断)";
                    end
                catch
                    content = "(无法读取为文本)";
                end
                obj.Attachments{end+1} = struct('name', string(f), 'content', content, ...
                    'path', "", 'isImage', false);
            end
            obj.pushToUi(struct('type', "attachments", 'files', {obj.attachmentNames()}));
        end

        function handleAttachImage(obj, data)
            % 接收 UI 粘贴的图片(base64 data URL),写临时 PNG,作图片附件(走视觉)。
            try
                dataUrl = string(getfieldor(data, 'dataUrl', ""));
                if strlength(dataUrl) == 0; return; end
                b64 = extractAfter(dataUrl, ",");        % 去掉 data:image/png;base64, 前缀
                if ismissing(b64) || strlength(b64) == 0; b64 = dataUrl; end
                bytes = matlab.net.base64decode(char(b64));
                tmp = string(tempname) + ".png";
                fid = fopen(tmp, 'w');
                if fid < 0; return; end
                fwrite(fid, bytes, 'uint8'); fclose(fid);
                name = string(getfieldor(data, 'name', "粘贴图片.png"));
                obj.Attachments{end+1} = struct('name', name, 'content', "", ...
                    'path', tmp, 'isImage', true);
                obj.pushToUi(struct('type', "attachments", 'files', {obj.attachmentNames()}));
            catch
            end
        end

        function names = attachmentNames(obj)
            names = strings(1, numel(obj.Attachments));
            for i = 1:numel(obj.Attachments); names(i) = obj.Attachments{i}.name; end
        end

        function ctx = contextWithAttachments(obj)
            ctx = matlabcopilot.Context.snapshot();
            if ~isempty(obj.Attachments)
                ctx.attachments = obj.Attachments;
            end
        end

        function handleUserMessage(obj, data)
            ctx = obj.contextWithAttachments();
            obj.pushContext();  % 顺手刷新顶栏,保证显示当前状态
            % UI 可在 data.attach 里指明只带哪些上下文;默认全带。
            msg = struct('type', "user_message", ...
                'id', getfieldor(data, 'id', char(matlab.lang.internal.uuid())), ...
                'text', getfieldor(data, 'text', ""), ...
                'convId', char(obj.ActiveConv), ...
                'context', ctx);
            obj.Bridge.send(msg);
            % 附件随本条消息发出后清空(属于这条消息,避免后续每条都重复带)。
            if ~isempty(obj.Attachments)
                obj.Attachments = {};
                obj.pushToUi(struct('type', "attachments", 'files', {{}}));
            end
        end

        function handleDiagnose(obj)
            % 结构化诊断:拉诊断查看器 + 命令行报错 → UI 卡片(可跳转高亮)+ 喂 agent 根因/修复。
            items = struct('severity', {}, 'message', {}, 'id', {}, 'block', {});
            try
                if ~isempty(obj.Diag) && isvalid(obj.Diag); items = obj.Diag.collect(); end
            catch
            end
            cc = char(obj.ActiveConv);
            if ~isempty(items)
                obj.pushToUi(struct('type', "diagnostics", 'convId', cc, 'items', {num2cell(items)}));
            else
                obj.pushToUi(struct('type', "status", 'convId', cc, 'text', "未捕获到结构化诊断,基于当前上下文分析…"));
            end
            ctx = matlabcopilot.Context.snapshot();
            text = obj.diagnosePrompt(items);
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', text, 'context', ctx));
        end

        function text = diagnosePrompt(obj, items) %#ok<INUSL>
            % 把结构化诊断拼进提示,让 agent 锚定真实诊断做根因+修复。
            if isempty(items)
                text = "请根据最近的报错和当前上下文,诊断原因并给出修复方案。";
                return;
            end
            lines = strings(0,1);
            for i = 1:numel(items)
                d = items(i);
                seg = "- [" + d.severity + "] " + d.message;
                if strlength(d.id) > 0;    seg = seg + "(ID: " + d.id + ")"; end
                if strlength(d.block) > 0; seg = seg + " @ " + d.block; end
                lines(end+1) = seg; %#ok<AGROW>
            end
            text = "以下是 Simulink 诊断查看器/命令行捕获的结构化诊断,请据此逐条分析根本原因、" + ...
                "定位涉及的 block,并给出具体修复步骤(可调用 model_read 核实参数):" + newline + ...
                strjoin(lines, newline) + newline + "回答用简体中文。";
        end

        function handleRunTasks(obj)
            % 「任务流」:探测本机能力 → 让 agent 按自适应分阶段管线跑质量任务并汇总。
            model = matlabcopilot.Context.currentModel();
            if strlength(string(model)) == 0
                obj.pushToUi(struct('type', "error", ...
                    'message', "没有打开的 Simulink 模型,无法运行任务流。请先打开一个模型。"));
                return;
            end
            caps = matlabcopilot.Tasks.capabilities();
            tag = "";
            if caps.padv; tag = " · Process Advisor";
            elseif caps.check; tag = " · 标准检查"; end
            if caps.test; tag = tag + " · Simulink Test"; end
            cc = char(obj.ActiveConv);
            obj.pushToUi(struct('type', "user_echo", 'convId', cc, 'text', "⚙ 运行任务流: " + string(model) + tag));
            text = matlabcopilot.Tasks.prompt(model, caps);
            ctx = matlabcopilot.Context.snapshot();
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', text, 'context', ctx));
        end

        function handleSelfHeal(obj)
            % 「自愈运行」:run → 抓错 → 修 → 重跑,最多迭代 3 次直到通过。
            % Agent 按系统提示里的「自愈验证环」流程自主驱动,每轮标注 [验证 N/3]。
            ctx = matlabcopilot.Context.snapshot();
            model = '';
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型
            cc = char(obj.ActiveConv);
            if isempty(model)
                prompt = ['请检查当前 MATLAB 工作区或最近报错中的代码。' ...
                          '若遇到错误,分析根因并修复,然后重新运行,最多迭代 3 次直到通过。' ...
                          '每次迭代用「[验证 N/3]」前缀标注进度。'];
            else
                prompt = sprintf(['请对 Simulink 模型 %s 执行自愈验证:' ...
                          '先 model_check 检查建模规范,再 model_test 跑测试套件。' ...
                          '若发现错误,分析根因并用 model_edit 修复,然后重新验证,最多迭代 3 次直到全部通过。' ...
                          '每次迭代用「[验证 N/3]」前缀报告本轮结果与改动。'], model);
            end
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                'context', ctx, 'attachments', {obj.Attachments}));
            obj.Attachments = {};
            obj.pushToUi(struct('type', "attachments", 'files', {{}}));
        end

        function handleCaptureModel(obj)
            % 「截图分析」:导出当前 Simulink 模型画布为 PNG → 发给 agent 做视觉分析。
            model = '';
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型
            if isempty(model)
                obj.pushToUi(struct('type', "status", 'text', '无打开的 Simulink 模型，请先打开一个模型。'));
                return;
            end
            try
                tmpFile = string(tempname) + ".png";
                % print -sModelName 把 Simulink 画布导出为 PNG(-r96 适合屏幕分辨率)
                print(['-s' model], '-dpng', '-r96', char(tmpFile));
                if ~isfile(tmpFile)
                    error('截图文件未生成');
                end
                % 直接作为路径型图片附件加入(与手动附件共用同一通道,发完即清)
                obj.Attachments{end+1} = struct('name', string(model) + ".png", ...
                    'content', "", 'path', tmpFile, 'isImage', true);
                obj.pushToUi(struct('type', "attachments", 'files', {obj.attachmentNames()}));
                ctx  = matlabcopilot.Context.snapshot();
                cc   = char(obj.ActiveConv);
                prompt = sprintf(['请先用 Read 工具查看附加的 Simulink 模型截图(%s.png),再系统分析:' ...
                    '①信号流与整体架构;②命名规范/未命名 block;' ...
                    '③未连接端口或悬空信号;④可疑参数取值;⑤布局可读性问题。' ...
                    '最后给出可直接执行的改进建议。'], model);
                obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                    'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                    'context', ctx, 'attachments', {obj.Attachments}));
                obj.Attachments = {};
                obj.pushToUi(struct('type', "attachments", 'files', {{}}));
            catch err
                % 用 error 类型让 UI 解除 busy(status 不会);并清掉可能已加入的陈旧截图附件。
                obj.Attachments = {};
                obj.pushToUi(struct('type', "attachments", 'files', {{}}));
                obj.pushToUi(struct('type', "error", 'convId', char(obj.ActiveConv), ...
                    'message', '模型截图失败: ' + string(err.message)));
            end
        end

        function handleRequirements(obj)
            % 「需求追溯」:反向推导需求条目,建立 block ↔ 需求双向追溯矩阵。
            ctx = matlabcopilot.Context.snapshot();
            cc  = char(obj.ActiveConv);
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型

            % 可靠检测 Requirements Toolbox:只用 license,不用 exist('slreq.load','file')
            hasReqTB = false;
            try, hasReqTB = logical(license('test', 'SL_Reqts_and_Test_Mgr')); catch, end

            nl = newline;
            if isempty(model)
                prompt = ['请分析当前 MATLAB 文件或工作区代码,完成以下需求追溯任务:' nl ...
                    '1. 推导功能需求条目,每条格式:ID(REQ-NNN)、描述、来源(函数/行号)、验证方法。' nl ...
                    '2. 输出 Markdown 表格(含表头:ID|描述|来源|验证方法|追溯状态)。' nl ...
                    '3. 标注每条需求对应的代码行范围,实现双向可追溯。' nl ...
                    '若当前无可分析的文件,请说明并给出操作步骤。'];
            else
                if hasReqTB
                    reqHint = ['环境已安装 Requirements Toolbox。' ...
                        '请额外用 evaluate_matlab_code 读取已有需求链接,' ...
                        '在表格中标注"已追溯/未追溯"状态。'];
                else
                    reqHint = '未检测到 Requirements Toolbox,输出纯 Markdown 表格(可手动导入 ReqIF/Excel)。';
                end
                prompt = [sprintf('请对 Simulink 模型 %s 执行需求追溯分析:', model) nl ...
                    '1. 用 model_overview / model_read 理解模型结构与信号流。' nl ...
                    '2. 针对每个关键 block/子系统反向推导功能需求,输出表格:' nl ...
                    '   | ID | 描述 | 来源 block 路径 | 验证方法 | 追溯状态 |' nl ...
                    '3. 标注输入/输出端口的接口需求。' nl ...
                    '4. ' reqHint nl ...
                    '5. 最后说明如何将此表格导入 ReqIF 或 Excel。'];
            end
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                'context', ctx, 'attachments', {obj.Attachments}));
            obj.Attachments = {};
            obj.pushToUi(struct('type', "attachments", 'files', {{}}));
        end

        function handleCodeGenReview(obj)
            % 「代码评审」:MISRA-C 风险 + 函数复杂度 + 向量化机会;
            %              有 Embedded Coder 时补充代码规模与 RAM/ROM 估算。
            ctx = matlabcopilot.Context.snapshot();
            cc  = char(obj.ActiveConv);
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型

            % 可靠检测 Embedded Coder:只用 license
            hasEC = false;
            try, hasEC = logical(license('test', 'RTW_Embedded_Coder')); catch, end

            nl = newline;
            if isempty(model)
                if hasEC
                    ecHint = ['环境已安装 Embedded Coder。' ...
                        '若当前文件有关联的 codegen/ 目录,可分析已生成的 C 文件行数与内存布局。'];
                else
                    ecHint = '';
                end
                prompt = ['请对当前 MATLAB 文件做代码质量审查,覆盖以下维度:' nl ...
                    '1. 函数复杂度:McCabe 圈复杂度估算,超过 10 的函数列出并建议重构。' nl ...
                    '2. MISRA-C 风险(生成 C 代码时的潜在问题):' nl ...
                    '   ① 隐式类型转换/精度丢失  ② 整数溢出或无符号下溢' nl ...
                    '   ③ 除零风险(除数未做保护)  ④ 未初始化变量/死代码' nl ...
                    '3. 向量化机会:可用矩阵运算替代的显式 for 循环。' nl ...
                    '4. 每条问题给出严重程度(高/中/低)、代码位置和修复建议。' nl ...
                    ecHint];
            else
                if hasEC
                    ecHint = [sprintf('5. Embedded Coder 代码规模:请执行 evaluate_matlab_code 生成代码(rtwbuild(''%s'')),', model) ...
                        '统计 codegen/ 下 C 文件总行数,估算静态 RAM 与 ROM 占用。'];
                else
                    ecHint = '5. 未检测到 Embedded Coder,跳过代码生成步骤。';
                end
                prompt = [sprintf('请对 Simulink 模型 %s 的代码做静态分析与评审,覆盖以下维度:', model) nl ...
                    '1. 先用 model_overview / model_read 理解模型接口与主要算法 block。' nl ...
                    '2. 函数复杂度:识别超复杂的 MATLAB Function block / Stateflow chart。' nl ...
                    '3. MISRA-C 风险评估:' nl ...
                    '   ① 类型转换(Data Type Conversion block/隐式 cast)' nl ...
                    '   ② 定点/浮点混用风险  ③ 除零保护  ④ Data Store Memory 并发风险' nl ...
                    '4. 向量化与效率:信号维度是否充分利用矩阵运算。' nl ...
                    ecHint nl ...
                    '按严重程度(高/中/低)分组,每条问题给出 block 路径和修复建议。'];
            end
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                'context', ctx, 'attachments', {obj.Attachments}));
            obj.Attachments = {};
            obj.pushToUi(struct('type', "attachments", 'files', {{}}));
        end

        function handleTestOrchestrate(obj)
            % 「测试编排」:生成测试 → 运行 → 汇总,自适应 MATLAB 文件 / Simulink 模型。
            % 运行类工具(runtests / model_test)仍走确认。
            ctx = matlabcopilot.Context.snapshot();
            cc  = char(obj.ActiveConv);
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型
            nl = newline;
            if isempty(model)
                prompt = ['任务:对当前 MATLAB 文件执行完整测试编排闭环。' nl ...
                    '1. 为当前文件/选中代码生成 MATLAB functiontests 测试(覆盖正常、边界、异常)。' nl ...
                    '2. 把测试写到与被测文件同目录的 test_*.m(写文件会弹确认)。' nl ...
                    '3. 用 run_matlab_file / runtests 运行测试(运行会弹确认)。' nl ...
                    '4. 汇总结果:总数 / 通过 / 失败 / 用时;失败项给出断言信息与可能原因。' nl ...
                    '5. 若有失败,分析根因并给出修复建议(先别擅自改被测代码,列出建议让我决定)。'];
            else
                prompt = [sprintf('任务:对 Simulink 模型 %s 执行完整测试编排闭环。', model) nl ...
                    '1. 先用 model_overview 理解模型接口(输入/输出)。' nl ...
                    '2. 用 Simulink Test(若可用)或 model_test 生成/组织测试用例,覆盖正常、边界、异常工况。' nl ...
                    '3. 运行测试套件(运行会弹确认)。' nl ...
                    '4. 汇总结果:用例数 / 通过 / 失败 / 覆盖率(若有);失败用例给出偏差与定位的 block。' nl ...
                    '5. 若有失败,分析根因并给出修复建议(先列建议,改模型前等我确认)。'];
            end
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                'context', ctx, 'attachments', {obj.Attachments}));
            obj.Attachments = {};
            obj.pushToUi(struct('type', "attachments", 'files', {{}}));
        end

        function handleBatchEdit(obj, data)
            % 「批量编辑」:用户用自然语言描述批改 → agent 定位所有目标 block → 逐个 model_edit。
            % 每处改动仍走权限确认(diff 可逐个核对),绝不一次性盲改。
            query = string(getfieldor(data, 'query', ""));
            ctx = matlabcopilot.Context.snapshot();
            cc  = char(obj.ActiveConv);
            model = char(matlabcopilot.Context.currentModel());   % 与查找/任务流一致:当前关注模型
            if isempty(model)
                obj.pushToUi(struct('type', "error", 'convId', cc, ...
                    'message', "没有打开的 Simulink 模型,无法批量编辑。请先打开一个模型。"));
                return;
            end
            nl = newline;
            prompt = [sprintf('任务:对 Simulink 模型 %s 执行批量编辑。', model) nl ...
                '批改需求:' char(query) nl nl ...   % 用户文本直接拼接,避免 sprintf 把 % / \ 当格式符
                '执行步骤:' nl ...
                '1. 先用 model_overview / model_read 理解模型结构。' nl ...
                '2. 用 model_query_params / find_system 思路定位**所有**符合需求的目标 block,先列出清单(完整路径)。' nl ...
                '3. 逐个用 model_edit 应用改动——每处改动都会弹确认,我会逐个核对 diff。' nl ...
                '4. 全部完成后用 model_read 回读抽查,汇报:共改了几处、清单、验证结果。' nl ...
                '注意:严格按需求范围操作,不要顺手改无关 block;若某个目标不确定是否该改,先问我。'];
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', prompt, ...
                'context', ctx, 'attachments', {obj.Attachments}));
            obj.Attachments = {};
            obj.pushToUi(struct('type', "attachments", 'files', {{}}));
        end

        function handleFindBlock(obj, data)
            % 「查找模块」:让 agent 语义定位符合描述的模块并解释,回答末尾输出
            % <<HILITE: 完整路径>> 标记;结果回来后由 applyHilite 在画布上原生高亮。
            query = getfieldor(data, 'query', "");
            model = matlabcopilot.Context.currentModel();
            if strlength(string(model)) == 0
                obj.pushToUi(struct('type', "error", ...
                    'message', "没有打开的 Simulink 模型,无法查找模块。请先打开一个模型。"));
                return;
            end
            obj.PendingFind = true;
            obj.PendingFindText = "";
            obj.PendingFindHits = strings(0,1);
            text = "任务:在当前 Simulink 模型「" + string(model) + "」中查找符合「" + string(query) + "」的模块。" + newline + ...
                "步骤:1) 用 model_overview / model_read 理解模型;2) 定位最匹配的那个模块;" + ...
                "3) 必须对该模块单独调用一次 model_read(传入它的完整路径)以确认;" + ...
                "4) 用简体中文解释它的作用、关键参数与上下游连接。" + newline + ...
                "【硬性要求】回答的最后一行必须原样输出高亮标记,格式严格为:<<HILITE: 模块完整路径>>" + newline + ...
                "例如:<<HILITE: " + string(model) + "/Sum>> 。路径用模型里的真实完整路径,不要加引号或反引号。" + ...
                "这一行用于在画布高亮,用户看不到。只有在模型里确实不存在匹配模块时才省略此行。";
            ctx = obj.contextWithAttachments();
            obj.Bridge.send(struct('type', "user_message", 'convId', char(obj.ActiveConv), ...
                'id', char(matlab.lang.internal.uuid()), 'text', text, 'context', ctx));
        end

        function collectFindHits(obj, msg)
            % 从一次工具调用的入参里,挑出"属于当前模型的 block 路径",留作兜底高亮。
            try
                if ~isfield(msg, 'input'); return; end
                model = matlabcopilot.Context.currentModel();
                if strlength(model) == 0; return; end
                strs = matlabcopilot.ModelSearch.collectStrings(msg.input);
                for i = 1:numel(strs)
                    s = strtrim(strs(i));
                    % 形如 "model/子系统/Block",排除只是模型名本身的情况。
                    if startsWith(s, model + "/") && strlength(s) > strlength(model) + 1
                        obj.PendingFindHits(end+1) = s; %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function applyHilite(obj, msg)
            % 高亮"查找模块"命中的 block:优先用回答里的 <<HILITE:>> 标记,
            % 取不到则回退到 agent 实际 model_read 过的最后一个 block 路径。
            try
                txt = obj.PendingFindText;
                if isfield(msg, 'text'); txt = txt + newline + string(msg.text); end
                p = matlabcopilot.ModelSearch.parseMarker(txt);
                if strlength(p) == 0 && ~isempty(obj.PendingFindHits)
                    p = obj.PendingFindHits(end);   % 兜底:agent 读过的最后一个 block
                end
                if strlength(p) == 0
                    obj.pushToUi(struct('type', "status", 'text', "未能定位可高亮的模块(已给出文字解释)"));
                    return;
                end
                if matlabcopilot.ModelSearch.highlight(p)
                    obj.pushToUi(struct('type', "status", ...
                        'text', "已在模型中高亮: " + matlabcopilot.ModelSearch.leafName(p)));
                else
                    obj.pushToUi(struct('type', "status", 'text', "高亮失败,路径可能无效: " + p));
                end
            catch
            end
        end

        function explainSelected(obj, blocks)
            % 就地解释选中的 Simulink 模块(由 Simulink 右键菜单或面板触发)。
            % 针对选中 block 的真实路径让 agent 用 model_read 读取参数,逐个精准解释。
            if nargin < 2 || isempty(blocks)
                blocks = matlabcopilot.Context.selectedBlocks();
            end
            blocks = string(blocks);
            blocks = blocks(strlength(blocks) > 0);
            try, figure(obj.Figure); catch, end  % 面板置前
            if isempty(blocks)
                obj.pushToUi(struct('type', "status", ...
                    'text', "没有选中的 Simulink 模块。请在画布上选中一个模块再试。"));
                return;
            end
            cc = char(obj.ActiveConv);
            names = arrayfun(@(b) matlabcopilot.ModelSearch.leafName(b), blocks);
            obj.pushToUi(struct('type', "user_echo", 'convId', cc, ...
                'text', "🧩 解释选中模块: " + strjoin(cellstr(names), "、")));
            list = strjoin("  - " + blocks, newline);
            text = "请解释当前 Simulink 模型中选中的模块:" + newline + list + newline + ...
                "用 model_read 读取这些模块的真实参数与端口,逐个说明:它的作用、关键参数取值、" + ...
                "输入/输出信号与上下游连接,以及它在整个模型里扮演的角色。回答用简体中文。";
            ctx = obj.contextWithAttachments();
            obj.Bridge.send(struct('type', "user_message", 'convId', cc, ...
                'id', char(matlab.lang.internal.uuid()), 'text', text, 'context', ctx));
        end

        function handleAskAtCursor(obj, data)
            % 暂存当前光标(之后会移动),用 insert 模式发请求;结果回来再插入。
            [doc, sel] = matlabcopilot.Editor.activeCursor();
            if isempty(doc)
                obj.pushToUi(struct('type', "error", 'message', "没有活动的编辑器文档,无法插入。"));
                return;
            end
            obj.PendingDoc = doc;
            obj.PendingSel = sel;
            obj.PendingInsert = true;
            ctx = matlabcopilot.Context.snapshot();
            obj.Bridge.send(struct('type', "user_message", 'convId', char(obj.ActiveConv), ...
                'id', char(matlab.lang.internal.uuid()), ...
                'text', getfieldor(data, 'text', ""), ...
                'intent', "insert_at_cursor", 'context', ctx));
        end

        % ── sidecar → MATLAB → JS ─────────────────────────────────────────
        function onSidecarMessage(obj, msg)
            if obj.PendingInsert
                obj.handleInsertMode(msg);
                return;
            end
            % 「查找模块」:边收集线索(助手文本 + 工具入参里的 block 路径),结果到了再高亮。
            if obj.PendingFind && isfield(msg, 'type')
                t = string(msg.type);
                switch t
                    case "assistant_delta"
                        if isfield(msg, 'text'); obj.PendingFindText = obj.PendingFindText + string(msg.text); end
                    case "tool_use"
                        obj.collectFindHits(msg);
                    case "result"
                        obj.PendingFind = false;
                        obj.applyHilite(msg);
                    case "error"
                        obj.PendingFind = false;
                end
            end
            obj.pushToUi(msg);
        end

        function handleInsertMode(obj, msg)
            % 生成到光标模式:吞掉助手文本气泡,等 result 把代码插入光标处。
            t = "";
            if isfield(msg, 'type'); t = string(msg.type); end
            switch t
                case {"assistant_start", "assistant_delta", "assistant_stop", "tool_use", "tool_result"}
                    % 不进聊天区
                case "result"
                    obj.PendingInsert = false;
                    code = "";
                    if isfield(msg, 'text'); code = string(msg.text); end
                    ok = matlabcopilot.Editor.insertAtCursor(obj.PendingDoc, obj.PendingSel, code);
                    if ok
                        obj.pushToUi(struct('type', "status", 'text', "已插入到光标处"));
                    else
                        obj.pushToUi(struct('type', "error", 'message', "插入失败,可手动复制代码。"));
                    end
                case "error"
                    obj.PendingInsert = false;
                    obj.pushToUi(msg);
                otherwise
                    obj.pushToUi(msg); % status 等照常透传
            end
        end

        function pushToUi(obj, eventStruct)
            % MATLAB → JS:统一推 ASCII JSON 字符串,JS 端 parse。
            % 这样可绕开 sendEventToHTMLSource 自动序列化嵌套结构体(含空 string 数组)
            % 时的静默失败,同时保证编码无歧义。
            try
                payload = matlabcopilot.Bridge.asciiJson(jsonencode(eventStruct));
                sendEventToHTMLSource(obj.HTML, 'sidecar', payload);
            catch
            end
        end

        function onClose(obj)
            % 关闭:先尽力清理(各步独立 try,任一失败都不影响删窗口),最后无条件删窗口。
            % 这样点 X 永远能关掉,绝不会因清理报错而卡住。
            try, if ~isempty(obj.Diag) && isvalid(obj.Diag); delete(obj.Diag); end, catch, end
            try, obj.Bridge.close(); catch, end
            try, delete(obj.Figure); catch, end
        end

        function delete(obj)
            try, if ~isempty(obj.Diag) && isvalid(obj.Diag); delete(obj.Diag); end, catch, end
            try, obj.Bridge.close(); catch, end
            try, delete(obj.Figure); catch, end
        end
    end

    methods (Static)
        function r = repoRoot()
            % 本文件位于 <root>/matlab/+matlabcopilot/Panel.m
            here = fileparts(mfilename('fullpath'));        % +matlabcopilot
            r = string(fileparts(fileparts(here)));         % <root>
        end

        function mode = detectTheme()
            % 返回 MATLAB 当前显示的主题:"light" 或 "dark"(供「随 MATLAB」用)。
            % 先读外观设置;若为 "System"/读取失败,再读 Windows 注册表解析实际明暗。
            mode = "dark";   % 默认暗色
            raw = "";
            try
                s = settings;
                raw = lower(string(s.matlab.appearance.MATLABTheme.ActiveValue));
            catch
            end
            if contains(raw, "dark");  mode = "dark";  return; end
            if contains(raw, "light"); mode = "light"; return; end
            % "System" 或读取失败 → 读 Windows 注册表(AppsUseLightTheme: 1=亮 0=暗)。
            try
                v = winqueryreg('HKEY_CURRENT_USER', ...
                    'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', ...
                    'AppsUseLightTheme');
                if double(v) == 0; mode = "dark"; else; mode = "light"; end
            catch
            end
        end

        function p = findActive()
            % 按窗口名查找当前活动面板(从图窗 UserData 取回),不用 persistent。
            % 找不到返回空,这样窗口一关引用即释放,不会拖住 clear classes。
            p = matlabcopilot.Panel.empty;
            try
                figs = findall(groot, 'Type', 'figure', 'Name', 'MATLAB Copilot');
                for i = 1:numel(figs)
                    ud = figs(i).UserData;
                    if isa(ud, 'matlabcopilot.Panel') && isvalid(ud)
                        p = ud; return;
                    end
                end
            catch
            end
        end

        function explainActiveSelection()
            % Simulink 右键菜单回调入口:解释当前选中的模块。
            % 面板已开 → 直接解释;未开 → 打开面板,待桥就绪后再解释。
            blocks = matlabcopilot.Context.selectedBlocks();
            p = matlabcopilot.Panel.findActive();
            if isempty(p)
                p = copilot();
                t = timer('StartDelay', 2.0, 'ExecutionMode', 'singleShot', ...
                    'TimerFcn', @(tt, ~) matlabcopilot.Panel.deferredExplain(p, blocks, tt));
                start(t);
            else
                p.explainSelected(blocks);
            end
        end

        function deferredExplain(p, blocks, t)
            % 冷启动面板后延时触发解释(供 explainActiveSelection 用)。
            try
                if ~isempty(p) && isvalid(p); p.explainSelected(blocks); end
            catch
            end
            try, stop(t); delete(t); catch, end
        end
    end
end

function v = getfieldor(s, name, dflt)
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = dflt;
    end
end
