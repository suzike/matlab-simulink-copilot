classdef ModelFileDiffTest < matlab.unittest.TestCase
    properties
        TempDir
        ModelName
        ModelFile
        BeforeFile
        AfterFile
    end

    methods (TestMethodSetup)
        function createSnapshots(testCase)
            testCase.TempDir = tempname;
            mkdir(testCase.TempDir);
            testCase.ModelName = ['file_diff_' strrep(char(matlab.lang.internal.uuid()), '-', '_')];
            testCase.ModelFile = fullfile(testCase.TempDir, [testCase.ModelName '.slx']);
            testCase.BeforeFile = fullfile(testCase.TempDir, 'saved-before.slx');
            testCase.AfterFile = fullfile(testCase.TempDir, 'saved-after.slx');
            new_system(testCase.ModelName);
            add_block('simulink/Sources/Constant', [testCase.ModelName '/Value'], 'Value', '1');
            save_system(testCase.ModelName, testCase.ModelFile);
            copyfile(testCase.ModelFile, testCase.BeforeFile);
            set_param([testCase.ModelName '/Value'], 'Value', '2');
            add_block('simulink/Math Operations/Gain', [testCase.ModelName '/Gain'], 'Gain', '3');
            save_system(testCase.ModelName, testCase.ModelFile);
            copyfile(testCase.ModelFile, testCase.AfterFile);
        end
    end

    methods (TestMethodTeardown)
        function cleanup(testCase)
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
        function detectsSavedParameterAndBlockChanges(testCase)
            result = matlabcopilot.ModelFileDiff.compare(testCase.BeforeFile, testCase.AfterFile);
            testCase.verifyEqual(string(result.status), "analyzed");
            testCase.verifyGreaterThanOrEqual(result.blockCountAfter, result.blockCountBefore + 1);
            testCase.verifyTrue(any(string(result.added) == "Gain"));
            changes = [result.changes{:}];
            gainValue = changes(string({changes.block}) == "Value" & string({changes.param}) == "Value");
            testCase.verifyNotEmpty(gainValue);
            testCase.verifyEqual(string(gainValue(1).before), "1");
            testCase.verifyEqual(string(gainValue(1).after), "2");
        end

        function rejectsIncompleteSnapshots(testCase)
            testCase.verifyError(@() matlabcopilot.ModelFileDiff.compare( ...
                testCase.BeforeFile, fullfile(testCase.TempDir, 'missing.slx')), ...
                'matlabcopilot:ModelFileDiff:MissingSnapshot');
        end
    end
end
