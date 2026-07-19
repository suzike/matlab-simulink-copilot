classdef ChangeTransaction
    % 模型变更事务：为单次 model_edit 建立检查点、验证结果和失败回退证据。
    % 只有模型在修改前已保存且无未保存改动时才允许自动回退，避免覆盖用户工作。

    methods (Static)
        function tx = start(model, before, cwd, convId, toolId, input)
            m = char(string(model));
            if isempty(m) || ~bdIsLoaded(m)
                error('matlabcopilot:ChangeTransaction:ModelNotLoaded', ...
                    '模型 %s 未加载，无法建立变更事务。', m);
            end

            runId = "run-" + string(matlab.lang.internal.uuid());
            runDir = fullfile(matlabcopilot.ChangeTransaction.runsRoot(), char(runId));
            if ~isfolder(runDir); mkdir(runDir); end

            modelFile = "";
            dirty = true;
            try
                modelFile = string(get_param(m, 'FileName'));
            catch
            end
            try
                dirty = strcmpi(get_param(m, 'Dirty'), 'on');
            catch
            end

            checkpoint = "";
            rollbackAvailable = false;
            rollbackUnavailableReason = "模型文件尚未保存，无法建立可回退检查点。";
            if dirty
                rollbackUnavailableReason = "修改前模型含未保存内容，自动回退已禁用。";
            end
            if ~dirty && strlength(modelFile) > 0 && isfile(modelFile)
                [~, ~, ext] = fileparts(char(modelFile));
                checkpoint = string(fullfile(runDir, ['checkpoint' ext]));
                [ok, msg] = copyfile(char(modelFile), char(checkpoint), 'f');
                if ~ok
                    error('matlabcopilot:ChangeTransaction:CheckpointFailed', ...
                        '无法创建模型检查点：%s', msg);
                end
                rollbackAvailable = true;
                rollbackUnavailableReason = "";
            end

            % Transaction setup runs before the model-edit permission decision. It must
            % remain side-effect free: compiling/updating here can execute callbacks.
            baselineCompileOk = false;
            baselineCompileMessage = "基线阶段未执行模型更新；修改后验证会在工具执行完成后运行。";

            [rules, source, loadError] = matlabcopilot.StandardsChecker.loadRules(cwd);
            findings = matlabcopilot.StandardsChecker.check(m, rules);
            baselineErrors = matlabcopilot.ChangeTransaction.errorKeys(findings);

            nowText = matlabcopilot.ChangeTransaction.nowText();
            tx = struct( ...
                'schemaVersion', 1, 'runId', char(runId), 'status', 'pending', ...
                'startedAt', nowText, 'updatedAt', nowText, ...
                'model', m, 'modelFile', char(modelFile), ...
                'projectRoot', char(string(cwd)), 'convId', char(string(convId)), ...
                'toolId', char(string(toolId)), ...
                'input', matlabcopilot.ChangeTransaction.sanitize(input, 0), ...
                'runDir', runDir, 'manifestFile', string(fullfile(runDir, 'manifest.json')), ...
                'checkpointFile', char(checkpoint), ...
                'rollbackAvailable', logical(rollbackAvailable), ...
                'rollbackUnavailableReason', char(rollbackUnavailableReason), ...
                'baselineDirty', logical(dirty), ...
                'before', matlabcopilot.ChangeTransaction.snapshotSummary(before), ...
                'baselineVerification', struct('compileOk', baselineCompileOk, ...
                    'compileChecked', false, 'compileMessage', char(baselineCompileMessage)), ...
                'baselineStandards', struct('source', char(source), ...
                    'loadError', char(loadError), 'errors', {cellstr(baselineErrors)}), ...
                'change', struct(), 'verification', struct(), ...
                'rollback', struct('attempted', false, 'ok', false, 'message', ''));
            matlabcopilot.ChangeTransaction.persist(tx);
        end

        function [tx, ev] = finish(tx, after, diff, toolOk, toolMessage)
            if nargin < 5; toolMessage = ""; end
            tx.updatedAt = matlabcopilot.ChangeTransaction.nowText();
            tx.change = matlabcopilot.ChangeTransaction.changeSummary(after, diff, toolOk, toolMessage);

            compileOk = false;
            compileMessage = "";
            if toolOk
                try
                    set_param(tx.model, 'SimulationCommand', 'update');
                    compileOk = true;
                catch err
                    compileMessage = string(err.message);
                end
            else
                compileMessage = "model_edit 工具返回失败";
            end

            standardsOk = false;
            standardsMessage = "";
            newErrors = strings(0, 1);
            afterErrorCount = 0;
            if toolOk
                try
                    [rules, ~, loadError] = matlabcopilot.StandardsChecker.loadRules(tx.projectRoot);
                    findings = matlabcopilot.StandardsChecker.check(tx.model, rules);
                    afterErrors = matlabcopilot.ChangeTransaction.errorKeys(findings);
                    afterErrorCount = numel(afterErrors);
                    baselineErrors = string(tx.baselineStandards.errors);
                    newErrors = setdiff(afterErrors, baselineErrors, 'stable');
                    standardsOk = isempty(newErrors);
                    if strlength(loadError) > 0; standardsMessage = loadError; end
                catch err
                    standardsMessage = string(err.message);
                end
            end

            verified = logical(toolOk) && compileOk && standardsOk;
            tx.verification = struct( ...
                'passed', verified, ...
                'compileOk', compileOk, 'compileMessage', char(compileMessage), ...
                'standardsOk', standardsOk, 'standardsMessage', char(standardsMessage), ...
                'standardsErrorCount', afterErrorCount, ...
                'newStandardErrors', {cellstr(newErrors)});

            if verified
                tx.status = 'verified';
            else
                [rolledBack, rollbackMessage] = matlabcopilot.ChangeTransaction.rollback(tx);
                tx.rollback = struct('attempted', logical(tx.rollbackAvailable), ...
                    'ok', rolledBack, 'message', char(rollbackMessage));
                if rolledBack
                    tx.status = 'rolled_back';
                elseif tx.rollbackAvailable
                    tx.status = 'rollback_failed';
                else
                    tx.status = 'manual_recovery_required';
                end
            end
            tx.updatedAt = matlabcopilot.ChangeTransaction.nowText();
            matlabcopilot.ChangeTransaction.persist(tx);
            ev = matlabcopilot.ChangeTransaction.buildEvent(tx);
        end

        function tx = abandon(tx, reason)
            if ~strcmp(tx.status, 'pending'); return; end
            tx.status = 'abandoned';
            tx.updatedAt = matlabcopilot.ChangeTransaction.nowText();
            tx.verification = struct('passed', false, 'message', char(string(reason)));
            matlabcopilot.ChangeTransaction.persist(tx);
        end

        function [ok, message] = rollback(tx)
            ok = false;
            message = "修改前模型存在未保存内容，未自动回退。";
            if ~logical(tx.rollbackAvailable); return; end
            try
                if bdIsLoaded(tx.model)
                    close_system(tx.model, 0);
                end
                [copied, copyMessage] = copyfile(tx.checkpointFile, tx.modelFile, 'f');
                if ~copied
                    error('matlabcopilot:ChangeTransaction:RestoreCopyFailed', '%s', copyMessage);
                end
                load_system(tx.modelFile);
                ok = true;
                message = "验证失败，已恢复修改前检查点。";
            catch err
                message = "自动回退失败：" + string(err.message);
            end
        end

        function ev = buildEvent(tx)
            v = tx.verification;
            ev = struct('type', "change_transaction", 'convId', tx.convId, ...
                'runId', tx.runId, 'model', tx.model, 'status', tx.status, ...
                'rollbackAvailable', logical(tx.rollbackAvailable), ...
                'rollbackUnavailableReason', tx.rollbackUnavailableReason, ...
                'rollbackAttempted', logical(tx.rollback.attempted), ...
                'rolledBack', logical(tx.rollback.ok), ...
                'rollbackMessage', tx.rollback.message, ...
                'compileOk', logical(v.compileOk), 'compileMessage', v.compileMessage, ...
                'standardsOk', logical(v.standardsOk), ...
                'newStandardErrors', {v.newStandardErrors}, ...
                'manifestFile', char(tx.manifestFile));
        end

        function entry = buildRecorderEntry(tx)
            rel = string(tx.modelFile);
            root = regexprep(strrep(string(tx.projectRoot), '\', '/'), '/+$', '');
            file = strrep(string(tx.modelFile), '\', '/');
            if strlength(file) > strlength(root) && startsWith(lower(file), lower(root + "/"))
                rel = extractAfter(file, strlength(root) + 1);
            end
            summary = "AI 模型编辑";
            if isfield(tx.change, 'toolMessage') && strlength(string(tx.change.toolMessage)) > 0
                summary = string(tx.change.toolMessage);
            end
            entry = struct('id', tx.runId, 'time', tx.updatedAt, ...
                'source', 'ai-model-edit', 'kind', 'model_edit', ...
                'relativePath', char(rel), 'model', tx.model, ...
                'status', tx.status, 'summary', char(summary), ...
                'changes', {tx.change.changes}, 'added', {tx.change.added}, ...
                'removed', {tx.change.removed}, ...
                'evidenceFile', char(tx.manifestFile));
        end

        function persist(tx)
            target = char(tx.manifestFile);
            tmp = [target '.tmp'];
            fid = fopen(tmp, 'w', 'n', 'UTF-8');
            if fid < 0
                error('matlabcopilot:ChangeTransaction:ManifestWriteFailed', ...
                    '无法写入事务清单：%s', target);
            end
            try
                fprintf(fid, '%s', char(jsonencode(tx, 'PrettyPrint', true)));
                fclose(fid);
            catch err
                fclose(fid);
                rethrow(err);
            end
            [ok, msg] = movefile(tmp, target, 'f');
            if ~ok
                error('matlabcopilot:ChangeTransaction:ManifestMoveFailed', '%s', msg);
            end
        end

        function root = runsRoot()
            home = getenv('USERPROFILE');
            if isempty(home); home = getenv('HOME'); end
            if isempty(home); home = char(java.lang.System.getProperty('user.home')); end
            root = fullfile(home, '.matlab-copilot', 'runs');
            if ~isfolder(root); mkdir(root); end
        end

        function s = snapshotSummary(snap)
            s = struct('paths', {cellstr(string(snap.paths))}, ...
                'parents', {cellstr(string(snap.parents))}, ...
                'blocks', numel(snap.blocks));
        end

        function s = changeSummary(after, diff, toolOk, toolMessage)
            changes = struct('block', {}, 'param', {}, 'before', {}, 'after', {});
            if isfield(diff, 'changes'); changes = diff.changes; end
            s = struct('toolOk', logical(toolOk), 'toolMessage', char(string(toolMessage)), ...
                'after', matlabcopilot.ChangeTransaction.snapshotSummary(after), ...
                'changes', {num2cell(changes)}, ...
                'added', {cellstr(string(diff.added))}, ...
                'removed', {cellstr(string(diff.removed))});
        end

        function keys = errorKeys(findings)
            keys = strings(0, 1);
            if isempty(findings); return; end
            for i = 1:numel(findings)
                if string(findings(i).severity) ~= "error"; continue; end
                keys(end+1, 1) = string(findings(i).rule) + "|" + ...
                    string(findings(i).path) + "|" + string(findings(i).msg); %#ok<AGROW>
            end
            keys = unique(keys, 'stable');
        end

        function out = sanitize(value, depth)
            if depth > 6
                out = '<truncated>';
            elseif isstruct(value)
                out = value;
                fields = fieldnames(value);
                for n = 1:numel(value)
                    for i = 1:numel(fields)
                        name = fields{i};
                        if ~isempty(regexpi(name, 'token|secret|password|authorization|cookie|api.?key', 'once'))
                            out(n).(name) = '<redacted>';
                        else
                            out(n).(name) = matlabcopilot.ChangeTransaction.sanitize(value(n).(name), depth + 1);
                        end
                    end
                end
            elseif iscell(value)
                out = value;
                for i = 1:numel(value)
                    out{i} = matlabcopilot.ChangeTransaction.sanitize(value{i}, depth + 1);
                end
            elseif ischar(value) || isstring(value)
                out = string(value);
                out(strlength(out) > 2000) = extractBefore(out(strlength(out) > 2000), 2001) + "…";
                if ischar(value) && isscalar(out); out = char(out); end
            else
                out = value;
            end
        end

        function text = nowText()
            text = char(string(datetime('now', 'Format', "yyyy-MM-dd'T'HH:mm:ss.SSS")));
        end
    end
end
