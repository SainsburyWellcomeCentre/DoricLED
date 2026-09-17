classdef SimulatedTransport < doric.transport.Transport
%SIMULATEDTRANSPORT A light source without hardware: records calls, scripts faults.
%
%   t = doric.transport.SimulatedTransport()
%   t = doric.transport.SimulatedTransport('Devices', struct('Port', 5, 'Name', 'LEDFLS_465_465'), ...
%                                          'LatencyMs', 0, 'HonourWaits', false)
%
%   Behaves like doric_bridge.exe --simulate: the same replies, the same library strings for
%   "not initialized" and "Device not found", STOPALL without a port stops every opened port, and
%   closing an open transport runs the bridge's stdin-EOF safety path (stop all, close, quit).
%   Works on any OS. Use it in tests, emulators (e.g. Bpod emulator mode) and demos.
%
%   Properties
%       Devices      struct array (Port, Name) reported by LIST and accepted by OPEN
%       LatencyMs    delay before a reply becomes visible to poll (default 0)
%       HonourWaits  also delay INIT/LIST/OPEN/CLOSE replies by their waitms (default false)
%       Calls        (read-only) struct array: Time, Id, Command, Args, Implicit. Args are the
%                    protocol arguments (0-based ch); SETTINGS args hold the ChannelSettings
%                    object in Args.Settings. Implicit marks calls made by the EOF safety path.
%       Device       (read-only) simulated device state per port:
%                    struct array Port, Open, Channels(1..2) with Settings, CurrentmA, Running
%       IsInitialised, OpenPorts (read-only)
%
%   Fault injection
%       failNext(command, text)   next <command> emits text as library output; error-like text
%                                 makes the reply ERR libraryError
%       hangNext(command)         next <command> never gets a reply (timeout tests)
%       crash(exitCode)           the "process" exits; poll reports Kind 'exit'
%       emitLibraryMessage(text)  unsolicited library text
%       clearCalls()              empty the Calls log
%       calls = callsOf(command)  Calls entries for one command
%
%   See also doric.transport.Transport, doric.transport.BridgeTransport, doric.LightSource

    properties
        Devices = struct('Port', 5, 'Name', 'LEDFLS_465_465')
        LatencyMs = 0
        HonourWaits = false
    end

    properties (SetAccess = private)
        Calls = struct('Time', {}, 'Id', {}, 'Command', {}, 'Args', {}, 'Implicit', {})
        Device = struct('Port', {}, 'Open', {}, 'Channels', {})
        IsInitialised = false
        OpenPorts = zeros(1, 0)
    end

    properties (Access = private)
        Opened = false
        Exited = false
        Outbox           % messages with DueAt
        Failures = struct('Command', {}, 'Text', {})
        Hangs = {}
    end

    methods
        function obj = SimulatedTransport(varargin)
            obj.Outbox = struct('Message', {}, 'DueAt', {});
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k + 1};
            end
        end

        function open(obj)
            obj.Opened = true;
            obj.Exited = false;
            obj.IsInitialised = false;
            obj.OpenPorts = zeros(1, 0);
            ready = doric.transport.Transport.newMessage('event');
            ready.Name = 'READY';
            ready.Data = struct('bridge', 'simulated', 'simulate', '1');
            obj.post(ready, 0);
        end

        function close(obj)
            if obj.Opened && ~obj.Exited
                % Same as the bridge on stdin EOF: light off, release, quit.
                obj.shutdown(true);
                exiting = doric.transport.Transport.newMessage('event');
                exiting.Name = 'EXITING';
                exiting.Data = struct('reason', 'stdinClosed');
                obj.post(exiting, 0);
            end
            obj.Opened = false;
            obj.Exited = false;
        end

        function tf = isOpen(obj)
            tf = obj.Opened && ~obj.Exited;
        end

        function delete(obj)
            try
                obj.close();
            catch
                % delete never throws
            end
        end

        % ---- fault injection ---------------------------------------------------------------

        function failNext(obj, command, text)
            obj.Failures(end + 1) = struct('Command', upper(char(command)), 'Text', char(text));
        end

        function hangNext(obj, command)
            obj.Hangs{end + 1} = upper(char(command));
        end

        function crash(obj, exitCode)
            if nargin < 2, exitCode = 9; end
            obj.Exited = true;
            m = doric.transport.Transport.newMessage('exit');
            m.Code = sprintf('%d', exitCode);
            m.Text = sprintf('Simulated bridge exited with code %d', exitCode);
            obj.post(m, 0);
        end

        function emitLibraryMessage(obj, text)
            obj.postLibrary(0, char(text));
        end

        function clearCalls(obj)
            obj.Calls = obj.Calls([]);
        end

        function calls = callsOf(obj, command)
            calls = obj.Calls(strcmp({obj.Calls.Command}, upper(char(command))));
        end
    end

    methods (Access = protected)
        function sendImpl(obj, id, command, args)
            if ~obj.isOpen()
                error('doric:SimulatedTransport:bridgeExited', ...
                    'The simulated transport is not open.');
            end
            obj.record(id, command, args, false);
            hangIndex = find(strcmp(obj.Hangs, command), 1);
            if ~isempty(hangIndex)
                obj.Hangs(hangIndex) = [];
                return
            end
            [ok, code, text, data, delayMs] = obj.execute(id, command, args);
            failIndex = find(strcmp({obj.Failures.Command}, command), 1);
            if ok && ~isempty(failIndex)
                failure = obj.Failures(failIndex);
                obj.Failures(failIndex) = [];
                severity = obj.postLibrary(id, failure.Text);
                if strcmp(severity, 'error')
                    ok = false;
                    code = 'libraryError';
                    text = failure.Text;
                end
            end
            reply = doric.transport.Transport.newMessage('reply');
            reply.Id = id;
            reply.Ok = ok;
            reply.Code = code;
            reply.Text = text;
            reply.Data = data;
            obj.post(reply, obj.LatencyMs + delayMs);
            if strcmp(command, 'QUIT') && ok
                exiting = doric.transport.Transport.newMessage('event');
                exiting.Name = 'EXITING';
                exiting.Data = struct('reason', 'quit');
                obj.post(exiting, obj.LatencyMs + delayMs);
                obj.Exited = true;
            end
        end

        function messages = readImpl(obj)
            messages = doric.transport.Transport.emptyMessages();
            if isempty(obj.Outbox)
                return
            end
            t = obj.now();
            due = [obj.Outbox.DueAt] <= t;
            if ~any(due)
                return
            end
            messages = [obj.Outbox(due).Message];
            obj.Outbox = obj.Outbox(~due);
            for k = 1:numel(messages)
                messages(k).Time = t;
            end
        end
    end

    methods (Access = private)
        function [ok, code, text, data, delayMs] = execute(obj, id, command, args)
            ok = true;
            code = '';
            text = '';
            data = struct();
            delayMs = 0;
            needsInit = {'LIST', 'OPEN', 'CLOSE', 'START', 'STOP', 'STARTALL', 'CURRENT', ...
                'SETTINGS'};
            if any(strcmp(command, needsInit)) && ~obj.IsInitialised
                [ok, code, text] = deal(false, 'notInitialised', 'send INIT first');
                return
            end
            waitMs = obj.arg(args, 'waitms', 0);
            if obj.HonourWaits
                delayMs = waitMs;
            end
            switch command
                case 'HELLO'
                    data = struct('bridge', 'simulated', 'dll', 'none', 'pid', '0', ...
                        'simulate', '1');
                case 'INIT'
                    if obj.IsInitialised
                        obj.postLibrary(id, 'System already initialized');
                    end
                    obj.IsInitialised = true;
                case 'LIST'
                    if isempty(obj.Devices)
                        obj.postLibrary(id, 'No available device(s)');
                    end
                    for k = 1:numel(obj.Devices)
                        obj.postLibrary(id, sprintf('%s (Port #%d)', obj.Devices(k).Name, ...
                            obj.Devices(k).Port));
                    end
                    data = struct('n', sprintf('%d', numel(obj.Devices)));
                case 'OPEN'
                    port = args.port;
                    if any([obj.Devices.Port] == port)
                        obj.OpenPorts = union(obj.OpenPorts, port);
                        obj.deviceIndex(port);
                        obj.Device([obj.Device.Port] == port).Open = true;
                    else
                        [ok, code, text] = obj.libraryError(id, ...
                            'Unable to connect device... Device not found');
                    end
                case 'CLOSE'
                    if obj.isPortOpen(args.port, id, 'Unable to disconnect device... Device not found')
                        obj.markClosed(args.port);
                    else
                        [ok, code, text] = deal(false, 'libraryError', ...
                            'Unable to disconnect device... Device not found');
                    end
                case {'START', 'STOP'}
                    starting = strcmp(command, 'START');
                    message = sprintf('Unable to %s channel... Device not found', ...
                        lower(command));
                    if obj.isPortOpen(args.port, id, message)
                        k = obj.deviceIndex(args.port);
                        obj.Device(k).Channels(args.ch + 1).Running = starting;
                    else
                        [ok, code, text] = deal(false, 'libraryError', message);
                    end
                case {'STARTALL', 'STOPALL'}
                    starting = strcmp(command, 'STARTALL');
                    if isfield(args, 'port')
                        ports = args.port;
                    else
                        ports = obj.OpenPorts;
                    end
                    if ~obj.IsInitialised
                        ports = zeros(1, 0);
                    end
                    message = sprintf('Unable to %s all... Device not found', ...
                        lower(command(1:end - 3)));
                    for port = ports
                        if obj.isPortOpen(port, id, message)
                            k = obj.deviceIndex(port);
                            for c = 1:numel(obj.Device(k).Channels)
                                obj.Device(k).Channels(c).Running = starting;
                            end
                        else
                            [ok, code, text] = deal(false, 'libraryError', message);
                        end
                    end
                    if ~starting
                        data = struct('ports', sprintf('%d', numel(ports)));
                    end
                case 'CURRENT'
                    message = 'Unable to send current... Device not found';
                    if obj.isPortOpen(args.port, id, message)
                        k = obj.deviceIndex(args.port);
                        obj.Device(k).Channels(args.ch + 1).CurrentmA = args.ma;
                    else
                        [ok, code, text] = deal(false, 'libraryError', message);
                    end
                case 'SETTINGS'
                    message = 'Unable to send settings... Device not found';
                    if obj.isPortOpen(args.port, id, message)
                        k = obj.deviceIndex(args.port);
                        obj.Device(k).Channels(args.ch + 1).Settings = args.Settings;
                        obj.Device(k).Channels(args.ch + 1).CurrentmA = args.Settings.CurrentmA;
                    else
                        [ok, code, text] = deal(false, 'libraryError', message);
                    end
                case 'SIZES'
                    data = struct('settings', '2088', 'ttl', '40', 'complex', '40');
                case 'QUIT'
                    obj.shutdown(false);
                otherwise
                    [ok, code, text] = deal(false, 'unknownCommand', command);
            end
        end

        function tf = isPortOpen(obj, port, id, message)
            tf = any(obj.OpenPorts == port);
            if ~tf
                obj.postLibrary(id, message);
            end
        end

        function [ok, code, text] = libraryError(obj, id, message)
            obj.postLibrary(id, message);
            ok = false;
            code = 'libraryError';
            text = message;
        end

        function k = deviceIndex(obj, port)
            k = find([obj.Device.Port] == port, 1);
            if isempty(k)
                channel = struct('Settings', [], 'CurrentmA', 0, 'Running', false);
                obj.Device(end + 1) = struct('Port', port, 'Open', false, ...
                    'Channels', [channel, channel]);
                k = numel(obj.Device);
            end
        end

        function markClosed(obj, port)
            obj.OpenPorts = setdiff(obj.OpenPorts, port);
            k = obj.deviceIndex(port);
            obj.Device(k).Open = false;
        end

        function shutdown(obj, implicit)
            for port = obj.OpenPorts
                if implicit
                    obj.record(0, 'STOPALL', struct('port', port), true);
                    obj.record(0, 'CLOSE', struct('port', port), true);
                end
                k = obj.deviceIndex(port);
                for c = 1:numel(obj.Device(k).Channels)
                    obj.Device(k).Channels(c).Running = false;
                end
                obj.markClosed(port);
            end
            if obj.IsInitialised && implicit
                obj.record(0, 'QUIT', struct(), true);
            end
            obj.IsInitialised = false;
        end

        function record(obj, id, command, args, implicit)
            obj.Calls(end + 1) = struct('Time', obj.now(), 'Id', id, 'Command', command, ...
                'Args', args, 'Implicit', implicit);
        end

        function severity = postLibrary(obj, id, text)
            m = doric.transport.Transport.newMessage('libmsg');
            m.Id = id;
            m.Source = 'sim';
            m.Text = text;
            m.Severity = doric.transport.MessageClassifier.classify(text);
            severity = m.Severity;
            obj.post(m, obj.LatencyMs);
        end

        function post(obj, message, delayMs)
            obj.Outbox(end + 1) = struct('Message', message, 'DueAt', obj.now() + delayMs / 1000);
        end
    end

    methods (Static, Access = private)
        function value = arg(args, name, default)
            if isfield(args, name)
                value = args.(name);
            else
                value = default;
            end
        end
    end
end
