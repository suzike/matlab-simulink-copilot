classdef MBSEWorkflowTest < matlab.unittest.TestCase
    properties
        Root string
    end

    methods (TestMethodSetup)
        function createFixture(testCase)
            testCase.Root = string(tempname);
            mkdir(testCase.Root);
            testCase.addTeardown(@() testCase.cleanupFixture());
            testCase.writeSources();
        end
    end

    methods (Test)
        function initializesAndEnforcesApprovalOrder(testCase)
            result = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'initialize', 'R', ...
                struct('systemName', 'ThermalController', 'requirementsSource', 'requirements.csv'));
            testCase.verifyTrue(result.state.initialized);
            testCase.verifyEqual(string(result.state.currentPhase), "R");
            testCase.verifyTrue(isfile(fullfile(testCase.Root, 'mbse', 'mbse-workflow.json')));
            testCase.verifyError(@() matlabcopilot.MBSEWorkflow.apply( ...
                testCase.Root, 'approve', 'R', struct()), ...
                'matlabcopilot:MBSEWorkflow:InvalidTransition');

            proposed = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'propose', 'R', struct());
            testCase.verifyEqual(string(proposed.state.phases(1).status), "proposed");
            fid = fopen(fullfile(testCase.Root, 'requirements.csv'), 'a');
            fprintf(fid, 'REQ-003,Changed after proposal,Approval must bind source version\n');
            fclose(fid);
            testCase.verifyError(@() matlabcopilot.MBSEWorkflow.apply( ...
                testCase.Root, 'approve', 'R', struct()), ...
                'matlabcopilot:MBSEWorkflow:SourceChanged');
            proposed = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'propose', 'R', struct());
            testCase.verifyNotEmpty(proposed.state.phases(1).sourceHash);
            legacy = proposed.state;
            legacy.phases = rmfield(legacy.phases, 'sourceHash');
            testCase.writeJson(fullfile(testCase.Root, 'mbse', 'mbse-workflow.json'), legacy);
            testCase.verifyError(@() matlabcopilot.MBSEWorkflow.apply( ...
                testCase.Root, 'approve', 'R', struct()), ...
                'matlabcopilot:MBSEWorkflow:SourceBaselineMissing');
            proposed = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'propose', 'R', struct());
            approved = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'approve', 'R', struct());
            testCase.verifyEqual(string(approved.state.phases(1).status), "approved");
            generated = matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'generate', 'R', struct());
            testCase.verifyEqual(string(generated.state.phases(1).status), "generated");
            testCase.verifyTrue(isfile(fullfile(testCase.Root, 'mbse', 'scripts', 'buildRequirements.m')));
        end

        function buildsNativeRequirementsAndFunctionalArchitecture(testCase)
            testCase.assumeTrue(testCase.hasRequirementsToolbox());
            testCase.assumeTrue(testCase.hasSystemComposer());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'initialize', 'R', ...
                struct('systemName', 'ThermalController', 'requirementsSource', 'requirements.csv'));

            testCase.runPhase('R');
            state = matlabcopilot.MBSEWorkflow.status(testCase.Root);
            reqFile = fullfile(testCase.Root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
            testCase.verifyTrue(isfile(reqFile));
            testCase.verifyEqual(string(state.phases(1).status), "confirmed");

            testCase.runPhase('F');
            state = matlabcopilot.MBSEWorkflow.status(testCase.Root);
            modelFile = fullfile(testCase.Root, 'mbse', 'generated', 'architecture', 'ThermalControllerFunctional.slx');
            dictFile = fullfile(testCase.Root, 'mbse', 'generated', 'architecture', 'ThermalControllerFunctionalInterfaces.sldd');
            testCase.verifyTrue(isfile(modelFile));
            testCase.verifyTrue(isfile(dictFile));
            testCase.verifyEqual(string(state.phases(2).status), "confirmed");
            testCase.verifyEqual(state.phases(2).verification.artifactComponents, 2);
            testCase.verifyEqual(state.phases(2).verification.unconnectedPorts, 0);
            slreq.clear();
            load_system(modelFile);
            slreq.load(reqFile);
            links = slreq.find('Type', 'Link');
            testCase.verifyGreaterThanOrEqual(numel(links), 2);
            testCase.verifyTrue(all(string({links.Type}) == "Implement"));
            slreq.clear(); close_system('ThermalControllerFunctional', 0);

            testCase.runPhase('L');
            testCase.runPhase('P');
            testCase.runPhase('V');
            state = matlabcopilot.MBSEWorkflow.status(testCase.Root);
            testCase.verifyEqual(string({state.phases.status}), ...
                ["confirmed", "confirmed", "confirmed", "confirmed", "confirmed"]);
            archDir = fullfile(testCase.Root, 'mbse', 'generated', 'architecture');
            testCase.verifyTrue(isfile(fullfile(archDir, 'ThermalControllerLogical.slx')));
            testCase.verifyTrue(isfile(fullfile(archDir, 'ThermalControllerPhysical.slx')));
            testCase.verifyTrue(isfile(fullfile(archDir, 'ThermalControllerFunctionalToLogical.mldatx')));
            testCase.verifyTrue(isfile(fullfile(archDir, 'ThermalControllerLogicalToPhysical.mldatx')));
            testCase.verifyTrue(isfile(fullfile(archDir, 'ThermalControllerPhysicalProfile.xml')));
            reportFile = fullfile(testCase.Root, 'mbse', 'generated', 'verification', 'verification-report.json');
            testCase.verifyTrue(isfile(reportFile));
            report = jsondecode(fileread(reportFile));
            testCase.verifyTrue(report.overallOk);
            testCase.verifyEqual(report.passed, 2);
        end

        function refusesToOverwriteUnownedRequirementArtifact(testCase)
            testCase.assumeTrue(testCase.hasRequirementsToolbox());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'initialize', 'R', ...
                struct('systemName', 'ThermalController', 'requirementsSource', 'requirements.csv'));
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'propose', 'R', struct());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'approve', 'R', struct());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'generate', 'R', struct());
            out = fullfile(testCase.Root, 'mbse', 'generated', 'requirements', 'SystemRequirements.slreqx');
            mkdir(fileparts(out));
            fid = fopen(out, 'w'); fprintf(fid, 'unowned'); fclose(fid);
            testCase.verifyError(@() matlabcopilot.MBSEWorkflow.apply( ...
                testCase.Root, 'run', 'R', struct()), ...
                'matlabcopilot:MBSEWorkflow:UnownedArtifact');
        end
    end

    methods (Access=private)
        function tf = hasRequirementsToolbox(~)
            tf = license('test', 'Simulink_Requirements') == 1 && ...
                ~isempty(which('slreq.new')) && ~isempty(which('slreq.load'));
        end

        function tf = hasSystemComposer(~)
            tf = license('test', 'System_Composer') == 1 && ...
                ~isempty(which('systemcomposer.createModel')) && ...
                ~isempty(which('systemcomposer.allocation.createAllocationSet'));
        end

        function runPhase(testCase, phase)
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'propose', phase, struct());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'approve', phase, struct());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'generate', phase, struct());
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'run', phase, struct());
            if any(string(phase) == ["F", "L", "P"])
                % 二次执行必须清理并重建模型与分配集，不能累积失效 SID。
                matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'run', phase, struct());
            end
            matlabcopilot.MBSEWorkflow.apply(testCase.Root, 'confirm', phase, struct());
        end

        function writeSources(testCase)
            reqFid = fopen(fullfile(testCase.Root, 'requirements.csv'), 'w', 'n', 'UTF-8');
            reqCleaner = onCleanup(@() fclose(reqFid)); %#ok<NASGU>
            fprintf(reqFid, ['ID,Title,Description\n' ...
                'REQ-001,Sense temperature,The system shall sense temperature.\n' ...
                'REQ-002,Compute command,The system shall compute a cooling command.\n']);
            clear reqCleaner
            mbseArch = fullfile(testCase.Root, 'mbse', 'architecture');
            mkdir(mbseArch);
            functions(1) = struct('name', 'SenseTemperature', 'description', 'Sense temperature', ...
                'requirements', {{'REQ-001'}}, 'inputs', {{}}, 'outputs', {{'Temperature'}});
            functions(2) = struct('name', 'ComputeCoolingCommand', 'description', 'Compute command', ...
                'requirements', {{'REQ-002'}}, 'inputs', {{'Temperature'}}, 'outputs', {{}});
            connections = struct('source', 'SenseTemperature/Temperature', ...
                'destination', 'ComputeCoolingCommand/Temperature');
            proposal = struct('schemaVersion', 1, 'modelName', 'ThermalControllerFunctional', ...
                'functions', functions, 'connections', connections);
            testCase.writeJson(fullfile(mbseArch, 'functional-architecture.json'), proposal);

            elements(1) = struct('name', 'SensingUnit', 'description', 'Logical sensing role', ...
                'functions', {{'SenseTemperature'}}, 'requirements', {{'REQ-001'}}, ...
                'inputs', {{}}, 'outputs', {{'Temperature'}});
            elements(2) = struct('name', 'ControlUnit', 'description', 'Logical control role', ...
                'functions', {{'ComputeCoolingCommand'}}, 'requirements', {{'REQ-002'}}, ...
                'inputs', {{'Temperature'}}, 'outputs', {{}});
            logicalConnection = struct('source', 'SensingUnit/Temperature', ...
                'destination', 'ControlUnit/Temperature');
            logical = struct('schemaVersion', 1, 'modelName', 'ThermalControllerLogical', ...
                'elements', elements, 'connections', logicalConnection);
            testCase.writeJson(fullfile(mbseArch, 'logical-architecture.json'), logical);

            components(1) = struct('name', 'TemperatureSensor', 'description', 'Physical sensor', ...
                'logicalElements', {{'SensingUnit'}}, 'requirements', {{'REQ-001'}}, ...
                'inputs', {{}}, 'outputs', {{'Temperature'}}, ...
                'properties', struct('massKg', 0.1, 'powerW', 0.5, 'cost', 20));
            components(2) = struct('name', 'ControllerECU', 'description', 'Physical controller', ...
                'logicalElements', {{'ControlUnit'}}, 'requirements', {{'REQ-002'}}, ...
                'inputs', {{'Temperature'}}, 'outputs', {{}}, ...
                'properties', struct('massKg', 0.4, 'powerW', 3, 'cost', 80));
            physicalConnection = struct('source', 'TemperatureSensor/Temperature', ...
                'destination', 'ControllerECU/Temperature');
            physical = struct('schemaVersion', 1, 'modelName', 'ThermalControllerPhysical', ...
                'profileName', 'ThermalControllerPhysicalProfile', ...
                'components', components, 'connections', physicalConnection);
            testCase.writeJson(fullfile(mbseArch, 'physical-architecture.json'), physical);

            verificationItems(1) = struct('id', 'VER-001', 'requirementId', 'REQ-001', ...
                'method', 'architecture_trace', 'artifact', '', 'reviewed', false);
            verificationItems(2) = struct('id', 'VER-002', 'requirementId', 'REQ-002', ...
                'method', 'architecture_trace', 'artifact', '', 'reviewed', false);
            plan = struct('schemaVersion', 1, 'verificationItems', verificationItems);
            testCase.writeJson(fullfile(testCase.Root, 'mbse', 'verification-plan.json'), plan);
        end

        function writeJson(~, file, value)
            fid = fopen(file, 'w', 'n', 'UTF-8');
            cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fprintf(fid, '%s', jsonencode(value, 'PrettyPrint', true));
        end

        function cleanupFixture(testCase)
            try, slreq.clear(); catch, end
            try, Simulink.data.dictionary.closeAll('-discard'); catch, end
            try
                models = find_system('type', 'block_diagram');
                for i = 1:numel(models); close_system(models{i}, 0); end
            catch
            end
            reqPath = fullfile(testCase.Root, 'mbse', 'generated', 'requirements');
            archPath = fullfile(testCase.Root, 'mbse', 'generated', 'architecture');
            entries = string(strsplit(path, pathsep));
            if any(entries == string(reqPath)); rmpath(reqPath); end
            if any(entries == string(archPath)); rmpath(archPath); end
            if isfolder(testCase.Root); try, rmdir(testCase.Root, 's'); catch, end; end
        end
    end
end
