classdef ModelFileDiff
    % 已保存模型快照的隔离语义对比。
    % 将前后文件复制为唯一模型名，只读 load_system 后复用 VersionDiff 的
    % 相对块路径/对话参数快照，完成后无条件关闭临时模型并删除工作目录。

    methods (Static)
        function semantic = compare(beforeFile, afterFile)
            beforeFile = char(string(beforeFile));
            afterFile = char(string(afterFile));
            if ~isfile(beforeFile) || ~isfile(afterFile)
                error('matlabcopilot:ModelFileDiff:MissingSnapshot', ...
                    '模型前后快照不完整，无法执行语义对比。');
            end
            [~, ~, beforeExt] = fileparts(beforeFile);
            [~, ~, afterExt] = fileparts(afterFile);
            if ~any(strcmpi(beforeExt, {'.slx', '.mdl'})) || ~strcmpi(beforeExt, afterExt)
                error('matlabcopilot:ModelFileDiff:UnsupportedType', ...
                    '仅支持同类型 .slx/.mdl 前后快照。');
            end

            token = strrep(char(matlab.lang.internal.uuid()), '-', '_');
            beforeName = ['mc_before_' token];
            afterName = ['mc_after_' token];
            workDir = tempname;
            mkdir(workDir);
            beforeCopy = fullfile(workDir, [beforeName beforeExt]);
            afterCopy = fullfile(workDir, [afterName afterExt]);
            cleanupObj = onCleanup(@() matlabcopilot.ModelFileDiff.cleanup( ...
                beforeName, afterName, workDir));
            copyfile(beforeFile, beforeCopy, 'f');
            copyfile(afterFile, afterCopy, 'f');

            load_system(beforeCopy);
            load_system(afterCopy);
            old = matlabcopilot.VersionDiff.snapModel(beforeName);
            cur = matlabcopilot.VersionDiff.snapModel(afterName);
            d = matlabcopilot.VersionDiff.compareSnaps(old, cur);
            semantic = struct('status', 'analyzed', ...
                'analyzedAt', matlabcopilot.ModelFileDiff.nowText(), ...
                'message', '', 'changes', {num2cell(d.changes)}, ...
                'added', {cellstr(d.added)}, 'removed', {cellstr(d.removed)}, ...
                'blockCountBefore', numel(old.blocks), ...
                'blockCountAfter', numel(cur.blocks), ...
                'truncated', numel(old.blocks) >= 400 || numel(cur.blocks) >= 400);
        end

        function cleanup(beforeName, afterName, workDir)
            try
                if bdIsLoaded(beforeName); close_system(beforeName, 0); end
            catch
            end
            try
                if bdIsLoaded(afterName); close_system(afterName, 0); end
            catch
            end
            try
                if isfolder(workDir); rmdir(workDir, 's'); end
            catch
            end
        end

        function text = nowText()
            text = char(string(datetime('now', 'Format', "yyyy-MM-dd'T'HH:mm:ss.SSS")));
        end
    end
end
