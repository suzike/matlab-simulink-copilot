classdef StandardsChecker
    % 建模规范检查器(确定性,非 LLM):对当前模型跑一组可配置的硬规则,
    % 秒级返回结构化违规清单;AI 只负责下游的"解释原因 + 给修复建议"。
    % 这样可靠性来自确定性检查,智能来自 LLM——各干各擅长的事。
    %
    % 规则来源:项目根(面板 Cwd)的 modeling_rules.json;不存在则用内置 MAB 常用子集默认。
    % 用户 JSON 里出现的顶层字段覆盖默认(浅合并),团队拿到公司规范后只改 JSON、不改代码。
    %
    % 内置检查项(每项独立 try/catch,单项失败不影响其余):
    %   unconnected      未连接的信号线/端口(几乎必是缺陷)
    %   portNaming       Inport/Outport 命名正则(接口名是 MBD 的门面)
    %   subsystemNaming  子系统命名正则
    %   signalNaming     已命名信号线的命名正则(未命名的不管)
    %   magicNumbers     Gain/Constant 直接写数字字面量(应引用参数/数据字典;白名单豁免)
    %   forbiddenBlocks  禁用块类型(如团队禁 Goto/From 跨层)
    %   maxDepth         子系统嵌套层深上限
    %   maxBlocksPerLayer 单层块数上限(可读性)

    methods (Static)
        function rules = defaultRules()
            rules = struct();
            rules.portNaming = struct('enabled', true, ...
                'pattern', '^[A-Za-z][A-Za-z0-9_]*$', ...
                'desc', "端口名:字母开头,仅字母/数字/下划线");
            rules.subsystemNaming = struct('enabled', true, ...
                'pattern', '^[A-Za-z][A-Za-z0-9_ ]*$', ...
                'desc', "子系统名:字母开头,允许空格");
            rules.signalNaming = struct('enabled', true, ...
                'pattern', '^[a-zA-Z][A-Za-z0-9_]*$', ...
                'desc', "命名信号:字母开头,仅字母/数字/下划线");
            rules.unconnected = struct('enabled', true);
            rules.magicNumbers = struct('enabled', true, ...
                'allow', {{'0', '1', '-1', '2', '0.5', 'pi', 'inf', '-inf'}});
            rules.forbiddenBlocks = struct('enabled', true, 'types', {{}});   % 默认不禁,团队按规范填
            rules.maxDepth = struct('enabled', true, 'value', 6);
            rules.maxBlocksPerLayer = struct('enabled', true, 'value', 45);
        end

        function [rules, src, loadError] = loadRules(startDir)
            % 读项目根 modeling_rules.json 并浅合并到默认;无文件/解析失败 → 纯默认。
            rules = matlabcopilot.StandardsChecker.defaultRules();
            src = "内置默认(MAB 子集)";
            loadError = "";
            try
                f = fullfile(char(startDir), 'modeling_rules.json');
                if ~isfile(f); return; end
                user = jsondecode(fileread(f));
                if ~isstruct(user) || ~isscalar(user)
                    error('matlabcopilot:StandardsChecker:InvalidRules', '规则文件顶层必须是 JSON object。');
                end
                fn = fieldnames(user);
                for i = 1:numel(fn)
                    rules.(fn{i}) = user.(fn{i});   % 顶层字段整体覆盖,语义简单可预期
                end
                matlabcopilot.StandardsChecker.validateRules(rules);
                src = "modeling_rules.json";
            catch err
                rules = matlabcopilot.StandardsChecker.defaultRules();
                src = "modeling_rules.json(无效，已回退内置默认)";
                loadError = string(err.message);
            end
        end

        function out = check(model, rules)
            % 跑全部启用的规则,返回 findings 结构数组(封顶 150 条,防超大模型刷屏)。
            out = struct('rule', {}, 'severity', {}, 'path', {}, 'msg', {});
            m = char(model);
            out = matlabcopilot.StandardsChecker.ckUnconnected(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckPortNaming(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckSubsystemNaming(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckSignalNaming(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckMagicNumbers(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckForbidden(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckDepth(m, rules, out);
            out = matlabcopilot.StandardsChecker.ckLayerSize(m, rules, out);
            out = out(1:min(150, end));
        end

        function ev = report(model, cwd, convId)
            % 面向 UI 的一站式入口:载规则 → 检查 → 组装 standards_report 事件。
            [rules, src, loadError] = matlabcopilot.StandardsChecker.loadRules(cwd);
            f = matlabcopilot.StandardsChecker.check(model, rules);
            if strlength(loadError) > 0
                cfg = struct('rule', "ruleConfig", 'severity', "error", ...
                    'path', string(fullfile(char(cwd), 'modeling_rules.json')), ...
                    'msg', "规则文件无效，当前结果仅使用内置默认:" + loadError);
                f = [cfg, f];
            end
            nErr = nnz(string({f.severity}) == "error");
            ev = struct('type', "standards_report", 'convId', char(convId), ...
                'model', char(model), 'source', char(src), ...
                'errors', nErr, 'warns', numel(f) - nErr, ...
                'findings', {num2cell(f)});
        end

        % ── 各检查项 ─────────────────────────────────────────────────────
        function out = ckUnconnected(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'unconnected'); return; end
                % 悬空线:目的端未接。
                ln = find_system(m, 'FindAll', 'on', 'Type', 'line', 'Connected', 'off');
                for i = 1:min(30, numel(ln))
                    p = get_param(ln(i), 'Parent');
                    out(end+1) = struct('rule', "unconnected", 'severity', "error", ...
                        'path', string(p), 'msg', "存在未连接的信号线"); %#ok<AGROW>
                end
                % 悬空端口(线都没有):PortConnectivity 里无对端的端口。
                blks = find_system(m, 'FollowLinks', 'off', 'LookUnderMasks', 'none', 'Type', 'Block');
                for i = 1:numel(blks)
                    try
                        pc = get_param(blks{i}, 'PortConnectivity');
                    catch
                        continue;
                    end
                    for k = 1:numel(pc)
                        noSrc = isempty(pc(k).SrcBlock) || isequal(pc(k).SrcBlock, -1);
                        noDst = isempty(pc(k).DstBlock) || isequal(pc(k).DstBlock, -1);
                        if noSrc && noDst
                            out(end+1) = struct('rule', "unconnected", 'severity', "error", ...
                                'path', string(blks{i}), ...
                                'msg', "端口 " + string(pc(k).Type) + " 未连接"); %#ok<AGROW>
                            break;   % 一个块报一次即可
                        end
                    end
                end
            catch
            end
        end

        function out = ckPortNaming(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'portNaming'); return; end
                pat = char(string(rules.portNaming.pattern));
                blks = [find_system(m, 'BlockType', 'Inport'); find_system(m, 'BlockType', 'Outport')];
                for i = 1:numel(blks)
                    nm = get_param(blks{i}, 'Name');
                    if isempty(regexp(nm, pat, 'once'))
                        out(end+1) = struct('rule', "portNaming", 'severity', "warn", ...
                            'path', string(blks{i}), ...
                            'msg', "端口名不符合规范 " + string(pat)); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function out = ckSubsystemNaming(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'subsystemNaming'); return; end
                pat = char(string(rules.subsystemNaming.pattern));
                blks = find_system(m, 'BlockType', 'SubSystem');
                for i = 1:numel(blks)
                    nm = get_param(blks{i}, 'Name');
                    if isempty(regexp(nm, pat, 'once'))
                        out(end+1) = struct('rule', "subsystemNaming", 'severity', "warn", ...
                            'path', string(blks{i}), ...
                            'msg', "子系统名不符合规范 " + string(pat)); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function out = ckSignalNaming(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'signalNaming'); return; end
                pat = char(string(rules.signalNaming.pattern));
                ln = find_system(m, 'FindAll', 'on', 'Type', 'line');
                for i = 1:numel(ln)
                    nm = get_param(ln(i), 'Name');
                    if isempty(nm); continue; end   % 未命名信号不管
                    if isempty(regexp(nm, pat, 'once'))
                        out(end+1) = struct('rule', "signalNaming", 'severity', "warn", ...
                            'path', string(get_param(ln(i), 'Parent')), ...
                            'msg', "信号名『" + string(nm) + "』不符合规范 " + string(pat)); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function out = ckMagicNumbers(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'magicNumbers'); return; end
                allow = string(rules.magicNumbers.allow);
                targets = {{'Gain', 'Gain'}, {'Constant', 'Value'}};
                for t = 1:numel(targets)
                    blks = find_system(m, 'BlockType', targets{t}{1});
                    for i = 1:numel(blks)
                        v = strtrim(get_param(blks{i}, targets{t}{2}));
                        isLiteral = ~isempty(regexp(v, '^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$', 'once'));
                        if isLiteral && ~any(allow == string(v))
                            out(end+1) = struct('rule', "magicNumbers", 'severity', "warn", ...
                                'path', string(blks{i}), ...
                                'msg', "魔术数字 " + string(v) + "(应引用标定参数/数据字典变量)"); %#ok<AGROW>
                        end
                    end
                end
            catch
            end
        end

        function out = ckForbidden(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'forbiddenBlocks'); return; end
                types = string(rules.forbiddenBlocks.types);
                for t = 1:numel(types)
                    blks = find_system(m, 'BlockType', char(types(t)));
                    for i = 1:numel(blks)
                        out(end+1) = struct('rule', "forbiddenBlocks", 'severity', "error", ...
                            'path', string(blks{i}), ...
                            'msg', "禁用块类型 " + types(t)); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function out = ckDepth(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'maxDepth'); return; end
                lim = double(rules.maxDepth.value);
                subs = find_system(m, 'BlockType', 'SubSystem');
                base = count(string(m), '/');
                for i = 1:numel(subs)
                    d = count(regexprep(string(subs{i}), '//', ''), '/') - base;
                    if d > lim
                        out(end+1) = struct('rule', "maxDepth", 'severity', "warn", ...
                            'path', string(subs{i}), ...
                            'msg', "嵌套层深 " + d + " 超过上限 " + lim); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function out = ckLayerSize(m, rules, out)
            try
                if ~matlabcopilot.StandardsChecker.on(rules, 'maxBlocksPerLayer'); return; end
                lim = double(rules.maxBlocksPerLayer.value);
                layers = [{m}; find_system(m, 'BlockType', 'SubSystem')];
                for i = 1:numel(layers)
                    n = numel(find_system(layers{i}, 'SearchDepth', 1, 'Type', 'Block'));
                    if i > 1; n = n - 1; end   % 子系统自身也被计入,扣掉
                    if n > lim
                        out(end+1) = struct('rule', "maxBlocksPerLayer", 'severity', "warn", ...
                            'path', string(layers{i}), ...
                            'msg', "单层 " + n + " 个块,超过上限 " + lim + "(建议分组为子系统)"); %#ok<AGROW>
                    end
                end
            catch
            end
        end

        function tf = on(rules, name)
            % 规则是否启用(字段缺失/enabled 缺失都当启用,便于用户 JSON 少写)。
            tf = isfield(rules, name) && ...
                (~isfield(rules.(name), 'enabled') || logical(rules.(name).enabled));
        end

        function validateRules(rules)
            names = ["portNaming", "subsystemNaming", "signalNaming", "unconnected", ...
                "magicNumbers", "forbiddenBlocks", "maxDepth", "maxBlocksPerLayer"];
            for i = 1:numel(names)
                n = char(names(i));
                if ~isfield(rules, n) || ~isstruct(rules.(n)) || ~isscalar(rules.(n))
                    error('matlabcopilot:StandardsChecker:InvalidRules', '规则 %s 必须是 JSON object。', n);
                end
            end
            for n = ["portNaming", "subsystemNaming", "signalNaming"]
                key = char(n);
                if matlabcopilot.StandardsChecker.on(rules, key)
                    if ~isfield(rules.(key), 'pattern'); error('规则 %s 缺少 pattern。', key); end
                    regexp('', char(string(rules.(key).pattern)), 'once');
                end
            end
            if matlabcopilot.StandardsChecker.on(rules, 'magicNumbers') && ~isfield(rules.magicNumbers, 'allow')
                error('规则 magicNumbers 缺少 allow。');
            end
            if matlabcopilot.StandardsChecker.on(rules, 'forbiddenBlocks') && ~isfield(rules.forbiddenBlocks, 'types')
                error('规则 forbiddenBlocks 缺少 types。');
            end
            for n = ["maxDepth", "maxBlocksPerLayer"]
                key = char(n);
                if matlabcopilot.StandardsChecker.on(rules, key)
                    if ~isfield(rules.(key), 'value') || ~isscalar(rules.(key).value) || ...
                            ~isfinite(double(rules.(key).value)) || double(rules.(key).value) < 1
                        error('规则 %s 的 value 必须是正数。', key);
                    end
                end
            end
        end
    end
end
