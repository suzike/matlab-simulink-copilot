classdef MBSEWorkflow
    % 工程级 MBSE 工作流。工程内 JSON/CSV 是设计源，MATLAB 工件是可重建产物。

    methods (Static)
        function state = status(projectRoot)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            file = matlabcopilot.MBSEWorkflow.workflowFile(root);
            if isfile(file)
                state = jsondecode(fileread(file));
                state = matlabcopilot.MBSEWorkflow.normalizeState(state, root);
            else
                state = matlabcopilot.MBSEWorkflow.defaultState(root);
            end
            state.capabilities = matlabcopilot.MBSEWorkflow.capabilities();
        end

        function result = apply(projectRoot, action, phaseId, config)
            if nargin < 4 || isempty(config); config = struct(); end
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            action = lower(string(action));
            phaseId = upper(string(phaseId));
            if action == "status"
                result = matlabcopilot.MBSEWorkflow.result( ...
                    matlabcopilot.MBSEWorkflow.status(root), true, "已读取 MBSE 工作流状态", struct());
                return;
            end
            if action == "initialize"
                state = matlabcopilot.MBSEWorkflow.initialize(root, config);
                result = matlabcopilot.MBSEWorkflow.result(state, true, ...
                    "MBSE 工作区已初始化；请完善需求源和功能架构提案后再提交评审。", ...
                    matlabcopilot.MBSEWorkflow.entry("mbse_initialized", state, "MBSE 工作区初始化完成"));
                return;
            end

            state = matlabcopilot.MBSEWorkflow.status(root);
            if ~logical(state.initialized)
                error('matlabcopilot:MBSEWorkflow:NotInitialized', '请先初始化 MBSE 工作区。');
            end
            if ~any(phaseId == ["R", "F", "L", "P", "V"])
                error('matlabcopilot:MBSEWorkflow:UnsupportedPhase', '未知 RFLPV 阶段: %s', phaseId);
            end
            idx = matlabcopilot.MBSEWorkflow.phaseIndex(state, phaseId);
            switch action
                case "propose"
                    matlabcopilot.MBSEWorkflow.requirePreviousConfirmed(root, state, idx);
                    details = matlabcopilot.MBSEWorkflow.validateSource(root, state, phaseId);
                    state = matlabcopilot.MBSEWorkflow.invalidateFrom(state, idx);
                    state.phases(idx).status = 'proposed';
                    state.phases(idx).summary = char(details.summary);
                    state.phases(idx).sourceHash = char(matlabcopilot.MBSEWorkflow.phaseSourceHash(root, state, phaseId));
                    state.phases(idx).proposedAt = matlabcopilot.MBSEWorkflow.nowText();
                    message = phaseId + " 阶段提案已通过结构校验，等待人工批准。";
                    kind = "mbse_proposed";
                case "approve"
                    matlabcopilot.MBSEWorkflow.requireStatus(state, idx, "proposed", "批准");
                    matlabcopilot.MBSEWorkflow.requireSourceUnchanged(root, state, idx);
                    state.phases(idx).status = 'approved';
                    state.phases(idx).approvedAt = matlabcopilot.MBSEWorkflow.nowText();
                    message = phaseId + " 阶段提案已批准，可生成构建步骤。";
                    kind = "mbse_approved";
                case "generate"
                    matlabcopilot.MBSEWorkflow.requireStatus(state, idx, "approved", "生成");
                    matlabcopilot.MBSEWorkflow.requireSourceUnchanged(root, state, idx);
                    matlabcopilot.MBSEWorkflow.writeBuildScript(root, phaseId);
                    state.phases(idx).status = 'generated';
                    state.phases(idx).generatedAt = matlabcopilot.MBSEWorkflow.nowText();
                    state.phases(idx).script = char(matlabcopilot.MBSEWorkflow.relativePath(root, ...
                        matlabcopilot.MBSEWorkflow.scriptFile(root, phaseId)));
                    message = phaseId + " 阶段构建脚本已生成，可执行真实 MATLAB 构建。";
                    kind = "mbse_generated";
                case "run"
                    matlabcopilot.MBSEWorkflow.requireAnyStatus(state, idx, ["generated", "executed"], "执行");
                    matlabcopilot.MBSEWorkflow.requireSourceUnchanged(root, state, idx);
                    state = matlabcopilot.MBSEWorkflow.execute(root, state, phaseId);
                    idx = matlabcopilot.MBSEWorkflow.phaseIndex(state, phaseId);
                    state.phases(idx).status = 'executed';
                    state.phases(idx).executedAt = matlabcopilot.MBSEWorkflow.nowText();
                    message = phaseId + " 阶段真实工件已构建，等待验证确认。";
                    kind = "mbse_executed";
                case "confirm"
                    matlabcopilot.MBSEWorkflow.requireStatus(state, idx, "executed", "确认");
                    matlabcopilot.MBSEWorkflow.requireSourceUnchanged(root, state, idx);
                    verification = matlabcopilot.MBSEWorkflow.verify(root, state, phaseId);
                    if ~logical(verification.ok)
                        error('matlabcopilot:MBSEWorkflow:VerificationFailed', '%s', verification.message);
                    end
                    state.phases(idx).status = 'confirmed';
                    state.phases(idx).confirmedAt = matlabcopilot.MBSEWorkflow.nowText();
                    state.phases(idx).verification = verification;
                    ids = ["R", "F", "L", "P", "V"];
                    pos = find(ids == phaseId, 1);
                    if pos < numel(ids)
                        nextId = ids(pos + 1);
                        state.currentPhase = char(nextId);
                        nextIdx = matlabcopilot.MBSEWorkflow.phaseIndex(state, nextId);
                        if string(state.phases(nextIdx).status) == "planned"
                            state.phases(nextIdx).status = 'draft';
                        end
                    end
                    message = phaseId + " 阶段验证通过并已确认。";
                    kind = "mbse_confirmed";
                otherwise
                    error('matlabcopilot:MBSEWorkflow:UnknownAction', '未知 MBSE 动作: %s', action);
            end
            state.updatedAt = matlabcopilot.MBSEWorkflow.nowText();
            matlabcopilot.MBSEWorkflow.writeState(root, state);
            state.capabilities = matlabcopilot.MBSEWorkflow.capabilities();
            result = matlabcopilot.MBSEWorkflow.result(state, true, message, ...
                matlabcopilot.MBSEWorkflow.entry(kind, state, message, phaseId));
        end

        function state = initialize(projectRoot, config)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            state = matlabcopilot.MBSEWorkflow.status(root);
            state.initialized = true;
            state.systemName = char(matlabcopilot.MBSEWorkflow.safeName( ...
                matlabcopilot.MBSEWorkflow.field(config, 'systemName', state.systemName)));
            state.description = char(string(matlabcopilot.MBSEWorkflow.field(config, 'description', state.description)));
            entryPhase = upper(string(matlabcopilot.MBSEWorkflow.field(config, 'entryPhase', state.currentPhase)));
            if ~any(entryPhase == ["R", "F"]); entryPhase = "R"; end
            state.currentPhase = char(entryPhase);

            dirs = matlabcopilot.MBSEWorkflow.directories(root);
            names = fieldnames(dirs);
            for i = 1:numel(names)
                if ~isfolder(dirs.(names{i})); mkdir(dirs.(names{i})); end
            end

            reqSource = string(matlabcopilot.MBSEWorkflow.field(config, 'requirementsSource', ""));
            if strlength(strtrim(reqSource)) == 0
                if isfile(fullfile(root, 'requirements.json')); reqSource = "requirements.json";
                elseif isfile(fullfile(root, 'requirements.csv')); reqSource = "requirements.csv";
                else; reqSource = fullfile('mbse', 'requirements', 'requirements.csv');
                end
            end
            reqFile = matlabcopilot.MBSEWorkflow.absolutePath(root, reqSource);
            if ~isfile(reqFile)
                matlabcopilot.MBSEWorkflow.writeTextAtomic(reqFile, "ID,Title,Description" + newline);
            end
            state.requirementsSource = char(matlabcopilot.MBSEWorkflow.relativePath(root, reqFile));

            functionalFile = fullfile(dirs.architecture, 'functional-architecture.json');
            if ~isfile(functionalFile)
                proposal = struct('schemaVersion', 1, ...
                    'modelName', char(matlabcopilot.MBSEWorkflow.safeName(state.systemName + "Functional")), ...
                    'functions', {{}}, 'connections', {{}});
                matlabcopilot.MBSEWorkflow.writeJsonAtomic(functionalFile, proposal);
            end
            state.functionalSource = char(matlabcopilot.MBSEWorkflow.relativePath(root, functionalFile));

            logicalFile = fullfile(dirs.architecture, 'logical-architecture.json');
            if ~isfile(logicalFile)
                proposal = struct('schemaVersion', 1, ...
                    'modelName', char(matlabcopilot.MBSEWorkflow.safeName(state.systemName + "Logical")), ...
                    'elements', {{}}, 'connections', {{}});
                matlabcopilot.MBSEWorkflow.writeJsonAtomic(logicalFile, proposal);
            end
            state.logicalSource = char(matlabcopilot.MBSEWorkflow.relativePath(root, logicalFile));

            physicalFile = fullfile(dirs.architecture, 'physical-architecture.json');
            if ~isfile(physicalFile)
                proposal = struct('schemaVersion', 1, ...
                    'modelName', char(matlabcopilot.MBSEWorkflow.safeName(state.systemName + "Physical")), ...
                    'profileName', char(matlabcopilot.MBSEWorkflow.safeName(state.systemName + "PhysicalProfile")), ...
                    'components', {{}}, 'connections', {{}});
                matlabcopilot.MBSEWorkflow.writeJsonAtomic(physicalFile, proposal);
            end
            state.physicalSource = char(matlabcopilot.MBSEWorkflow.relativePath(root, physicalFile));

            verificationFile = fullfile(dirs.base, 'verification-plan.json');
            if ~isfile(verificationFile)
                plan = struct('schemaVersion', 1, 'verificationItems', {{}});
                matlabcopilot.MBSEWorkflow.writeJsonAtomic(verificationFile, plan);
            end
            state.verificationSource = char(matlabcopilot.MBSEWorkflow.relativePath(root, verificationFile));

            if entryPhase == "F"
                ridx = matlabcopilot.MBSEWorkflow.phaseIndex(state, "R");
                state.phases(ridx).status = 'confirmed';
                state.phases(ridx).summary = 'Brownfield entry: existing requirements accepted as baseline';
                state.phases(ridx).sourceHash = char(matlabcopilot.MBSEWorkflow.phaseSourceHash(root, state, "R"));
                state.phases(ridx).confirmedAt = matlabcopilot.MBSEWorkflow.nowText();
                fidx = matlabcopilot.MBSEWorkflow.phaseIndex(state, "F");
                if string(state.phases(fidx).status) == "planned"; state.phases(fidx).status = 'draft'; end
            end
            state.updatedAt = matlabcopilot.MBSEWorkflow.nowText();
            matlabcopilot.MBSEWorkflow.writeState(root, state);
            state.capabilities = matlabcopilot.MBSEWorkflow.capabilities();
        end

        function state = executeRequirements(projectRoot, state)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            caps = matlabcopilot.MBSEWorkflow.capabilities();
            if ~caps.requirementsToolbox
                error('matlabcopilot:MBSEWorkflow:NoRequirementsToolbox', '未检测到 Requirements Toolbox 许可证。');
            end
            reqs = matlabcopilot.MBSEWorkflow.readRequirements( ...
                matlabcopilot.MBSEWorkflow.absolutePath(root, state.requirementsSource));
            if isempty(reqs); error('matlabcopilot:MBSEWorkflow:EmptyRequirements', '需求源没有有效条目。'); end
            out = fullfile(root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
            if ~isfolder(fileparts(out)); mkdir(fileparts(out)); end
            addpath(fileparts(out));
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, out);
            slreq.clear();
            cleaner = onCleanup(@() slreq.clear()); %#ok<NASGU>
            if isfile(out)
                rs = slreq.load(out);
                linkSets = slreq.find('Type', 'LinkSet', 'Artifact', out);
                for i = 1:numel(linkSets)
                    links = linkSets(i).getLinks();
                    for k = numel(links):-1:1; links(k).remove(); end
                end
                existing = rs.find('Type', 'Requirement');
                for i = numel(existing):-1:1; existing(i).remove(); end
            else
                rs = slreq.new(out);
            end
            for i = 1:numel(reqs)
                add(rs, 'Id', char(reqs(i).id), 'Summary', char(reqs(i).title), ...
                    'Description', char(reqs(i).text));
            end
            save(rs);
            state = matlabcopilot.MBSEWorkflow.own(root, state, out);
            state = matlabcopilot.MBSEWorkflow.registerProjectArtifacts(root, state, out);
        end

        function state = executeFunctional(projectRoot, state)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            caps = matlabcopilot.MBSEWorkflow.capabilities();
            if ~caps.systemComposer
                error('matlabcopilot:MBSEWorkflow:NoSystemComposer', '未检测到 System Composer 许可证。');
            end
            source = matlabcopilot.MBSEWorkflow.readFunctional(root, state);
            generated = fullfile(root, 'mbse', 'generated', 'architecture');
            if ~isfolder(generated); mkdir(generated); end
            addpath(generated);
            modelName = matlabcopilot.MBSEWorkflow.safeName(source.modelName);
            modelFile = fullfile(generated, modelName + ".slx");
            dictFile = fullfile(generated, modelName + "Interfaces.sldd");
            linkFile = fullfile(generated, modelName + "~mdl.slmx");
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, modelFile);
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, dictFile);
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, linkFile);
            slreq.clear();
            if bdIsLoaded(modelName); close_system(modelName, 0); end
            if isfile(modelFile); delete(modelFile); end
            if isfile(dictFile); delete(dictFile); end
            if isfile(linkFile); delete(linkFile); end
            Simulink.data.dictionary.closeAll('-discard');

            old = pwd;
            cleanup = onCleanup(@() cd(old)); %#ok<NASGU>
            cd(generated);
            dict = systemcomposer.createDictionary(dictFile);
            flowNames = matlabcopilot.MBSEWorkflow.flowNames(source);
            for i = 1:numel(flowNames)
                iface = addInterface(dict, matlabcopilot.MBSEWorkflow.interfaceName(flowNames(i)));
                addElement(iface, 'Value', 'Type', 'double');
            end
            dict.save();
            model = systemcomposer.createModel(char(modelName));
            arch = model.Architecture;
            linkDictionary(model, dictFile);
            comps = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for i = 1:numel(source.functions)
                spec = source.functions(i);
                comp = addComponent(arch, char(spec.name), 'Position', [80 + 210*(i-1), 100, 190 + 210*(i-1), 180]);
                comps(char(spec.name)) = comp;
                inputs = matlabcopilot.MBSEWorkflow.stringList(spec, 'inputs');
                outputs = matlabcopilot.MBSEWorkflow.stringList(spec, 'outputs');
                for k = 1:numel(inputs)
                    port = addPort(comp.Architecture, char(inputs(k)), 'in');
                    iface = dict.getInterface(matlabcopilot.MBSEWorkflow.interfaceName(inputs(k)));
                    port.setInterface(iface);
                end
                for k = 1:numel(outputs)
                    port = addPort(comp.Architecture, char(outputs(k)), 'out');
                    iface = dict.getInterface(matlabcopilot.MBSEWorkflow.interfaceName(outputs(k)));
                    port.setInterface(iface);
                end
            end
            for i = 1:numel(source.connections)
                [srcComp, srcPort] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).source);
                [dstComp, dstPort] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).destination);
                connect(comps(srcComp).getPort(srcPort), comps(dstComp).getPort(dstPort));
            end
            save_system(char(modelName), char(modelFile));
            state = matlabcopilot.MBSEWorkflow.linkFunctionalRequirements(root, state, source, comps);
            save_system(char(modelName));
            close_system(char(modelName), 0);
            state = matlabcopilot.MBSEWorkflow.own(root, state, modelFile);
            state = matlabcopilot.MBSEWorkflow.own(root, state, dictFile);
            artifacts = [modelFile, dictFile];
            if isfile(linkFile)
                state = matlabcopilot.MBSEWorkflow.own(root, state, linkFile);
                artifacts(end+1) = linkFile;
            end
            state = matlabcopilot.MBSEWorkflow.registerProjectArtifacts(root, state, artifacts);
        end

        function state = executeLogical(projectRoot, state)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            source = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements');
            [state, built] = matlabcopilot.MBSEWorkflow.buildArchitectureLayer( ...
                root, state, source, 'elements', false);
            functional = matlabcopilot.MBSEWorkflow.readFunctional(root, state);
            mappings = matlabcopilot.MBSEWorkflow.layerMappings(source.elements, 'functions');
            state = matlabcopilot.MBSEWorkflow.buildAllocation(root, state, ...
                functional.modelName, built.modelName, ...
                matlabcopilot.MBSEWorkflow.safeName(state.systemName + "FunctionalToLogical"), mappings);
        end

        function state = executePhysical(projectRoot, state)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            source = matlabcopilot.MBSEWorkflow.readLayer(root, state.physicalSource, 'components');
            [state, built] = matlabcopilot.MBSEWorkflow.buildArchitectureLayer( ...
                root, state, source, 'components', true);
            logical = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements');
            mappings = matlabcopilot.MBSEWorkflow.layerMappings(source.components, 'logicalElements');
            state = matlabcopilot.MBSEWorkflow.buildAllocation(root, state, ...
                logical.modelName, built.modelName, ...
                matlabcopilot.MBSEWorkflow.safeName(state.systemName + "LogicalToPhysical"), mappings);
        end

        function state = executeVerification(projectRoot, state)
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            plan = matlabcopilot.MBSEWorkflow.readVerification(root, state);
            results = matlabcopilot.MBSEWorkflow.runVerificationItems(root, state, plan.verificationItems);
            passed = sum(string({results.status}) == "passed");
            failed = sum(string({results.status}) == "failed");
            report = struct('schemaVersion', 1, 'generatedAt', matlabcopilot.MBSEWorkflow.nowText(), ...
                'projectRoot', char(root), 'systemName', char(state.systemName), ...
                'overallOk', failed == 0 && passed == numel(results) && ~isempty(results), ...
                'passed', passed, 'failed', failed, 'results', results);
            dirPath = fullfile(root, 'mbse', 'generated', 'verification');
            if ~isfolder(dirPath); mkdir(dirPath); end
            jsonFile = fullfile(dirPath, 'verification-report.json');
            mdFile = fullfile(dirPath, 'verification-report.md');
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, jsonFile);
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, mdFile);
            matlabcopilot.MBSEWorkflow.writeJsonAtomic(jsonFile, report);
            matlabcopilot.MBSEWorkflow.writeTextAtomic(mdFile, ...
                matlabcopilot.MBSEWorkflow.verificationMarkdown(report));
            state = matlabcopilot.MBSEWorkflow.own(root, state, jsonFile);
            state = matlabcopilot.MBSEWorkflow.own(root, state, mdFile);
            state = matlabcopilot.MBSEWorkflow.registerProjectArtifacts(root, state, [jsonFile, mdFile]);
        end

        function saveState(projectRoot, state)
            % 供工程内构建脚本保存生成物所有权和时间戳。
            root = matlabcopilot.MBSEWorkflow.requireRoot(projectRoot);
            state.updatedAt = matlabcopilot.MBSEWorkflow.nowText();
            matlabcopilot.MBSEWorkflow.writeState(root, state);
        end
    end

    methods (Static, Access=private)
        function state = execute(root, state, phaseId)
            switch phaseId
                case "R"; state = matlabcopilot.MBSEWorkflow.executeRequirements(root, state);
                case "F"; state = matlabcopilot.MBSEWorkflow.executeFunctional(root, state);
                case "L"; state = matlabcopilot.MBSEWorkflow.executeLogical(root, state);
                case "P"; state = matlabcopilot.MBSEWorkflow.executePhysical(root, state);
                case "V"; state = matlabcopilot.MBSEWorkflow.executeVerification(root, state);
            end
            matlabcopilot.MBSEWorkflow.writeState(root, state);
        end

        function details = validateSource(root, state, phaseId)
            reqs = matlabcopilot.MBSEWorkflow.readRequirements( ...
                matlabcopilot.MBSEWorkflow.absolutePath(root, state.requirementsSource));
            knownReqs = string({reqs.id});
            switch phaseId
                case "R"
                    if isempty(reqs); error('matlabcopilot:MBSEWorkflow:EmptyRequirements', '需求源没有有效条目。'); end
                    if numel(unique(knownReqs)) ~= numel(knownReqs)
                        error('matlabcopilot:MBSEWorkflow:DuplicateRequirement', '需求 ID 必须唯一。');
                    end
                    details = struct('summary', numel(reqs) + " 条需求已通过结构校验");
                case "F"
                    source = matlabcopilot.MBSEWorkflow.readFunctional(root, state);
                    details = matlabcopilot.MBSEWorkflow.validateLayer( ...
                        source, 'functions', 'requirements', knownReqs, true, "功能");
                case "L"
                    source = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements');
                    upstream = matlabcopilot.MBSEWorkflow.readFunctional(root, state);
                    details = matlabcopilot.MBSEWorkflow.validateLayer( ...
                        source, 'elements', 'functions', string({upstream.functions.name}), true, "逻辑元素");
                    matlabcopilot.MBSEWorkflow.validateOptionalRequirements(source.elements, knownReqs);
                case "P"
                    source = matlabcopilot.MBSEWorkflow.readLayer(root, state.physicalSource, 'components');
                    upstream = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements');
                    details = matlabcopilot.MBSEWorkflow.validateLayer( ...
                        source, 'components', 'logicalElements', string({upstream.elements.name}), true, "物理组件");
                    matlabcopilot.MBSEWorkflow.validateOptionalRequirements(source.components, knownReqs);
                case "V"
                    plan = matlabcopilot.MBSEWorkflow.readVerification(root, state);
                    items = plan.verificationItems;
                    if isempty(items); error('matlabcopilot:MBSEWorkflow:EmptyVerification', '验证计划至少需要一项验证。'); end
                    ids = string({items.id});
                    if any(strlength(ids) == 0) || numel(unique(lower(ids))) ~= numel(ids)
                        error('matlabcopilot:MBSEWorkflow:InvalidVerificationId', '验证项 ID 必须非空且唯一。');
                    end
                    covered = strings(0, 1);
                    allowed = ["architecture_trace", "matlab_test", "test_manager", "artifact_review"];
                    for i = 1:numel(items)
                        reqId = string(items(i).requirementId);
                        if ~any(knownReqs == reqId)
                            error('matlabcopilot:MBSEWorkflow:UnknownRequirement', '验证项 %s 引用了未知需求 %s。', items(i).id, reqId);
                        end
                        method = lower(string(items(i).method));
                        if ~any(allowed == method)
                            error('matlabcopilot:MBSEWorkflow:InvalidVerificationMethod', '验证项 %s 的方法无效: %s', items(i).id, method);
                        end
                        if method ~= "architecture_trace" && strlength(string(matlabcopilot.MBSEWorkflow.field(items(i), 'artifact', ""))) == 0
                            error('matlabcopilot:MBSEWorkflow:MissingVerificationArtifact', '验证项 %s 缺少 artifact。', items(i).id);
                        end
                        covered(end+1, 1) = reqId; %#ok<AGROW>
                    end
                    missing = setdiff(knownReqs, unique(covered));
                    if ~isempty(missing)
                        error('matlabcopilot:MBSEWorkflow:UnverifiedRequirement', '以下需求未分配验证项: %s', strjoin(missing, ', '));
                    end
                    details = struct('summary', numel(items) + " 个验证项覆盖 " + numel(knownReqs) + " 条需求");
            end
        end

        function verification = verify(root, state, phaseId)
            if phaseId == "R"
                source = matlabcopilot.MBSEWorkflow.readRequirements( ...
                    matlabcopilot.MBSEWorkflow.absolutePath(root, state.requirementsSource));
                file = fullfile(root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
                if ~isfile(file)
                    verification = struct('ok', false, 'message', '原生 .slreqx 工件不存在。'); return;
                end
                addpath(fileparts(file));
                slreq.clear(); cleaner = onCleanup(@() slreq.clear()); %#ok<NASGU>
                rs = slreq.load(file); actual = numel(rs.find('Type', 'Requirement'));
                ok = actual == numel(source);
                verification = struct('ok', ok, 'message', char(matlabcopilot.MBSEWorkflow.choose(ok, ...
                    "需求集验证通过", "需求条目数与源文件不一致")), ...
                    'sourceCount', numel(source), 'artifactCount', actual, ...
                    'artifact', char(matlabcopilot.MBSEWorkflow.relativePath(root, file)));
                return;
            end
            if phaseId == "V"
                file = fullfile(root, 'mbse', 'generated', 'verification', 'verification-report.json');
                if ~isfile(file); verification = struct('ok', false, 'message', '验证报告不存在。'); return; end
                report = jsondecode(fileread(file));
                verification = struct('ok', logical(report.overallOk), ...
                    'message', char(matlabcopilot.MBSEWorkflow.choose(report.overallOk, "验证计划全部通过", "验证计划存在失败项")), ...
                    'passed', report.passed, 'failed', report.failed, ...
                    'artifact', char(matlabcopilot.MBSEWorkflow.relativePath(root, file)));
                return;
            end
            if phaseId == "F"
                source = matlabcopilot.MBSEWorkflow.readFunctional(root, state); itemField = 'functions'; label = "功能架构";
            elseif phaseId == "L"
                source = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements'); itemField = 'elements'; label = "逻辑架构";
            else
                source = matlabcopilot.MBSEWorkflow.readLayer(root, state.physicalSource, 'components'); itemField = 'components'; label = "物理架构";
            end
            verification = matlabcopilot.MBSEWorkflow.verifyArchitecture(root, source, itemField, label);
            if logical(verification.ok) && any(phaseId == ["L", "P"])
                alloc = matlabcopilot.MBSEWorkflow.allocationFile(root, state, phaseId);
                if ~isfile(alloc)
                    verification.ok = false; verification.message = '层间 Allocation Set 不存在。';
                else
                    if phaseId == "L"
                        mappings = matlabcopilot.MBSEWorkflow.layerMappings(source.elements, 'functions');
                    else
                        mappings = matlabcopilot.MBSEWorkflow.layerMappings(source.components, 'logicalElements');
                    end
                    allocationCheck = matlabcopilot.MBSEWorkflow.verifyAllocation(alloc, mappings);
                    verification.ok = allocationCheck.ok;
                    verification.message = char(matlabcopilot.MBSEWorkflow.choose( ...
                        allocationCheck.ok, label + "及层间分配验证通过", allocationCheck.message));
                    verification.allocation = char(matlabcopilot.MBSEWorkflow.relativePath(root, alloc));
                    verification.expectedAllocations = allocationCheck.expected;
                    verification.actualAllocations = allocationCheck.actual;
                end
                if logical(verification.ok) && phaseId == "P"
                    profileName = matlabcopilot.MBSEWorkflow.safeName( ...
                        matlabcopilot.MBSEWorkflow.field(source, 'profileName', state.systemName + "PhysicalProfile"));
                    profileFile = fullfile(root, 'mbse', 'generated', 'architecture', profileName + ".xml");
                    if ~isfile(profileFile)
                        verification.ok = false; verification.message = '物理架构 Profile 不存在。';
                    else
                        verification.profile = char(matlabcopilot.MBSEWorkflow.relativePath(root, profileFile));
                    end
                end
            end
        end

        function state = linkFunctionalRequirements(root, state, source, comps)
            reqFile = fullfile(root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
            if ~isfile(reqFile); return; end
            rs = slreq.load(reqFile);
            for i = 1:numel(source.functions)
                reqIds = matlabcopilot.MBSEWorkflow.stringList(source.functions(i), 'requirements');
                for k = 1:numel(reqIds)
                    req = rs.find('Id', char(reqIds(k)));
                    if isempty(req); continue; end
                    link = slreq.createLink(comps(char(source.functions(i).name)), req(1));
                    link.Type = 'Implement';
                    save(linkSet(link));
                end
            end
            slreq.saveAll();
        end

        function source = readFunctional(root, state)
            file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.functionalSource);
            if ~isfile(file); error('matlabcopilot:MBSEWorkflow:MissingFunctionalSource', '功能架构源不存在: %s', file); end
            source = jsondecode(fileread(file));
            if ~isfield(source, 'modelName') || ~isfield(source, 'functions') || ~isfield(source, 'connections')
                error('matlabcopilot:MBSEWorkflow:InvalidFunctionalSource', ...
                    'functional-architecture.json 必须包含 modelName/functions/connections。');
            end
            if isempty(source.functions); source.functions = struct('name', {}, 'description', {}, 'requirements', {}, 'inputs', {}, 'outputs', {}); end
            if isempty(source.connections); source.connections = struct('source', {}, 'destination', {}); end
        end

        function source = readLayer(root, sourcePath, itemField)
            file = matlabcopilot.MBSEWorkflow.absolutePath(root, sourcePath);
            if ~isfile(file); error('matlabcopilot:MBSEWorkflow:MissingLayerSource', '架构源不存在: %s', file); end
            source = jsondecode(fileread(file));
            if ~isfield(source, 'modelName') || ~isfield(source, itemField) || ~isfield(source, 'connections')
                error('matlabcopilot:MBSEWorkflow:InvalidLayerSource', ...
                    '架构源必须包含 modelName/%s/connections。', itemField);
            end
            if isempty(source.(itemField))
                source.(itemField) = struct('name', {}, 'description', {}, 'requirements', {}, ...
                    'inputs', {}, 'outputs', {});
            end
            if isempty(source.connections); source.connections = struct('source', {}, 'destination', {}); end
        end

        function plan = readVerification(root, state)
            file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.verificationSource);
            if ~isfile(file); error('matlabcopilot:MBSEWorkflow:MissingVerificationPlan', '验证计划不存在: %s', file); end
            plan = jsondecode(fileread(file));
            if ~isfield(plan, 'verificationItems')
                error('matlabcopilot:MBSEWorkflow:InvalidVerificationPlan', '验证计划必须包含 verificationItems。');
            end
            if isempty(plan.verificationItems)
                plan.verificationItems = struct('id', {}, 'requirementId', {}, 'method', {}, ...
                    'artifact', {}, 'reviewed', {});
            end
        end

        function details = validateLayer(source, itemField, mappingField, upstream, requireCoverage, label)
            items = source.(itemField);
            if isempty(items); error('matlabcopilot:MBSEWorkflow:EmptyLayer', '%s提案至少需要一个元素。', label); end
            names = string({items.name});
            if any(strlength(strtrim(names)) == 0) || numel(unique(lower(names))) ~= numel(names)
                error('matlabcopilot:MBSEWorkflow:DuplicateElement', '%s名称必须非空且唯一。', label);
            end
            covered = strings(0, 1);
            inputs = containers.Map('KeyType', 'char', 'ValueType', 'any');
            outputs = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for i = 1:numel(items)
                refs = matlabcopilot.MBSEWorkflow.stringList(items(i), mappingField);
                unknown = setdiff(refs, upstream);
                if ~isempty(unknown)
                    error('matlabcopilot:MBSEWorkflow:UnknownAllocationSource', ...
                        '%s %s 引用了未知上游元素: %s', label, items(i).name, strjoin(unknown, ', '));
                end
                covered = [covered; refs(:)]; %#ok<AGROW>
                inputs(char(items(i).name)) = matlabcopilot.MBSEWorkflow.stringList(items(i), 'inputs');
                outputs(char(items(i).name)) = matlabcopilot.MBSEWorkflow.stringList(items(i), 'outputs');
            end
            if requireCoverage
                missing = setdiff(upstream, unique(covered));
                if ~isempty(missing)
                    error('matlabcopilot:MBSEWorkflow:UnallocatedUpstream', ...
                        '以下上游元素尚未分配到%s: %s', label, strjoin(missing, ', '));
                end
            end
            for i = 1:numel(source.connections)
                [sc, sp] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).source);
                [dc, dp] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).destination);
                if ~isKey(outputs, sc) || ~any(string(outputs(sc)) == string(sp)) || ...
                        ~isKey(inputs, dc) || ~any(string(inputs(dc)) == string(dp))
                    error('matlabcopilot:MBSEWorkflow:InvalidConnection', ...
                        '连接必须从已声明输出指向已声明输入: %s -> %s', ...
                        source.connections(i).source, source.connections(i).destination);
                end
            end
            details = struct('summary', numel(items) + " 个" + label + "、" + ...
                numel(source.connections) + " 条连接、" + numel(unique(covered)) + " 项上游分配已校验");
        end

        function validateOptionalRequirements(items, known)
            for i = 1:numel(items)
                refs = matlabcopilot.MBSEWorkflow.stringList(items(i), 'requirements');
                unknown = setdiff(refs, known);
                if ~isempty(unknown)
                    error('matlabcopilot:MBSEWorkflow:UnknownRequirement', ...
                        '元素 %s 引用了未知需求: %s', items(i).name, strjoin(unknown, ', '));
                end
            end
        end

        function [state, built] = buildArchitectureLayer(root, state, source, itemField, withProfile)
            caps = matlabcopilot.MBSEWorkflow.capabilities();
            if ~caps.systemComposer
                error('matlabcopilot:MBSEWorkflow:NoSystemComposer', '未检测到 System Composer 许可证。');
            end
            generated = fullfile(root, 'mbse', 'generated', 'architecture');
            if ~isfolder(generated); mkdir(generated); end
            addpath(generated);
            modelName = matlabcopilot.MBSEWorkflow.safeName(source.modelName);
            modelFile = fullfile(generated, modelName + ".slx");
            dictFile = fullfile(generated, modelName + "Interfaces.sldd");
            linkFile = fullfile(generated, modelName + "~mdl.slmx");
            artifacts = [modelFile, dictFile, linkFile];
            profileName = ""; profileFile = "";
            if withProfile
                profileName = matlabcopilot.MBSEWorkflow.safeName( ...
                    matlabcopilot.MBSEWorkflow.field(source, 'profileName', state.systemName + "PhysicalProfile"));
                profileFile = fullfile(generated, profileName + ".xml");
                artifacts(end+1) = profileFile;
            end
            for file = artifacts; matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, file); end
            slreq.clear(); systemcomposer.allocation.AllocationSet.closeAll();
            if bdIsLoaded(modelName); close_system(modelName, 0); end
            for file = artifacts; if isfile(file); delete(file); end; end
            Simulink.data.dictionary.closeAll('-discard');
            systemcomposer.profile.Profile.closeAll();
            old = pwd; cleanup = onCleanup(@() cd(old)); %#ok<NASGU>
            cd(generated);
            dict = systemcomposer.createDictionary(char(dictFile));
            flows = matlabcopilot.MBSEWorkflow.flowNamesForItems(source.(itemField));
            for i = 1:numel(flows)
                iface = addInterface(dict, matlabcopilot.MBSEWorkflow.interfaceName(flows(i)));
                addElement(iface, 'Value', 'Type', 'double');
            end
            dict.save();
            if withProfile
                profile = systemcomposer.profile.Profile.createProfile(char(profileName));
                stereotype = addStereotype(profile, 'ComponentProperties', 'AppliesTo', 'Component');
                addProperty(stereotype, 'Mass_kg', 'Type', 'double', 'Units', 'kg', 'DefaultValue', '0');
                addProperty(stereotype, 'Power_W', 'Type', 'double', 'Units', 'W', 'DefaultValue', '0');
                addProperty(stereotype, 'Cost', 'Type', 'double', 'DefaultValue', '0');
                profile.save(char(generated));
            end
            model = systemcomposer.createModel(char(modelName)); arch = model.Architecture;
            linkDictionary(model, char(dictFile));
            if withProfile; applyProfile(model, char(profileName)); end
            specs = source.(itemField);
            comps = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for i = 1:numel(specs)
                spec = specs(i);
                comp = addComponent(arch, char(spec.name), 'Position', [80 + 210*(i-1), 100, 190 + 210*(i-1), 180]);
                comps(char(spec.name)) = comp;
                in = matlabcopilot.MBSEWorkflow.stringList(spec, 'inputs');
                out = matlabcopilot.MBSEWorkflow.stringList(spec, 'outputs');
                for k = 1:numel(in)
                    port = addPort(comp.Architecture, char(in(k)), 'in');
                    port.setInterface(dict.getInterface(matlabcopilot.MBSEWorkflow.interfaceName(in(k))));
                end
                for k = 1:numel(out)
                    port = addPort(comp.Architecture, char(out(k)), 'out');
                    port.setInterface(dict.getInterface(matlabcopilot.MBSEWorkflow.interfaceName(out(k))));
                end
                if withProfile
                    applyStereotype(comp, char(profileName + ".ComponentProperties"));
                    props = matlabcopilot.MBSEWorkflow.field(spec, 'properties', struct());
                    setProperty(comp, char(profileName + ".ComponentProperties.Mass_kg"), ...
                        char(string(matlabcopilot.MBSEWorkflow.field(props, 'massKg', 0))));
                    setProperty(comp, char(profileName + ".ComponentProperties.Power_W"), ...
                        char(string(matlabcopilot.MBSEWorkflow.field(props, 'powerW', 0))));
                    setProperty(comp, char(profileName + ".ComponentProperties.Cost"), ...
                        char(string(matlabcopilot.MBSEWorkflow.field(props, 'cost', 0))));
                end
            end
            for i = 1:numel(source.connections)
                [sc, sp] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).source);
                [dc, dp] = matlabcopilot.MBSEWorkflow.endpoint(source.connections(i).destination);
                connect(comps(sc).getPort(sp), comps(dc).getPort(dp));
            end
            save_system(char(modelName), char(modelFile));
            state = matlabcopilot.MBSEWorkflow.linkComponentRequirements(root, state, specs, comps);
            save_system(char(modelName)); close_system(char(modelName), 0);
            for file = artifacts
                if isfile(file); state = matlabcopilot.MBSEWorkflow.own(root, state, file); end
            end
            state = matlabcopilot.MBSEWorkflow.registerProjectArtifacts(root, state, artifacts(isfile(artifacts)));
            built = struct('modelName', char(modelName), 'modelFile', char(modelFile), ...
                'dictFile', char(dictFile), 'profileFile', char(profileFile));
        end

        function state = buildAllocation(root, state, sourceModelName, targetModelName, allocName, mappings)
            generated = fullfile(root, 'mbse', 'generated', 'architecture'); addpath(generated);
            file = fullfile(generated, allocName + ".mldatx");
            matlabcopilot.MBSEWorkflow.assertOwnedOrNew(root, state, file);
            systemcomposer.allocation.AllocationSet.closeAll();
            if isfile(file); delete(file); end
            old = pwd;
            cleanup = onCleanup(@() cd(old)); %#ok<NASGU>
            cd(generated);
            src = systemcomposer.loadModel(char(sourceModelName));
            dst = systemcomposer.loadModel(char(targetModelName));
            set = systemcomposer.allocation.createAllocationSet(char(allocName), char(sourceModelName), char(targetModelName));
            scenario = set.Scenarios(1); scenario.Name = 'MainAllocation';
            for i = 1:numel(mappings)
                srcComp = src.Architecture.getComponent(mappings(i).source);
                dstComp = dst.Architecture.getComponent(mappings(i).target);
                if isempty(srcComp) || isempty(dstComp)
                    error('matlabcopilot:MBSEWorkflow:AllocationElementMissing', ...
                        '分配元素不存在: %s -> %s', mappings(i).source, mappings(i).target);
                end
                allocate(scenario, srcComp, dstComp);
            end
            save(set);
            close(set);
            if ~isfile(file)
                error('matlabcopilot:MBSEWorkflow:ArtifactMissing', ...
                    '层间 Allocation Set 未成功落盘: %s', file);
            end
            state = matlabcopilot.MBSEWorkflow.own(root, state, file);
            state = matlabcopilot.MBSEWorkflow.registerProjectArtifacts(root, state, file);
        end

        function state = linkComponentRequirements(root, state, specs, comps)
            reqFile = fullfile(root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
            if ~isfile(reqFile); return; end
            rs = slreq.load(reqFile);
            for i = 1:numel(specs)
                ids = matlabcopilot.MBSEWorkflow.stringList(specs(i), 'requirements');
                for k = 1:numel(ids)
                    req = rs.find('Id', char(ids(k))); if isempty(req); continue; end
                    link = slreq.createLink(comps(char(specs(i).name)), req(1)); link.Type = 'Implement';
                    save(linkSet(link));
                end
            end
            slreq.saveAll();
        end

        function verification = verifyArchitecture(root, source, itemField, label)
            modelName = matlabcopilot.MBSEWorkflow.safeName(source.modelName);
            file = fullfile(root, 'mbse', 'generated', 'architecture', modelName + ".slx");
            dict = fullfile(root, 'mbse', 'generated', 'architecture', modelName + "Interfaces.sldd");
            if ~isfile(file) || ~isfile(dict)
                verification = struct('ok', false, 'message', char(label + "模型或接口字典不存在。")); return;
            end
            addpath(fileparts(file)); wasLoaded = bdIsLoaded(modelName);
            if ~wasLoaded; load_system(file); end
            cleanup = onCleanup(@() matlabcopilot.MBSEWorkflow.closeIfNeeded(modelName, wasLoaded)); %#ok<NASGU>
            model = systemcomposer.loadModel(char(modelName));
            actual = numel(model.Architecture.Components); unconnected = model.Architecture.getUnconnectedPorts();
            expected = numel(source.(itemField)); ok = actual == expected && isempty(unconnected);
            msg = label + "验证通过";
            if actual ~= expected; msg = label + "组件数与工程源不一致";
            elseif ~isempty(unconnected); msg = label + "仍有 " + numel(unconnected) + " 个未连接端口"; end
            verification = struct('ok', ok, 'message', char(msg), 'sourceComponents', expected, ...
                'artifactComponents', actual, 'unconnectedPorts', numel(unconnected), ...
                'artifact', char(matlabcopilot.MBSEWorkflow.relativePath(root, file)));
        end

        function file = allocationFile(root, state, phaseId)
            if phaseId == "L"; name = state.systemName + "FunctionalToLogical";
            else; name = state.systemName + "LogicalToPhysical"; end
            file = fullfile(root, 'mbse', 'generated', 'architecture', ...
                matlabcopilot.MBSEWorkflow.safeName(name) + ".mldatx");
        end

        function result = verifyAllocation(file, mappings)
            result = struct('ok', false, 'message', '无法验证层间分配。', ...
                'expected', numel(mappings), 'actual', 0);
            try
                systemcomposer.allocation.AllocationSet.closeAll();
                addpath(fileparts(file));
                [~, name] = fileparts(file);
                set = systemcomposer.allocation.load(name);
                cleanup = onCleanup(@() systemcomposer.allocation.AllocationSet.closeAll()); %#ok<NASGU>
                if isempty(set.Scenarios)
                    result.message = '层间 Allocation Set 不包含分配场景。'; return;
                end
                allocations = set.Scenarios(1).Allocations;
                result.actual = numel(allocations);
                expected = strings(numel(mappings), 1);
                for i = 1:numel(mappings)
                    expected(i) = string(mappings(i).source) + "->" + string(mappings(i).target);
                end
                actual = strings(numel(allocations), 1);
                for i = 1:numel(allocations)
                    actual(i) = string(allocations(i).Source.Name) + "->" + string(allocations(i).Target.Name);
                end
                result.ok = isequal(sort(expected), sort(actual));
                if result.ok
                    result.message = '层间分配完整性验证通过。';
                else
                    result.message = '层间分配与架构源映射不一致。';
                end
            catch err
                result.message = char("无法加载层间 Allocation Set: " + string(err.message));
            end
        end

        function reqs = readRequirements(file)
            reqs = struct('id', {}, 'title', {}, 'text', {});
            if ~isfile(file); error('matlabcopilot:MBSEWorkflow:MissingRequirements', '需求源不存在: %s', file); end
            [~, ~, ext] = fileparts(file);
            if strcmpi(ext, '.json')
                raw = jsondecode(fileread(file));
                if isstruct(raw); raw = num2cell(raw); end
                for i = 1:numel(raw)
                    r = raw{i};
                    reqs(end+1) = struct('id', strtrim(string(matlabcopilot.MBSEWorkflow.firstField(r, {'id','ID','reqId'}))), ... %#ok<AGROW>
                        'title', string(matlabcopilot.MBSEWorkflow.firstField(r, {'title','name','Summary'})), ...
                        'text', string(matlabcopilot.MBSEWorkflow.firstField(r, {'text','description','Description'})));
                end
            else
                table = readtable(file, 'Delimiter', ',', 'TextType', 'string', ...
                    'VariableNamingRule', 'preserve');
                if width(table) < 1; return; end
                for i = 1:height(table)
                    id = strtrim(string(table{i, 1})); if strlength(id) == 0; continue; end
                    title = ""; text = "";
                    if width(table) >= 2; title = string(table{i, 2}); end
                    if width(table) >= 3; text = string(table{i, 3}); end
                    reqs(end+1) = struct('id', id, 'title', title, 'text', text); %#ok<AGROW>
                end
            end
            if ~isempty(reqs); reqs = reqs(strlength(string({reqs.id})) > 0); end
        end

        function results = runVerificationItems(root, state, items)
            blank = struct('id', '', 'requirementId', '', 'method', '', 'status', 'failed', ...
                'summary', '', 'artifact', '', 'metrics', struct());
            results = repmat(blank, 1, numel(items));
            for i = 1:numel(items)
                item = items(i); method = lower(string(item.method));
                result = blank; result.id = char(string(item.id));
                result.requirementId = char(string(item.requirementId)); result.method = char(method);
                artifact = string(matlabcopilot.MBSEWorkflow.field(item, 'artifact', ""));
                if strlength(artifact) > 0; artifact = matlabcopilot.MBSEWorkflow.absolutePath(root, artifact); end
                result.artifact = char(artifact);
                try
                    switch method
                        case "architecture_trace"
                            [ok, summary, metrics] = matlabcopilot.MBSEWorkflow.traceRequirement( ...
                                root, state, string(item.requirementId));
                        case "matlab_test"
                            if ~isfile(artifact); error('验证测试文件不存在: %s', artifact); end
                            testResults = runtests(char(artifact));
                            ok = ~isempty(testResults) && all([testResults.Passed]);
                            summary = sum([testResults.Passed]) + "/" + numel(testResults) + " 个 MATLAB 测试通过";
                            metrics = struct('passed', sum([testResults.Passed]), ...
                                'failed', sum([testResults.Failed]), 'total', numel(testResults));
                        case "test_manager"
                            caps = matlabcopilot.TestBridge.caps();
                            if ~caps.sltest; error('未检测到 Simulink Test。'); end
                            if ~isfile(artifact); error('Test Manager 文件不存在: %s', artifact); end
                            event = matlabcopilot.TestBridge.runTestFiles(artifact, 'mbse-verification');
                            ok = event.failed == 0 && event.passed > 0;
                            summary = event.passed + " 个通过，" + event.failed + " 个失败";
                            metrics = struct('passed', event.passed, 'failed', event.failed);
                        case "artifact_review"
                            reviewed = logical(matlabcopilot.MBSEWorkflow.field(item, 'reviewed', false));
                            ok = isfile(artifact) && reviewed;
                            summary = matlabcopilot.MBSEWorkflow.choose(ok, ...
                                "人工评审证据存在且已批准", "人工评审证据缺失或尚未批准");
                            metrics = struct('exists', isfile(artifact), 'reviewed', reviewed);
                    end
                    result.status = char(matlabcopilot.MBSEWorkflow.choose(ok, "passed", "failed"));
                    result.summary = char(summary); result.metrics = metrics;
                catch err
                    result.status = 'failed'; result.summary = char(string(err.message));
                end
                results(i) = result;
            end
        end

        function [ok, summary, metrics] = traceRequirement(root, state, requirementId)
            functional = matlabcopilot.MBSEWorkflow.readFunctional(root, state);
            logical = matlabcopilot.MBSEWorkflow.readLayer(root, state.logicalSource, 'elements');
            physical = matlabcopilot.MBSEWorkflow.readLayer(root, state.physicalSource, 'components');
            functions = strings(0, 1);
            for i = 1:numel(functional.functions)
                if any(matlabcopilot.MBSEWorkflow.stringList(functional.functions(i), 'requirements') == requirementId)
                    functions(end+1, 1) = string(functional.functions(i).name); %#ok<AGROW>
                end
            end
            logicalElements = strings(0, 1);
            for i = 1:numel(logical.elements)
                if any(ismember(matlabcopilot.MBSEWorkflow.stringList(logical.elements(i), 'functions'), functions))
                    logicalElements(end+1, 1) = string(logical.elements(i).name); %#ok<AGROW>
                end
            end
            physicalComponents = strings(0, 1);
            for i = 1:numel(physical.components)
                if any(ismember(matlabcopilot.MBSEWorkflow.stringList(physical.components(i), 'logicalElements'), logicalElements))
                    physicalComponents(end+1, 1) = string(physical.components(i).name); %#ok<AGROW>
                end
            end
            allocF = matlabcopilot.MBSEWorkflow.allocationFile(root, state, "L");
            allocP = matlabcopilot.MBSEWorkflow.allocationFile(root, state, "P");
            checkF = matlabcopilot.MBSEWorkflow.verifyAllocation(allocF, ...
                matlabcopilot.MBSEWorkflow.layerMappings(logical.elements, 'functions'));
            checkP = matlabcopilot.MBSEWorkflow.verifyAllocation(allocP, ...
                matlabcopilot.MBSEWorkflow.layerMappings(physical.components, 'logicalElements'));
            ok = ~isempty(functions) && ~isempty(logicalElements) && ~isempty(physicalComponents) && ...
                checkF.ok && checkP.ok;
            summary = matlabcopilot.MBSEWorkflow.choose(ok, ...
                "需求已形成 R→F→L→P 完整追溯链", "需求的 R→F→L→P 追溯链不完整");
            metrics = struct('functions', numel(functions), 'logicalElements', numel(logicalElements), ...
                'physicalComponents', numel(physicalComponents), ...
                'functionalToLogicalAllocation', checkF.ok, ...
                'logicalToPhysicalAllocation', checkP.ok);
        end

        function mappings = layerMappings(items, mappingField)
            mappings = struct('source', {}, 'target', {});
            for i = 1:numel(items)
                refs = matlabcopilot.MBSEWorkflow.stringList(items(i), mappingField);
                for k = 1:numel(refs)
                    mappings(end+1) = struct('source', char(refs(k)), ... %#ok<AGROW>
                        'target', char(string(items(i).name)));
                end
            end
        end

        function text = verificationMarkdown(report)
            lines = ["# MBSE 验证报告"; ""; ...
                "- 系统: " + string(report.systemName); ...
                "- 生成时间: " + string(report.generatedAt); ...
                "- 结果: " + matlabcopilot.MBSEWorkflow.choose(report.overallOk, "通过", "失败"); ...
                "- 通过/失败: " + report.passed + "/" + report.failed; ""; ...
                "| 验证项 | 需求 | 方法 | 状态 | 说明 |"; ...
                "|---|---|---|---|---|"];
            for i = 1:numel(report.results)
                item = report.results(i);
                lines(end+1, 1) = "| " + string(item.id) + " | " + string(item.requirementId) + ... %#ok<AGROW>
                    " | " + string(item.method) + " | " + string(item.status) + " | " + ...
                    replace(string(item.summary), "|", "\|") + " |";
            end
            text = strjoin(lines, newline) + newline;
        end

        function writeBuildScript(root, phaseId)
            file = matlabcopilot.MBSEWorkflow.scriptFile(root, phaseId);
            if ~isfolder(fileparts(file)); mkdir(fileparts(file)); end
            methods = struct('R', 'executeRequirements', 'F', 'executeFunctional', ...
                'L', 'executeLogical', 'P', 'executePhysical', 'V', 'executeVerification');
            functionNames = struct('R', 'buildRequirements', 'F', 'buildFunctional', ...
                'L', 'buildLogical', 'P', 'buildPhysical', 'V', 'runVerification');
            method = string(methods.(char(phaseId)));
            functionName = string(functionNames.(char(phaseId)));
            lines = ["function " + functionName + "()"; ...
                "% 由 MATLAB Copilot MBSE 工作流生成；工程 JSON/CSV 是设计源。"; ...
                "root = fileparts(fileparts(fileparts(mfilename('fullpath'))));"; ...
                "state = matlabcopilot.MBSEWorkflow.status(root);"; ...
                "state = matlabcopilot.MBSEWorkflow." + method + "(root, state);"; ...
                "matlabcopilot.MBSEWorkflow.saveState(root, state);"; ...
                "end"; ""];
            matlabcopilot.MBSEWorkflow.writeTextAtomic(file, strjoin(lines, newline));
        end

        function state = registerProjectArtifacts(root, state, files)
            try
                proj = matlab.project.rootProject;
                if isempty(proj) || ~strcmpi(char(proj.RootFolder), char(root)); return; end
                generated = fullfile(root, 'mbse', 'generated');
                try, addPath(proj, generated); catch, end
                for file = string(files(:))'
                    try, addFile(proj, char(file)); catch, end
                end
            catch
            end
        end

        function state = own(root, state, file)
            rel = char(matlabcopilot.MBSEWorkflow.relativePath(root, file));
            owned = string(state.ownedArtifacts);
            if ~any(owned == string(rel)); owned(end+1, 1) = string(rel); end
            state.ownedArtifacts = cellstr(owned);
        end

        function assertOwnedOrNew(root, state, file)
            if ~isfile(file); return; end
            rel = matlabcopilot.MBSEWorkflow.relativePath(root, file);
            if ~any(string(state.ownedArtifacts) == rel)
                error('matlabcopilot:MBSEWorkflow:UnownedArtifact', ...
                    '拒绝覆盖未登记为工作流生成物的文件: %s', file);
            end
        end

        function state = defaultState(root)
            blank = struct('id', '', 'name', '', 'status', 'planned', 'summary', '', ...
                'proposedAt', '', 'approvedAt', '', 'generatedAt', '', 'executedAt', '', ...
                'confirmedAt', '', 'script', '', 'sourceHash', '', 'verification', struct());
            phases = repmat(blank, 1, 5);
            ids = {'R','F','L','P','V'};
            names = {'需求','功能架构','逻辑架构','物理架构','验证'};
            for i = 1:5; phases(i).id = ids{i}; phases(i).name = names{i}; end
            phases(1).status = 'draft';
            state = struct('schemaVersion', 2, 'initialized', false, 'projectRoot', char(root), ...
                'systemName', 'UntitledSystem', 'description', '', 'currentPhase', 'R', ...
                'requirementsSource', '', 'functionalSource', '', 'logicalSource', '', ...
                'physicalSource', '', 'verificationSource', '', 'phases', phases, ...
                'ownedArtifacts', {{}}, 'createdAt', matlabcopilot.MBSEWorkflow.nowText(), ...
                'updatedAt', matlabcopilot.MBSEWorkflow.nowText(), ...
                'capabilities', matlabcopilot.MBSEWorkflow.capabilities());
        end

        function state = normalizeState(state, root)
            base = matlabcopilot.MBSEWorkflow.defaultState(root);
            fields = fieldnames(base);
            for i = 1:numel(fields)
                if ~isfield(state, fields{i}); state.(fields{i}) = base.(fields{i}); end
            end
            state.projectRoot = char(root);
            if isempty(state.phases) || numel(state.phases) ~= 5; state.phases = base.phases; end
            for i = 1:min(numel(state.phases), numel(base.phases))
                names = fieldnames(base.phases(i));
                for k = 1:numel(names)
                    if ~isfield(state.phases(i), names{k})
                        state.phases(i).(names{k}) = base.phases(i).(names{k});
                    end
                end
            end
            if ischar(state.ownedArtifacts) || isstring(state.ownedArtifacts)
                state.ownedArtifacts = cellstr(string(state.ownedArtifacts));
            end
        end

        function caps = capabilities()
            req = false; sc = false; project = false;
            try, req = license('test', 'Simulink_Requirements') == 1; catch, end
            try, sc = license('test', 'System_Composer') == 1; catch, end
            try, project = ~isempty(which('matlab.project.rootProject')); catch, end
            caps = struct('requirementsToolbox', logical(req), 'systemComposer', logical(sc), ...
                'matlabProject', logical(project));
        end

        function result = result(state, ok, message, entry)
            result = struct('state', state, 'ok', logical(ok), 'message', char(message), 'entry', entry);
        end

        function entry = entry(kind, state, summary, phaseId)
            if nargin < 4; phaseId = ""; end
            entry = struct('id', char("mbse-" + string(matlab.lang.internal.uuid())), ...
                'time', matlabcopilot.MBSEWorkflow.nowText(), 'source', 'mbse-workflow', ...
                'kind', char(kind), 'status', 'ok', 'summary', char(summary), ...
                'relativePath', 'mbse/mbse-workflow.json', 'model', '', ...
                'requirements', {{}}, 'metrics', struct('phase', char(phaseId), ...
                'systemName', char(state.systemName)));
        end

        function dirs = directories(root)
            dirs = struct('base', fullfile(root, 'mbse'), ...
                'requirements', fullfile(root, 'mbse', 'requirements'), ...
                'architecture', fullfile(root, 'mbse', 'architecture'), ...
                'scripts', fullfile(root, 'mbse', 'scripts'), ...
                'generated', fullfile(root, 'mbse', 'generated'));
        end

        function file = workflowFile(root); file = fullfile(root, 'mbse', 'mbse-workflow.json'); end
        function file = scriptFile(root, phaseId)
            names = struct('R', 'buildRequirements.m', 'F', 'buildFunctional.m', ...
                'L', 'buildLogical.m', 'P', 'buildPhysical.m', 'V', 'runVerification.m');
            name = names.(char(phaseId));
            file = fullfile(root, 'mbse', 'scripts', name);
        end

        function writeState(root, state)
            state.capabilities = matlabcopilot.MBSEWorkflow.capabilities();
            matlabcopilot.MBSEWorkflow.writeJsonAtomic(matlabcopilot.MBSEWorkflow.workflowFile(root), state);
        end

        function writeJsonAtomic(file, value)
            matlabcopilot.MBSEWorkflow.writeTextAtomic(file, string(jsonencode(value, 'PrettyPrint', true)) + newline);
        end

        function writeTextAtomic(file, value)
            if ~isfolder(fileparts(file)); mkdir(fileparts(file)); end
            tmp = string([tempname(fileparts(file)) '.tmp']);
            fid = fopen(tmp, 'w', 'n', 'UTF-8');
            if fid < 0; error('matlabcopilot:MBSEWorkflow:WriteFailed', '无法写入临时文件: %s', tmp); end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fprintf(fid, '%s', char(value)); clear cleanup
            [ok, msg] = movefile(tmp, file, 'f');
            if ~ok; error('matlabcopilot:MBSEWorkflow:WriteFailed', '%s', msg); end
        end

        function root = requireRoot(value)
            root = string(value);
            if strlength(strtrim(root)) == 0 || ~isfolder(root)
                error('matlabcopilot:MBSEWorkflow:InvalidRoot', '未找到有效的工程根目录。');
            end
            root = string(char(java.io.File(char(root)).getCanonicalPath()));
        end

        function path = absolutePath(root, value)
            value = string(value);
            if isfile(value) || isfolder(value); path = value; return; end
            if ~isempty(regexp(char(value), '^[A-Za-z]:[\\/]|^\\\\', 'once')); path = value; return; end
            path = string(fullfile(root, value));
        end

        function rel = relativePath(root, file)
            r = replace(string(root), '\', '/'); f = replace(string(file), '\', '/');
            if startsWith(lower(f), lower(r + "/")); rel = extractAfter(f, strlength(r) + 1); else; rel = f; end
        end

        function value = field(s, name, fallback)
            value = fallback; if isstruct(s) && isfield(s, name) && ~isempty(s.(name)); value = s.(name); end
        end

        function value = firstField(s, names)
            value = "";
            for i = 1:numel(names); if isfield(s, names{i}); value = s.(names{i}); return; end; end
        end

        function name = safeName(value)
            name = string(matlab.lang.makeValidName(char(string(value))));
            if strlength(name) == 0; name = "UntitledSystem"; end
        end

        function list = stringList(s, field)
            list = strings(0, 1);
            if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
                list = string(s.(field)); list = strtrim(list(:)); list = list(strlength(list) > 0);
            end
        end

        function names = flowNames(source)
            names = strings(0, 1);
            for i = 1:numel(source.functions)
                names = [names; matlabcopilot.MBSEWorkflow.stringList(source.functions(i), 'inputs'); ... %#ok<AGROW>
                    matlabcopilot.MBSEWorkflow.stringList(source.functions(i), 'outputs')];
            end
            names = unique(names, 'stable');
        end

        function names = flowNamesForItems(items)
            names = strings(0, 1);
            for i = 1:numel(items)
                names = [names; matlabcopilot.MBSEWorkflow.stringList(items(i), 'inputs'); ... %#ok<AGROW>
                    matlabcopilot.MBSEWorkflow.stringList(items(i), 'outputs')];
            end
            names = unique(names, 'stable');
        end

        function name = interfaceName(flow)
            name = char(matlab.lang.makeValidName(char(string(flow) + "Interface")));
        end

        function [component, port] = endpoint(value)
            parts = split(string(value), '/');
            if numel(parts) ~= 2 || any(strlength(strtrim(parts)) == 0)
                error('matlabcopilot:MBSEWorkflow:InvalidEndpoint', '端点必须使用 Component/Port: %s', value);
            end
            component = char(parts(1)); port = char(parts(2));
        end

        function idx = phaseIndex(state, phaseId)
            idx = find(string({state.phases.id}) == string(phaseId), 1);
            if isempty(idx); error('matlabcopilot:MBSEWorkflow:InvalidPhase', '未知阶段: %s', phaseId); end
        end

        function requirePreviousConfirmed(root, state, idx)
            if idx <= 1; return; end
            for i = 1:idx-1
                if string(state.phases(i).status) ~= "confirmed"
                    error('matlabcopilot:MBSEWorkflow:PreviousPhase', '上游阶段尚未确认，不能提交本阶段提案。');
                end
                matlabcopilot.MBSEWorkflow.requireSourceUnchanged(root, state, i);
            end
        end

        function requireSourceUnchanged(root, state, idx)
            expected = string(state.phases(idx).sourceHash);
            if isempty(expected) || ~isscalar(expected) || strlength(expected) == 0
                error('matlabcopilot:MBSEWorkflow:SourceBaselineMissing', ...
                    '阶段尚未绑定设计源版本，请重新提案。');
            end
            actual = matlabcopilot.MBSEWorkflow.phaseSourceHash(root, state, string(state.phases(idx).id));
            if actual ~= expected
                error('matlabcopilot:MBSEWorkflow:SourceChanged', ...
                    '阶段设计源在提案后已变更，请重新提案并批准。');
            end
        end

        function state = invalidateFrom(state, idx)
            for i = idx:numel(state.phases)
                state.phases(i).status = 'planned';
                state.phases(i).summary = '';
                state.phases(i).proposedAt = '';
                state.phases(i).approvedAt = '';
                state.phases(i).generatedAt = '';
                state.phases(i).executedAt = '';
                state.phases(i).confirmedAt = '';
                state.phases(i).script = '';
                state.phases(i).sourceHash = '';
                state.phases(i).verification = struct();
            end
            state.currentPhase = char(string(state.phases(idx).id));
        end

        function hash = phaseSourceHash(root, state, phaseId)
            switch string(phaseId)
                case "R"; file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.requirementsSource);
                case "F"; file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.functionalSource);
                case "L"; file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.logicalSource);
                case "P"; file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.physicalSource);
                case "V"; file = matlabcopilot.MBSEWorkflow.absolutePath(root, state.verificationSource);
            end
            if ~isfile(file)
                error('matlabcopilot:MBSEWorkflow:SourceMissing', '阶段设计源不存在: %s', file);
            end
            fid = fopen(file, 'rb');
            if fid < 0; error('matlabcopilot:MBSEWorkflow:SourceReadFailed', '无法读取阶段设计源: %s', file); end
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            bytes = fread(fid, Inf, '*uint8');
            digest = java.security.MessageDigest.getInstance('SHA-256');
            digest.update(bytes);
            raw = typecast(digest.digest(), 'uint8');
            hash = lower(string(reshape(dec2hex(raw, 2).', 1, [])));
        end

        function requireStatus(state, idx, expected, action)
            if string(state.phases(idx).status) ~= expected
                error('matlabcopilot:MBSEWorkflow:InvalidTransition', ...
                    '%s前阶段状态必须为 %s，当前为 %s。', action, expected, state.phases(idx).status);
            end
        end

        function requireAnyStatus(state, idx, expected, action)
            if ~any(string(state.phases(idx).status) == expected)
                error('matlabcopilot:MBSEWorkflow:InvalidTransition', ...
                    '%s前阶段状态必须为 %s，当前为 %s。', action, strjoin(expected, '/'), state.phases(idx).status);
            end
        end

        function closeIfNeeded(modelName, wasLoaded)
            if ~wasLoaded && bdIsLoaded(modelName); close_system(modelName, 0); end
        end

        function value = choose(condition, yes, no)
            if condition; value = yes; else; value = no; end
        end

        function text = nowText()
            text = char(string(datetime('now', 'TimeZone', 'UTC', 'Format', "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")));
        end
    end
end
