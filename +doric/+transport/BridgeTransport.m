classdef BridgeTransport < doric.transport.Transport
%BRIDGETRANSPORT Real device through the doric_bridge.exe helper process (decision D1).
%
%   t = doric.transport.BridgeTransport()
%   t = doric.transport.BridgeTransport('Name', value, ...)
%
%   Name-value options (also settable properties while closed)
%       ExePath         bridge executable (default from doric.config: <root>/bin/doric_bridge.exe)
%       DllDir          folder holding DoricSystem.dll and its Qt runtime (default from
%                       doric.config: DoricSystemDLL/API/lib/x64/release/Qt)
%       PumpMs          wait() slice the bridge pumps while idle (default 10)
%       SettleMs        default settle window of the bridge (default 100)
%       Debugger        --debugger flag passed to the bridge (default true)
%       CaptureOds      capture OutputDebugString text too (default true)
%       Simulate        run the bridge with --simulate (no DLL, no hardware; default false)
%       SimDevices      '--sim-devices' list, e.g. '5:LEDFLS_465_465' (default: bridge default)
%       StartTimeoutMs  time allowed for the bridge to report READY (default 10000)
%       CloseTimeoutMs  time allowed for a clean exit after stdin closes (default 5000)
%
%   Read-only after open: BridgeVersion, DllPath, Pid, ExitCode.
%
%   The process is started through java.lang.ProcessBuilder with piped stdin/stdout; poll()
%   drains complete lines that are already available and never blocks. Constructing the object
%   does not start anything. open() starts the bridge and waits for READY and HELLO; close()
%   closes the bridge's stdin, which makes it stop every opened port, close, quit and exit.
%   If MATLAB dies, the pipe closes the same way.
%
%   Errors
%       doric:BridgeTransport:notWindows         real bridge requested off Windows
%       doric:BridgeTransport:bridgeNotFound     executable missing (run doric.build())
%       doric:BridgeTransport:vendorDllNotFound  DoricSystem.dll missing or failed to load
%       doric:BridgeTransport:missingExport      the DLL lacks an expected export
%       doric:BridgeTransport:startFailed        the process did not start or report READY
%       doric:BridgeTransport:bridgeExited       send() after the process exited
%
%   See also doric.transport.Transport, doric.config, doric.build, docs/bridge-protocol.md

    properties
        ExePath = ''
        DllDir = ''
        PumpMs = 10
        SettleMs = 100
        Debugger = true
        CaptureOds = true
        Simulate = false
        SimDevices = ''
        StartTimeoutMs = 10000
        CloseTimeoutMs = 5000
    end

    properties (SetAccess = private)
        BridgeVersion = ''
        DllPath = ''
        Pid = []
        ExitCode = []
    end

    properties (Access = private)
        Process = []
        Reader = []
        Writer = []
        ExitReported = false
    end

    methods
        function obj = BridgeTransport(varargin)
            cfg = doric.config();
            obj.ExePath = cfg.BridgeExe;
            obj.DllDir = cfg.DllDir;
            if mod(numel(varargin), 2) ~= 0
                error('doric:BridgeTransport:invalidOption', 'Options must be name-value pairs.');
            end
            valid = properties(obj);
            for k = 1:2:numel(varargin)
                match = strcmpi(valid, char(varargin{k}));
                if ~any(match)
                    error('doric:BridgeTransport:invalidOption', 'Unknown option "%s".', ...
                        char(varargin{k}));
                end
                obj.(valid{match}) = varargin{k + 1};
            end
        end

        function open(obj)
            if obj.isOpen()
                return
            end
            obj.cleanupProcess();
            if ~ispc
                error('doric:BridgeTransport:notWindows', ...
                    'doric_bridge.exe runs on Windows only; use SimulatedTransport elsewhere.');
            end
            if ~isfile(obj.ExePath)
                error('doric:BridgeTransport:bridgeNotFound', ...
                    'Bridge executable not found: %s\nBuild it once with doric.build().', ...
                    obj.ExePath);
            end
            if ~obj.Simulate && ~isfile(fullfile(obj.DllDir, 'DoricSystem.dll'))
                error('doric:BridgeTransport:vendorDllNotFound', ...
                    'DoricSystem.dll not found in %s.', obj.DllDir);
            end
            command = {char(obj.ExePath), '--pump-ms', sprintf('%d', obj.PumpMs), ...
                '--settle-ms', sprintf('%d', obj.SettleMs), ...
                '--debugger', sprintf('%d', logical(obj.Debugger))};
            if obj.Simulate
                command{end + 1} = '--simulate';
                if ~isempty(obj.SimDevices)
                    command = [command, {'--sim-devices', char(obj.SimDevices)}];
                end
            else
                command = [command, {'--dll-dir', char(obj.DllDir), ...
                    '--capture-ods', sprintf('%d', logical(obj.CaptureOds))}];
            end
            try
                builder = java.lang.ProcessBuilder(command);
                builder.directory(java.io.File(fileparts(char(obj.ExePath))));
                builder.redirectErrorStream(true);
                obj.Process = builder.start();
            catch err
                error('doric:BridgeTransport:startFailed', 'Could not start %s: %s', ...
                    obj.ExePath, err.message);
            end
            obj.Reader = java.io.BufferedReader(java.io.InputStreamReader( ...
                obj.Process.getInputStream(), 'UTF-8'));
            obj.Writer = java.io.BufferedWriter(java.io.OutputStreamWriter( ...
                obj.Process.getOutputStream(), 'UTF-8'));
            obj.ExitReported = false;
            obj.ExitCode = [];

            % Wait for READY (or FATAL / early exit), keeping everything else for poll().
            start = tic;
            held = doric.transport.Transport.emptyMessages();
            while true
                messages = obj.readNew();
                for k = 1:numel(messages)
                    m = messages(k);
                    if strcmp(m.Kind, 'event') && strcmp(m.Name, 'READY')
                        obj.stash(held);
                        obj.stash(messages(k + 1:end));
                        obj.handshake();
                        return
                    elseif (strcmp(m.Kind, 'event') && strcmp(m.Name, 'FATAL')) || ...
                            strcmp(m.Kind, 'exit')
                        obj.failStart(m, [held, messages]);
                    end
                    held(end + 1) = m; %#ok<AGROW>
                end
                if toc(start) * 1000 > obj.StartTimeoutMs
                    obj.cleanupProcess();
                    error('doric:BridgeTransport:startFailed', ...
                        'The bridge did not report READY within %d ms.', obj.StartTimeoutMs);
                end
                pause(0.005);
            end
        end

        function close(obj)
            if isempty(obj.Process)
                return
            end
            try
                obj.Writer.close();  % stdin EOF: the bridge stops, closes, quits and exits
            catch
                % already closed
            end
            start = tic;
            while obj.Process.isAlive() && toc(start) * 1000 < obj.CloseTimeoutMs
                obj.stash(obj.readNew());
                pause(0.01);
            end
            if obj.Process.isAlive()
                obj.Process.destroyForcibly();
            end
            % The shutdown lines (stop all, close, quit, EXITING) can still be in the pipe.
            obj.stash(obj.readNew());
            obj.cleanupProcess();
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.Process) && obj.Process.isAlive();
        end

        function delete(obj)
            try
                obj.close();
            catch
                % delete never throws
            end
        end
    end

    methods (Access = protected)
        function sendImpl(obj, id, command, args)
            if isempty(obj.Process) || ~obj.Process.isAlive()
                error('doric:BridgeTransport:bridgeExited', ...
                    'The bridge process is not running (exit code %s).', num2str(obj.ExitCode));
            end
            % Drain whatever the bridge has already written. A host that sends a burst without
            % polling would otherwise fill the bridge's stdout pipe, which blocks the bridge in
            % its write and then blocks this write on its full stdin pipe: a deadlock.
            obj.stash(obj.readNew());
            line = doric.transport.ProtocolCodec.encodeRequest(id, command, args);
            try
                obj.Writer.write([line newline]);
                obj.Writer.flush();
            catch err
                error('doric:BridgeTransport:bridgeExited', ...
                    'Writing to the bridge failed: %s', err.message);
            end
        end

        function messages = readImpl(obj)
            messages = obj.readLines();
            if ~obj.ExitReported && ~isempty(obj.Process) && ~obj.Process.isAlive() && ...
                    ~obj.Reader.ready()
                obj.ExitReported = true;
                obj.ExitCode = double(obj.Process.exitValue());
                m = doric.transport.Transport.newMessage('exit');
                m.Code = sprintf('%d', obj.ExitCode);
                m.Text = sprintf('Bridge process exited with code %d', obj.ExitCode);
                m.Time = obj.now();
                messages(end + 1) = m;
            end
        end
    end

    methods (Access = private)
        function messages = readLines(obj)
            messages = doric.transport.Transport.emptyMessages();
            if isempty(obj.Reader)
                return
            end
            try
                while obj.Reader.ready()
                    line = obj.Reader.readLine();
                    if isempty(line)
                        break
                    end
                    messages(end + 1) = doric.transport.ProtocolCodec.decodeLine( ...
                        char(line), obj.now()); %#ok<AGROW>
                end
            catch
                % Stream closed under us: the exit is reported by readImpl.
            end
        end

        function handshake(obj)
            [reply, ~] = obj.request('HELLO', struct(), obj.StartTimeoutMs);
            if ~reply.Ok
                obj.cleanupProcess();
                error('doric:BridgeTransport:startFailed', 'HELLO failed: %s', reply.Text);
            end
            obj.BridgeVersion = doric.transport.BridgeTransport.dataField(reply.Data, 'bridge');
            obj.DllPath = doric.transport.BridgeTransport.dataField(reply.Data, 'dll');
            obj.Pid = str2double(doric.transport.BridgeTransport.dataField(reply.Data, 'pid'));
            obj.DefaultSettleMs = obj.SettleMs;
        end

        function failStart(obj, message, context)
            code = message.Code;
            text = message.Text;
            obj.cleanupProcess();
            if strcmp(message.Kind, 'exit')
                % The exit may come before the FATAL line was read; look for it.
                fatal = context(strcmp({context.Kind}, 'event') & strcmp({context.Name}, 'FATAL'));
                if ~isempty(fatal)
                    code = fatal(1).Code;
                    text = fatal(1).Text;
                end
            end
            switch code
                case 'vendorDllNotFound'
                    error('doric:BridgeTransport:vendorDllNotFound', '%s', text);
                case 'missingExport'
                    error('doric:BridgeTransport:missingExport', '%s', text);
                otherwise
                    error('doric:BridgeTransport:startFailed', 'The bridge failed to start: %s', ...
                        text);
            end
        end

        function cleanupProcess(obj)
            if ~isempty(obj.Process)
                try
                    if obj.Process.isAlive()
                        obj.Process.destroyForcibly();
                    end
                    obj.ExitCode = double(obj.Process.waitFor());
                catch
                    % best effort
                end
            end
            try
                if ~isempty(obj.Reader), obj.Reader.close(); end
            catch
            end
            try
                if ~isempty(obj.Writer), obj.Writer.close(); end
            catch
            end
            obj.Process = [];
            obj.Reader = [];
            obj.Writer = [];
        end
    end

    methods (Static, Access = private)
        function value = dataField(data, name)
            if isfield(data, name)
                value = data.(name);
            else
                value = '';
            end
        end
    end
end
