classdef Bridge < handle
    % sidecar 通信桥:负责启动 Node sidecar 进程、用 tcpclient 连接它、
    % 按行(LF 结尾的 JSON)收发消息。收到的每条消息通过 OnMessage 回调上抛给 Panel。

    properties
        Host = "127.0.0.1"
        Port = 8765
        ControlPort = 8766
        Backend = "claude"     % "claude" | "echo"
        NodeBin = "node"
        SidecarDir string      % .../sidecar
        Cwd string             % agent 工作目录
        Client                 % tcpclient
        Process                % java.lang.Process
        OnMessage function_handle = function_handle.empty
        OnStatus  function_handle = function_handle.empty
        RxBuffer string = ""    % 接收行缓冲(可能有跨包的半行)
    end

    methods
        function obj = Bridge(sidecarDir, cwd, opts)
            arguments
                sidecarDir (1,1) string
                cwd (1,1) string
                opts.Backend (1,1) string = "claude"
                opts.Port (1,1) double = 8765
                opts.ControlPort (1,1) double = 8766
                opts.NodeBin (1,1) string = "node"
            end
            obj.SidecarDir = sidecarDir;
            obj.Cwd = cwd;
            obj.Backend = opts.Backend;
            obj.Port = opts.Port;
            obj.ControlPort = opts.ControlPort;
            obj.NodeBin = opts.NodeBin;
        end

        function start(obj)
            obj.launchSidecar();
            obj.connect();
        end

        function launchSidecar(obj)
            % 用 ProcessBuilder 后台启动 sidecar,不阻塞 MATLAB;输出重定向到日志文件。
            entry = fullfile(obj.SidecarDir, 'src', 'index.js');
            if ~isfile(entry)
                error('matlabcopilot:sidecarMissing', '找不到 sidecar 入口: %s', entry);
            end
            args = javaArray('java.lang.String', 2);
            args(1) = java.lang.String(obj.NodeBin);
            args(2) = java.lang.String(entry);
            pb = java.lang.ProcessBuilder(args);
            env = pb.environment();
            env.put('MATLAB_COPILOT_CWD', char(obj.Cwd));
            env.put('MATLAB_COPILOT_BACKEND', char(obj.Backend));
            env.put('MATLAB_COPILOT_PORT', num2str(obj.Port));
            env.put('MATLAB_COPILOT_CONTROL_PORT', num2str(obj.ControlPort));
            logFile = fullfile(tempdir, 'matlab-copilot-sidecar.log');
            pb.redirectErrorStream(true);
            pb.redirectOutput(java.io.File(logFile));
            obj.Process = pb.start();
            obj.status(sprintf('sidecar 启动中(日志: %s)', logFile));
        end

        function connect(obj)
            % sidecar 起来需要一点时间,带重试地连。
            deadline = tic;
            lastErr = '';
            while toc(deadline) < 15
                try
                    t = tcpclient(obj.Host, obj.Port, 'Timeout', 5, 'ConnectTimeout', 5);
                    configureTerminator(t, "LF");
                    configureCallback(t, "terminator", @(src, ~) obj.onData(src));
                    obj.Client = t;
                    obj.status('已连接 sidecar');
                    return;
                catch err
                    lastErr = err.message;
                    pause(0.4);
                end
            end
            error('matlabcopilot:connect', '无法连接 sidecar (%s:%d): %s', ...
                obj.Host, obj.Port, lastErr);
        end

        function onData(obj, src)
            % "terminator" 回调:一次性把可用字节全部读出,自己按 LF 切分,
            % 处理所有完整行。这样即使多行在同一包到达(如 assistant_stop+result),
            % 也不会有行滞留缓冲区导致丢事件。
            try
                n = src.NumBytesAvailable;
                if n == 0; return; end
                raw = read(src, n, "uint8");
                obj.RxBuffer = obj.RxBuffer + string(char(raw(:)'));
            catch
                return;
            end
            parts = split(obj.RxBuffer, newline);
            obj.RxBuffer = parts(end);            % 最后一段可能是半行,留着
            for k = 1:numel(parts)-1
                line = strtrim(parts(k));
                if strlength(line) == 0; continue; end
                try
                    msg = jsondecode(line);
                catch
                    continue;
                end
                if ~isempty(obj.OnMessage)
                    try
                        obj.OnMessage(msg);
                    catch err
                        obj.status(['处理消息出错: ' err.message]);
                    end
                end
            end
        end

        function send(obj, msg)
            % 把结构体序列化为一行 JSON 发给 sidecar。
            if isempty(obj.Client)
                obj.status('未连接,发送被忽略');
                return;
            end
            try
                % 转纯 ASCII(非 ASCII → \uXXXX),与 sidecar 一致,避免编码歧义。
                writeline(obj.Client, matlabcopilot.Bridge.asciiJson(jsonencode(msg)));
            catch err
                obj.status(['发送失败: ' err.message]);
            end
        end

        function status(obj, text)
            if ~isempty(obj.OnStatus)
                try, obj.OnStatus(string(text)); catch, end
            end
        end

        function close(obj)
            try
                if ~isempty(obj.Client)
                    configureCallback(obj.Client, "off");
                    clear obj.Client;
                    obj.Client = [];
                end
            catch
            end
            try
                if ~isempty(obj.Process)
                    obj.Process.destroy();
                    obj.Process = [];
                end
            catch
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Static)
        function out = asciiJson(s)
            % 把字符串里所有非 ASCII 字符转成 \uXXXX(BMP 范围足够覆盖中文)。
            % 性能关键:model_diff 等事件含 base64 截图(数十万字符)+ 少量中文;
            % 只按"非 ASCII 的位置"分段拼接,循环次数 = 中文字符数(几十),而非总长(几十万)。
            % 旧实现逐字符建 strings 数组,一次序列化卡数秒且阻塞 MATLAB 主线程(连带拖慢 MCP 工具)。
            c = char(s);
            pos = find(double(c) > 127);
            if isempty(pos)
                out = c;
                return;
            end
            segs = cell(1, 2 * numel(pos) + 1);
            prev = 1;
            for k = 1:numel(pos)
                segs{2*k - 1} = c(prev:pos(k) - 1);
                segs{2*k} = sprintf('\\u%04x', double(c(pos(k))));
                prev = pos(k) + 1;
            end
            segs{end} = c(prev:end);
            out = [segs{:}];
        end
    end
end
