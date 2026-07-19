classdef ChangeTransactionTest < matlab.unittest.TestCase
    properties
        TempDir
        ModelName
        ModelFile
        BlockPath
    end

    methods (TestMethodSetup)
        function createModel(testCase)
            testCase.TempDir = tempname;
            mkdir(testCase.TempDir);
            testCase.ModelName = ['tx_model_' char(matlab.lang.internal.uuid())];
            testCase.ModelName = strrep(testCase.ModelName, '-', '_');
            testCase.ModelFile = fullfile(testCase.TempDir, [testCase.ModelName '.slx']);
            testCase.BlockPath = [testCase.ModelName '/Value'];
            new_system(testCase.ModelName);
            add_block('simulink/Sources/Constant', testCase.BlockPath, 'Value', '1');
            save_system(testCase.ModelName, testCase.ModelFile);
        end
    end

    methods (TestMethodTeardown)
        function removeModel(testCase)
            try
                if bdIsLoaded(testCase.ModelName); close_system(testCase.ModelName, 0); end
            catch
            end
            try
                if isfolder(testCase.TempDir); rmdir(testCase.TempDir, 's'); end
            catch
            end
        end
    end

    methods (Test)
        function validEditProducesVerifiedManifest(testCase)
            before = matlabcopilot.ModelDiff.snapshot(string(testCase.BlockPath));
            tx = matlabcopilot.ChangeTransaction.start(testCase.ModelName, before, ...
                testCase.TempDir, 'main', 'tool-valid', struct('Value', '2'));

            set_param(testCase.BlockPath, 'Value', '2');
            after = matlabcopilot.ModelDiff.snapshot(before.paths, before.parents);
            diff = matlabcopilot.ModelDiff.compare(before, after);
            [done, event] = matlabcopilot.ChangeTransaction.finish(tx, after, diff, true, 'ok');

            testCase.verifyEqual(string(done.status), "verified");
            testCase.verifyTrue(done.verification.compileOk);
            testCase.verifyTrue(done.verification.standardsOk);
            testCase.verifyFalse(done.rollback.attempted);
            testCase.verifyEqual(string(event.type), "change_transaction");
            testCase.verifyTrue(isfile(done.manifestFile));
            manifest = jsondecode(fileread(done.manifestFile));
            testCase.verifyEqual(string(manifest.status), "verified");
            recorder = matlabcopilot.ChangeTransaction.buildRecorderEntry(done);
            testCase.verifyEqual(string(recorder.source), "ai-model-edit");
            testCase.verifyEqual(string(recorder.kind), "model_edit");
            testCase.verifyEqual(string(recorder.relativePath), string(testCase.ModelName) + ".slx");
            testCase.verifyEqual(string(recorder.evidenceFile), string(done.manifestFile));
        end

        function compileFailureRestoresCheckpoint(testCase)
            before = matlabcopilot.ModelDiff.snapshot(string(testCase.BlockPath));
            tx = matlabcopilot.ChangeTransaction.start(testCase.ModelName, before, ...
                testCase.TempDir, 'main', 'tool-invalid', struct('Value', 'missingCalibration'));
            testCase.verifyTrue(tx.rollbackAvailable);

            set_param(testCase.BlockPath, 'Value', 'missingCalibration');
            after = matlabcopilot.ModelDiff.snapshot(before.paths, before.parents);
            diff = matlabcopilot.ModelDiff.compare(before, after);
            [done, event] = matlabcopilot.ChangeTransaction.finish(tx, after, diff, true, 'ok');

            testCase.verifyEqual(string(done.status), "rolled_back");
            testCase.verifyTrue(done.rollback.attempted);
            testCase.verifyTrue(done.rollback.ok);
            testCase.verifyTrue(event.rolledBack);
            testCase.verifyTrue(bdIsLoaded(testCase.ModelName));
            testCase.verifyEqual(string(get_param(testCase.BlockPath, 'Value')), "1");
        end

        function dirtyBaselineDisablesAutomaticRollback(testCase)
            set_param(testCase.BlockPath, 'Position', [40 40 90 80]);
            testCase.verifyEqual(string(get_param(testCase.ModelName, 'Dirty')), "on");
            before = matlabcopilot.ModelDiff.snapshot(string(testCase.BlockPath));
            tx = matlabcopilot.ChangeTransaction.start(testCase.ModelName, before, ...
                testCase.TempDir, 'main', 'tool-dirty', ...
                struct('apiKey', 'must-not-leak', 'nested', struct('password', 'hidden')));

            testCase.verifyTrue(tx.baselineDirty);
            testCase.verifyFalse(tx.rollbackAvailable);
            testCase.verifyEqual(string(tx.input.apiKey), "<redacted>");
            testCase.verifyEqual(string(tx.input.nested.password), "<redacted>");
            testCase.verifyEqual(string(tx.status), "pending");
        end

        function abandonedTransactionIsPersisted(testCase)
            before = matlabcopilot.ModelDiff.snapshot(string(testCase.BlockPath));
            tx = matlabcopilot.ChangeTransaction.start(testCase.ModelName, before, ...
                testCase.TempDir, 'tab-closed', 'tool-pending', struct());
            done = matlabcopilot.ChangeTransaction.abandon(tx, '会话已关闭');

            testCase.verifyEqual(string(done.status), "abandoned");
            manifest = jsondecode(fileread(done.manifestFile));
            testCase.verifyEqual(string(manifest.status), "abandoned");
            testCase.verifyEqual(string(manifest.verification.message), "会话已关闭");
        end
    end
end
