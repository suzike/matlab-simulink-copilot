classdef Diagnostics < handle
    % 结构化诊断采集:对标官方「从诊断查看器抓诊断、带 block 跳转」。
    % 用文档化的 sldiagviewer.DiagnosticReceiver 捕获模型运行期诊断(错误/警告/信息),
    % 每条带消息/ID/严重度/block 路径;再用命令行 lasterr 兜底。
    % receiver 是「前向」的:面板创建后才捕获后续操作的诊断,故在 Panel 构造时就建好。

    properties
        Receiver   % sldiagviewer.DiagnosticReceiver(无 Simulink 时为空)
    end

    methods
        function obj = Diagnostics()
            obj.Receiver = [];
            try
                obj.Receiver = sldiagviewer.DiagnosticReceiver;
            catch
            end
        end

        function list = collect(obj)
            % 返回 struct 数组(最新在前,最多 20 条):severity/message/id/block。
            list = struct('severity', {}, 'message', {}, 'id', {}, 'block', {});
            try
                if ~isempty(obj.Receiver) && isvalid(obj.Receiver)
                    msgs = getDiagnostics(obj.Receiver);   % cell of MSLDiagnostic
                    for k = 1:numel(msgs)
                        list(end+1) = matlabcopilot.Diagnostics.fromMSL(msgs{k}); %#ok<AGROW>
                    end
                end
            catch
            end
            % 命令行最近报错兜底(去重)。
            try
                le = lasterror; %#ok<LERR>
                if ~isempty(le.message)
                    s = struct('severity', "error", 'message', string(le.message), ...
                        'id', string(le.identifier), ...
                        'block', matlabcopilot.Diagnostics.parseBlock(le.message));
                    if isempty(list) || ~any(arrayfun(@(x) x.message == s.message, list))
                        list(end+1) = s;
                    end
                end
            catch
            end
            % 最新在前 + 截断。
            if ~isempty(list)
                list = fliplr(list);
                if numel(list) > 20; list = list(1:20); end
            end
        end

        function delete(obj)
            try
                if ~isempty(obj.Receiver) && isvalid(obj.Receiver)
                    delete(obj.Receiver);
                end
            catch
            end
        end
    end

    methods (Static)
        function s = fromMSL(d)
            % 把一个 MSLDiagnostic 转成统一 struct(属性名按版本兜底尝试)。
            s = struct('severity', "error", 'message', "", 'id', "", 'block', "");
            try, s.message = string(d.Message); catch, end
            try
                s.id = string(d.MessageID);
            catch
                try, s.id = string(d.Identifier); catch, end
            end
            try, s.severity = lower(string(d.Type)); catch, end
            % block 路径:Paths(cell)优先,其次 Source,最后从消息文本解析。
            try
                p = d.Paths;
                if iscell(p) && ~isempty(p)
                    s.block = string(p{1});
                elseif ~isempty(p)
                    s.block = string(p);
                end
            catch
                try, s.block = string(d.Source); catch, end
            end
            if strlength(s.block) == 0
                s.block = matlabcopilot.Diagnostics.parseBlock(s.message);
            end
        end

        function blk = parseBlock(msg)
            % 从报错文本里抽 'model/.../Block' 形式的 block 完整路径(Simulink 报错常内嵌)。
            blk = "";
            try
                tok = regexp(string(msg), "'([A-Za-z]\w*(?:/[^'\n]+)+)'", 'tokens', 'once');
                if ~isempty(tok); blk = strtrim(string(tok{1})); end
            catch
            end
        end
    end
end
