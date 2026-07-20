classdef SetupTest < matlab.unittest.TestCase
    methods (Test)
        function managedStartupIsIdempotentAndScoped(testCase)
            base = string(tempname); mkdir(base);
            cleanup = onCleanup(@() SetupTest.cleanup(base)); %#ok<NASGU>
            root = fullfile(base, "toolbox", "matlab"); mkdir(root);
            startupFile = fullfile(base, "user", "startup.m");
            mkdir(fileparts(startupFile));
            SetupTest.write(startupFile, "disp('user startup');" + newline);
            SetupTest.write(fullfile(root, "copilot.m"), "function copilot" + newline + "end" + newline);

            first = setupMATLABCopilot("install", Root=root, StartupFile=startupFile, ...
                Persistence="startup", ApplyPath=true);
            testCase.verifyTrue(first.ok);
            setupMATLABCopilot("repair", Root=root, StartupFile=startupFile, ...
                Persistence="startup", ApplyPath=true);
            text = string(fileread(startupFile));
            testCase.verifyEqual(count(text, "% MATLAB-Copilot managed path begin"), 1);
            testCase.verifySubstring(text, "disp('user startup');");

            removed = setupMATLABCopilot("uninstall", Root=root, StartupFile=startupFile, ...
                Persistence="startup", ApplyPath=true);
            testCase.verifyFalse(removed.onPath);
            text = string(fileread(startupFile));
            testCase.verifyFalse(contains(text, "MATLAB-Copilot managed path"));
            testCase.verifySubstring(text, "disp('user startup');");
        end
    end

    methods (Static, Access=private)
        function write(file, text)
            fid = fopen(file, 'w', 'n', 'UTF-8');
            cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
            fwrite(fid, char(text), 'char');
        end

        function cleanup(base)
            try
                if isfolder(base); rmdir(base, 's'); end
            catch
            end
        end
    end
end
