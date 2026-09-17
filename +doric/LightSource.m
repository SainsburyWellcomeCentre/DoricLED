classdef LightSource < handle
%LIGHTSOURCE Doric 2-channel LED light source (LEDFLS_465_465): connection, commands, safety.
%
%   ls = doric.LightSource()                    real device via doric_bridge.exe
%   ls = doric.LightSource('Port', 5)           Doric port number (see doric.listDevices)
%   ls = doric.LightSource('Transport', doric.transport.SimulatedTransport())
%   ls = doric.LightSource(..., 'Name', value)  any settable property below
%
%   The constructor never touches hardware; connect does.
%
%   Properties (read-only)
%       State        'Disconnected' | 'Initialising' | 'Opening' | 'Ready' | 'Closing' | 'Faulted'
%       FaultReason  why the object is Faulted, else ''
%       Channels     doric.Channel 1x2
%       Transport    the doric.transport.Transport in use
%       DeviceName   name from the device listing, when known
%       Devices      table (Port, Name) of the last listing
%
%   Properties (settable)
%       Port              Doric port; [] = the only listed device (settable when not connected)
%       SettleMs          confirmation window per command (default 100; 0 = ack only)
%       CommandTimeoutMs  extra time allowed for a command's reply (default 2000)
%       InitWaitMs, ListWaitMs, OpenWaitMs, CloseWaitMs   library waits (5000, 500, 5000, 1000)
%       ConnectTimeoutMs  extra time allowed for init/open replies (default 30000)
%       Debugger          init(debuggerActive) flag (default true)
%       AutoPoll          poll the transport from a timer while connected (default true)
%       PollPeriodMs      timer period (default 20)
%       Verbose           print state changes and library text (default false)
%       LogCapacity       entries kept by log() (default 1000)
%
%   Methods
%       result = connect(...)       init -> list -> open -> stop all. 'Wait' (true), 'OnDone' fn
%       disconnect()                stop all -> close -> quit. Idempotent, never throws
%       result = reconnect(...)     disconnect, then connect
%       result = stopAll(...)       emergency stop; allowed in every state
%       result = startAll(...)      ls_start_all
%       results = apply(s1, s2, ...) send settings to channel 1 and 2 ([] skips a channel)
%       devices = listDevices()     table(Port, Name); temporary init/quit when not connected
%       poll()                      process pending replies and messages now
%       s = record()                plain struct for data files
%       t = log()                   table of recent commands, library text and state changes
%       t = stats()                 latency summary per command
%       saveConfig(file) / loadConfig(file)   JSON of both channels' settings and limits
%   Command options: 'Wait' (default true), 'SettleMs', 'OnDone' (fn(result)).
%
%   Events (event data doric.DoricEventData)
%       StateChanged, CommandCompleted, LibraryMessage, Faulted
%
%   Errors
%       doric:LightSource:notReady       command needs state Ready
%       doric:LightSource:busy           connect/list while connecting or closing
%       doric:LightSource:deviceNotFound port not listed or the library cannot find it
%       doric:LightSource:portRequired   several devices listed and Port is empty
%       doric:LightSource:timeout        no reply in time (the object becomes Faulted)
%       doric:LightSource:bridgeExited   the bridge process ended
%       doric:LightSource:libraryError   the library printed an error for the command
%       doric:LightSource:portLocked     Port changed while connected
%       Transport errors from open (e.g. doric:BridgeTransport:bridgeNotFound) pass through.
%
%   Example
%       ls = doric.LightSource('Transport', doric.transport.SimulatedTransport());
%       ls.connect();
%       ls.Channels(1).apply(doric.ChannelSettings.cw(100));
%       ls.Channels(1).start();
%       ls.disconnect();
%
%   See also doric.Channel, doric.ChannelSettings, doric.listDevices, doric.gui.LightSourceApp

    properties (SetAccess = private)
        State = 'Disconnected'
        FaultReason = ''
        Channels
        Transport
        DeviceName = ''
        Devices = table(zeros(0, 1), strings(0, 1), 'VariableNames', {'Port', 'Name'})
    end

    properties (Dependent)
        Port
    end

    properties
        SettleMs = 100
        CommandTimeoutMs = 2000
        InitWaitMs = 5000
        ListWaitMs = 500
        OpenWaitMs = 5000
        CloseWaitMs = 1000
        ConnectTimeoutMs = 30000
        Debugger = true
        AutoPoll = true
        PollPeriodMs = 20
        Verbose = false
        LogCapacity = 1000
    end

    events
        StateChanged
        CommandCompleted
        LibraryMessage
        Faulted
    end

    properties (Access = private)
        PortValue = []
        OwnsTransport = false
        Pending            % containers.Map id -> entry
        Results            % containers.Map id -> result, for blocking waiters
        LogEntries
        LatencyMs = struct()
        FailureCounts = struct()
        PollTimer = []
        DeviceOpen = false
        Initialised = false
        Generation = 0     % bumps on connect/teardown; stale continuations are ignored
        BusyDepth = 0      % > 0 while poll/submit run; the timer then skips its tick
        ConnectOutcome = []
        ConnectOnDone = []
        ClockStart
        ClockEpoch
    end

    methods
        function obj = LightSource(varargin)
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.Results = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.LogEntries = doric.LightSource.emptyLog();
            obj.ClockStart = tic;
            obj.ClockEpoch = datetime('now');
            if mod(numel(varargin), 2) ~= 0
                error('doric:LightSource:invalidOption', 'Options must be name-value pairs.');
            end
            transport = [];
            settable = [{'Port', 'Transport'}, obj.settableNames()];
            for k = 1:2:numel(varargin)
                match = strcmpi(settable, char(varargin{k}));
                if ~any(match)
                    error('doric:LightSource:invalidOption', 'Unknown option "%s". Valid: %s.', ...
                        char(varargin{k}), strjoin(settable, ', '));
                end
                name = settable{match};
                if strcmp(name, 'Transport')
                    transport = varargin{k + 1};
                else
                    obj.(name) = varargin{k + 1};
                end
            end
            if isempty(transport)
                transport = doric.transport.BridgeTransport();
                obj.OwnsTransport = true;
            elseif ~isa(transport, 'doric.transport.Transport')
                error('doric:LightSource:invalidOption', ...
                    'Transport must be a doric.transport.Transport.');
            end
            obj.Transport = transport;
            obj.Channels = [doric.Channel(obj, 1), doric.Channel(obj, 2)];
        end

        function delete(obj)
            try
                obj.disconnect();
            catch
                % delete never throws
            end
            obj.stopTimer();
            if obj.OwnsTransport && ~isempty(obj.Transport) && isvalid(obj.Transport)
                try
                    delete(obj.Transport);
                catch
                end
            end
        end

        % ---- properties --------------------------------------------------------------------

        function value = get.Port(obj)
            value = obj.PortValue;
        end

        function set.Port(obj, value)
            if ~any(strcmp(obj.State, {'Disconnected', 'Faulted'}))
                error('doric:LightSource:portLocked', ...
                    'Port can only change while disconnected (state is %s).', obj.State);
            end
            if ~isempty(value) && (~isnumeric(value) || ~isscalar(value) || value < 0 || ...
                    value ~= fix(value) || ~isfinite(value))
                error('doric:LightSource:invalidOption', 'Port must be [] or an integer >= 0.');
            end
            obj.PortValue = double(value);
        end

        function set.SettleMs(obj, value)
            obj.SettleMs = doric.LightSource.checkMs(value, 'SettleMs', 60000);
        end

        function set.CommandTimeoutMs(obj, value)
            obj.CommandTimeoutMs = doric.LightSource.checkMs(value, 'CommandTimeoutMs', Inf);
        end

        function set.InitWaitMs(obj, value)
            obj.InitWaitMs = doric.LightSource.checkMs(value, 'InitWaitMs', 600000);
        end

        function set.ListWaitMs(obj, value)
            obj.ListWaitMs = doric.LightSource.checkMs(value, 'ListWaitMs', 600000);
        end

        function set.OpenWaitMs(obj, value)
            obj.OpenWaitMs = doric.LightSource.checkMs(value, 'OpenWaitMs', 600000);
        end

        function set.CloseWaitMs(obj, value)
            obj.CloseWaitMs = doric.LightSource.checkMs(value, 'CloseWaitMs', 600000);
        end

        function set.ConnectTimeoutMs(obj, value)
            obj.ConnectTimeoutMs = doric.LightSource.checkMs(value, 'ConnectTimeoutMs', Inf);
        end

        function set.PollPeriodMs(obj, value)
            value = doric.LightSource.checkMs(value, 'PollPeriodMs', 10000);
            if value < 1
                error('doric:LightSource:invalidOption', 'PollPeriodMs must be >= 1.');
            end
            obj.PollPeriodMs = value;
        end

        function set.LogCapacity(obj, value)
            obj.LogCapacity = doric.LightSource.checkMs(value, 'LogCapacity', Inf);
        end

        function set.Verbose(obj, value)
            obj.Verbose = logical(value);
        end

        function set.Debugger(obj, value)
            obj.Debugger = logical(value);
        end

        function set.AutoPoll(obj, value)
            obj.AutoPoll = logical(value);
        end

        % ---- connection --------------------------------------------------------------------

        function result = connect(obj, varargin)
        %CONNECT Start the transport, init the library, list devices, open the port, stop all.
        %   result = connect('Wait', true|false, 'OnDone', fn)
        %   Blocking by default. With 'Wait', false it returns at once; fn(result) runs when the
        %   device is Ready or the attempt failed. A failure after the transport started rolls
        %   back (stop, close, quit) and leaves the object Faulted with FaultReason.
            opts = commandOptions(struct('Wait', true, 'OnDone', []), varargin, 'LightSource');
            switch obj.State
                case 'Ready'
                    result = obj.connectResult(true, '', 'Already connected');
                    obj.callOnDone(opts.OnDone, result);
                    return
                case {'Initialising', 'Opening', 'Closing'}
                    error('doric:LightSource:busy', 'Cannot connect while %s.', obj.State);
                case 'Faulted'
                    obj.disconnect();
            end
            obj.Generation = obj.Generation + 1;
            generation = obj.Generation;
            obj.ConnectOutcome = [];
            obj.ConnectOnDone = opts.OnDone;
            obj.DeviceName = '';
            for k = 1:numel(obj.Channels)
                obj.Channels(k).resetCommanded();
            end
            try
                obj.Transport.open();
            catch err
                obj.addLog('error', 'error', 'OPEN', [], [], [], NaN, err.message);
                rethrow(err);
            end
            obj.startTimer();
            obj.setState('Initialising', 'connect');
            obj.submitInternal('INIT', ...
                @() obj.Transport.init(obj.Debugger, obj.InitWaitMs, obj.SettleMs), ...
                obj.InitWaitMs + obj.SettleMs + obj.ConnectTimeoutMs, ...
                @(r) obj.onInitDone(r, generation));
            if opts.Wait
                while isempty(obj.ConnectOutcome) && obj.Generation == generation
                    obj.poll();
                    pause(0.002);
                end
                outcome = obj.ConnectOutcome;
                if isempty(outcome)
                    error('doric:LightSource:cancelled', 'connect was cancelled.');
                end
                if ~outcome.Ok
                    error(['doric:LightSource:' outcome.Code], '%s', outcome.Message);
                end
                result = outcome;
            else
                result = obj.connectResult([], '', 'Connecting');
            end
        end

        function disconnect(obj)
        %DISCONNECT Stop all, close the device, quit the library, stop the transport.
        %   Idempotent and never throws; teardown problems become warnings.
            try
                transportOpen = ~isempty(obj.Transport) && isvalid(obj.Transport) && ...
                    obj.Transport.isOpen();
                if strcmp(obj.State, 'Disconnected') && ~transportOpen
                    return
                end
                wasFaulted = strcmp(obj.State, 'Faulted');
                obj.setState('Closing', 'disconnect');
                obj.teardown(wasFaulted);
                obj.FaultReason = '';
                obj.setState('Disconnected', 'disconnect');
            catch err
                warning('doric:LightSource:teardownFailed', 'disconnect: %s', err.message);
                obj.State = 'Disconnected';
            end
        end

        function result = reconnect(obj, varargin)
        %RECONNECT disconnect, then connect with the same options as connect.
            obj.disconnect();
            result = obj.connect(varargin{:});
        end

        % ---- commands ----------------------------------------------------------------------

        function result = stopAll(obj, varargin)
        %STOPALL Stop every channel. Allowed in every state. Without an open transport there is
        %   nothing to stop and the call returns Ok. Before the device is open the bridge stops
        %   every port it opened.
            opts = obj.commandOpts(varargin);
            t = obj.Transport;
            if isempty(t) || ~isvalid(t) || ~t.isOpen()
                result = obj.localResult('STOPALL', true, 'Nothing open');
                obj.callOnDone(opts.OnDone, result);
                return
            end
            port = [];
            if obj.DeviceOpen
                port = obj.PortValue;
            end
            settle = obj.settleFor(opts);
            result = obj.submit('STOPALL', @() t.stopAll(port, settle), opts, [], ...
                settle + obj.CommandTimeoutMs, @(r) obj.markAllStopped());
        end

        function result = startAll(obj, varargin)
        %STARTALL Start every configured channel (ls_start_all).
            opts = obj.commandOpts(varargin);
            obj.requireReady();
            settle = obj.settleFor(opts);
            t = obj.Transport;
            port = obj.PortValue;
            result = obj.submit('STARTALL', @() t.startAll(port, settle), opts, [], ...
                settle + obj.CommandTimeoutMs, @(r) obj.markAllStarted());
        end

        function results = apply(obj, settings1, settings2, varargin)
        %APPLY Send settings to both channels; [] skips a channel. Options as Channel/apply.
            if nargin < 3
                settings2 = [];
            end
            given = {settings1, settings2};
            results = cell(1, 2);
            for k = 1:2
                if ~isempty(given{k})
                    results{k} = obj.Channels(k).apply(given{k}, varargin{:});
                end
            end
        end

        function devices = listDevices(obj)
        %LISTDEVICES Device listing as table(Port, Name).
        %   When Ready, re-lists through the open connection. When disconnected, starts the
        %   transport, inits, lists, quits and stops the transport; no device is opened.
            switch obj.State
                case 'Ready'
                    result = obj.submitBlocking('LIST', ...
                        @() obj.Transport.listDevices(obj.ListWaitMs, obj.SettleMs), ...
                        obj.ListWaitMs + obj.SettleMs + obj.CommandTimeoutMs);
                    obj.throwIfFailed(result, 'LightSource');
                    devices = doric.LightSource.parseDevices(result.LibraryText);
                    obj.Devices = devices;
                    return
                case {'Initialising', 'Opening', 'Closing'}
                    error('doric:LightSource:busy', 'Cannot list devices while %s.', obj.State);
                case 'Faulted'
                    obj.disconnect();
            end
            obj.Transport.open();
            cleanup = onCleanup(@() obj.endScan());
            obj.setState('Initialising', 'listDevices');
            result = obj.submitBlocking('INIT', ...
                @() obj.Transport.init(obj.Debugger, obj.InitWaitMs, obj.SettleMs), ...
                obj.InitWaitMs + obj.SettleMs + obj.ConnectTimeoutMs);
            obj.throwIfFailed(result, 'LightSource');
            obj.Initialised = true;
            result = obj.submitBlocking('LIST', ...
                @() obj.Transport.listDevices(obj.ListWaitMs, obj.SettleMs), ...
                obj.ListWaitMs + obj.SettleMs + obj.CommandTimeoutMs);
            obj.throwIfFailed(result, 'LightSource');
            devices = doric.LightSource.parseDevices(result.LibraryText);
            obj.Devices = devices;
            clear cleanup
        end

        function poll(obj)
        %POLL Process replies, library text and events that have arrived. Never blocks.
        %   Called by the AutoPoll timer and by blocking commands; hosts that disable AutoPoll
        %   call it from their own loop.
            t = obj.Transport;
            if isempty(t) || ~isvalid(t)
                return
            end
            obj.BusyDepth = obj.BusyDepth + 1;
            try
                try
                    messages = t.poll();
                catch err
                    obj.addLog('error', 'error', '', [], [], [], NaN, ['poll: ' err.message]);
                    messages = [];
                end
                for k = 1:numel(messages)
                    obj.handleMessage(messages(k));
                end
                obj.checkTimeouts();
            catch err
                obj.BusyDepth = obj.BusyDepth - 1;
                rethrow(err);
            end
            obj.BusyDepth = obj.BusyDepth - 1;
        end

        % ---- records -----------------------------------------------------------------------

        function s = record(obj)
        %RECORD Plain struct describing the session, for data files (no objects inside).
            s = struct();
            s.Package = 'doric';
            s.Version = doric.version();
            s.RecordedAt = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSS'));
            s.State = obj.State;
            s.FaultReason = obj.FaultReason;
            s.Port = obj.PortValue;
            s.DeviceName = obj.DeviceName;
            s.Transport = class(obj.Transport);
            s.Bridge = struct();
            if isa(obj.Transport, 'doric.transport.BridgeTransport')
                s.Bridge = struct('Version', obj.Transport.BridgeVersion, ...
                    'DllPath', obj.Transport.DllPath, 'Simulate', obj.Transport.Simulate);
            end
            s.SettleMs = obj.SettleMs;
            channels = struct('Index', {}, 'MaxCurrentmA', {}, 'CommandedSettings', {}, ...
                'CommandedCurrentmA', {}, 'IsRunning', {}, 'CommandedState', {}, ...
                'PendingSettings', {});
            for k = 1:numel(obj.Channels)
                ch = obj.Channels(k);
                commanded = [];
                if ~isempty(ch.CommandedSettings)
                    commanded = ch.CommandedSettings.toStruct();
                end
                channels(k) = struct('Index', ch.Index, 'MaxCurrentmA', ch.MaxCurrentmA, ...
                    'CommandedSettings', commanded, 'CommandedCurrentmA', ch.CommandedCurrentmA, ...
                    'IsRunning', ch.IsRunning, 'CommandedState', ch.CommandedState, ...
                    'PendingSettings', ch.Settings.toStruct());
            end
            s.Channels = channels;
            s.Stats = table2struct(obj.stats());
            entries = obj.LogEntries;
            times = obj.ClockEpoch + seconds([entries.Time]);
            times.Format = 'yyyy-MM-dd''T''HH:mm:ss.SSS';
            timeText = cellstr(char(times));
            for k = 1:numel(entries)
                entries(k).Time = timeText{k};
            end
            s.Log = entries;
        end

        function t = log(obj)
        %LOG Table of recent log entries (oldest first).
            entries = obj.LogEntries;
            t = table('Size', [numel(entries), 9], ...
                'VariableTypes', {'datetime', 'string', 'string', 'string', 'double', ...
                'double', 'double', 'double', 'string'}, ...
                'VariableNames', {'Time', 'Kind', 'Severity', 'Command', 'Channel', 'Id', ...
                'Ok', 'LatencyMs', 'Text'});
            if isempty(entries)
                return
            end
            t.Time = reshape(obj.ClockEpoch + seconds([entries.Time]), [], 1);
            t.Kind = string({entries.Kind})';
            t.Severity = string({entries.Severity})';
            t.Command = string({entries.Command})';
            t.Channel = doric.LightSource.column(entries, 'Channel');
            t.Id = doric.LightSource.column(entries, 'Id');
            t.Ok = doric.LightSource.column(entries, 'Ok');
            t.LatencyMs = [entries.LatencyMs]';
            t.Text = string({entries.Text})';
        end

        function t = stats(obj)
        %STATS Latency (send to reply, ms) per command: Count, Failures, Mean, Median, P95, Max.
            names = union(fieldnames(obj.LatencyMs), fieldnames(obj.FailureCounts));
            n = numel(names);
            [count, failures, meanMs, medianMs, p95Ms, maxMs] = deal(zeros(n, 1));
            for k = 1:n
                values = [];
                if isfield(obj.LatencyMs, names{k})
                    values = obj.LatencyMs.(names{k});
                end
                if isfield(obj.FailureCounts, names{k})
                    failures(k) = obj.FailureCounts.(names{k});
                end
                count(k) = numel(values);
                if isempty(values)
                    [meanMs(k), medianMs(k), p95Ms(k), maxMs(k)] = deal(NaN);
                else
                    sorted = sort(values);
                    meanMs(k) = mean(sorted);
                    medianMs(k) = median(sorted);
                    p95Ms(k) = sorted(max(1, ceil(0.95 * numel(sorted))));
                    maxMs(k) = sorted(end);
                end
            end
            t = table(string(names(:)), count, failures, meanMs, medianMs, p95Ms, maxMs, ...
                'VariableNames', {'Command', 'Count', 'Failures', 'MeanMs', 'MedianMs', ...
                'P95Ms', 'MaxMs'});
        end

        function saveConfig(obj, file)
        %SAVECONFIG Write both channels' pending settings and limits to a JSON file.
            config = struct('Package', 'doric', 'Version', doric.version(), 'Channels', {{}});
            for k = 1:numel(obj.Channels)
                s = obj.Channels(k).Settings.toStruct();
                s.ComplexSegments = num2cell(s.ComplexSegments);
                s.CustomDataPoints = num2cell(s.CustomDataPoints);
                config.Channels{k} = struct('Index', k, ...
                    'MaxCurrentmA', obj.Channels(k).MaxCurrentmA, 'Settings', s);
            end
            text = jsonencode(config, 'PrettyPrint', true);
            fid = fopen(file, 'w', 'n', 'UTF-8');
            if fid < 0
                error('doric:LightSource:fileError', 'Cannot write %s.', file);
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, text, 'char');
            clear closer
        end

        function loadConfig(obj, file)
        %LOADCONFIG Set pending settings and limits from a saveConfig file. Sends nothing.
        %   Everything is validated before anything changes. A limit below a channel's commanded
        %   current is refused (doric:Channel:limitBelowCommanded).
            if ~isfile(file)
                error('doric:LightSource:fileError', 'File not found: %s.', file);
            end
            config = jsondecode(fileread(file));
            if ~isfield(config, 'Channels')
                error('doric:LightSource:invalidConfig', 'No Channels in %s.', file);
            end
            entries = config.Channels;
            if iscell(entries)
                entries = [entries{:}];
            end
            settings = cell(1, numel(entries));
            limits = zeros(1, numel(entries));
            indices = zeros(1, numel(entries));
            for k = 1:numel(entries)
                indices(k) = entries(k).Index;
                if ~any(indices(k) == 1:numel(obj.Channels))
                    error('doric:LightSource:invalidConfig', 'Channel index %g is invalid.', ...
                        indices(k));
                end
                settings{k} = doric.ChannelSettings.fromStruct(entries(k).Settings);
                limits(k) = entries(k).MaxCurrentmA;
                commanded = obj.Channels(indices(k)).CommandedCurrentmA;
                if ~isempty(commanded) && commanded > limits(k)
                    error('doric:Channel:limitBelowCommanded', ...
                        'Channel %d: commanded %d mA is above the loaded limit %d mA.', ...
                        indices(k), commanded, limits(k));
                end
            end
            for k = 1:numel(entries)
                obj.Channels(indices(k)).MaxCurrentmA = limits(k);
                obj.Channels(indices(k)).Settings = settings{k};
            end
        end
    end

    % ---- used by doric.Channel -------------------------------------------------------------

    methods (Access = {?doric.Channel})
        function result = channelCommand(obj, index, command, payload, opts, onSuccess)
            obj.requireReady();
            t = obj.Transport;
            port = obj.PortValue;
            settle = obj.settleFor(opts);
            switch command
                case 'SETTINGS'
                    sendFcn = @() t.sendSettings(port, index, payload, settle);
                case 'START'
                    sendFcn = @() t.startChannel(port, index, settle);
                case 'STOP'
                    sendFcn = @() t.stopChannel(port, index, settle);
                case 'CURRENT'
                    sendFcn = @() t.sendCurrent(port, index, payload, settle);
            end
            result = obj.submit(command, sendFcn, opts, index, settle + obj.CommandTimeoutMs, ...
                onSuccess);
        end
    end

    methods (Access = private)
        % ---- request machinery -------------------------------------------------------------

        function result = submit(obj, command, sendFcn, opts, channel, timeoutMs, onSuccess, ...
                continuation)
            if nargin < 8
                continuation = [];
            end
            component = 'LightSource';
            if isfield(opts, 'Component')
                component = opts.Component;
            end
            obj.BusyDepth = obj.BusyDepth + 1;
            try
                id = sendFcn();
            catch err
                obj.BusyDepth = obj.BusyDepth - 1;
                obj.addLog('command', 'error', command, channel, [], false, NaN, err.message);
                obj.poll();  % surfaces an exit message, if that is why sending failed
                error(['doric:' component ':bridgeExited'], '%s failed to send: %s', command, ...
                    err.message);
            end
            entry = struct('Id', id, 'Command', command, 'Channel', channel, ...
                'Component', component, 'SentAt', obj.clock(), 'TimeoutMs', timeoutMs, ...
                'OnSuccess', onSuccess, 'OnDone', opts.OnDone, 'Continuation', continuation, ...
                'Wait', logical(opts.Wait), 'LibraryText', {{}});
            obj.Pending(id) = entry;
            obj.BusyDepth = obj.BusyDepth - 1;
            if opts.Wait
                result = obj.waitFor(id);
                obj.throwIfFailed(result, component);
            else
                result = struct('Id', id, 'Command', command, 'Channel', channel, 'Ok', [], ...
                    'Code', '', 'Message', 'pending', 'LatencyMs', NaN, 'Data', struct(), ...
                    'LibraryText', {{}});
            end
        end

        function submitInternal(obj, command, sendFcn, timeoutMs, continuation)
        %SUBMITINTERNAL Non-blocking request whose outcome feeds a continuation.
            opts = struct('Wait', false, 'OnDone', [], 'Component', 'LightSource');
            try
                obj.submit(command, sendFcn, opts, [], timeoutMs, [], continuation);
            catch err
                continuation(struct('Id', 0, 'Command', command, 'Channel', [], 'Ok', false, ...
                    'Code', 'bridgeExited', 'Message', err.message, 'LatencyMs', NaN, ...
                    'Data', struct(), 'LibraryText', {{}}));
            end
        end

        function result = submitBlocking(obj, command, sendFcn, timeoutMs)
        %SUBMITBLOCKING Blocking request that returns the result instead of throwing.
            opts = struct('Wait', false, 'OnDone', [], 'Component', 'LightSource');
            try
                pending = obj.submit(command, sendFcn, opts, [], timeoutMs, []);
            catch err
                result = struct('Id', 0, 'Command', command, 'Channel', [], 'Ok', false, ...
                    'Code', 'bridgeExited', 'Message', err.message, 'LatencyMs', NaN, ...
                    'Data', struct(), 'LibraryText', {{}});
                return
            end
            entry = obj.Pending(pending.Id);
            entry.Wait = true;
            obj.Pending(pending.Id) = entry;
            result = obj.waitFor(pending.Id);
        end

        function result = waitFor(obj, id)
            while true
                if isKey(obj.Results, id)
                    result = obj.Results(id);
                    remove(obj.Results, id);
                    return
                end
                obj.poll();
                if isKey(obj.Results, id)
                    continue
                end
                if ~isKey(obj.Pending, id)
                    % Completed without a waiter record (should not happen): report cancelled.
                    result = struct('Id', id, 'Command', '', 'Channel', [], 'Ok', false, ...
                        'Code', 'cancelled', 'Message', 'Request was cancelled', ...
                        'LatencyMs', NaN, 'Data', struct(), 'LibraryText', {{}});
                    return
                end
                pause(0.001);
            end
        end

        function throwIfFailed(~, result, component)
            if isempty(result.Ok) || result.Ok
                return
            end
            code = result.Code;
            if isempty(code)
                code = 'commandFailed';
            end
            channelText = '';
            if ~isempty(result.Channel)
                channelText = sprintf(' (channel %d)', result.Channel);
            end
            error(['doric:' component ':' code], '%s%s failed: %s', result.Command, ...
                channelText, result.Message);
        end

        function handleMessage(obj, m)
            switch m.Kind
                case 'reply'
                    if isKey(obj.Pending, m.Id)
                        obj.complete(obj.Pending(m.Id), m.Ok, m.Code, m.Text, m.LatencyMs, m.Data);
                    else
                        obj.addLog('reply', 'warning', '', [], m.Id, m.Ok, m.LatencyMs, ...
                            ['Unmatched reply: ' m.Code ' ' m.Text]);
                    end
                case 'libmsg'
                    if m.Id ~= 0 && isKey(obj.Pending, m.Id)
                        entry = obj.Pending(m.Id);
                        entry.LibraryText{end + 1} = m.Text;
                        obj.Pending(m.Id) = entry;
                    end
                    obj.addLog('library', m.Severity, '', [], m.Id, [], NaN, m.Text);
                    if obj.Verbose
                        fprintf('[doric] library (%s): %s\n', m.Severity, m.Text);
                    end
                    if event.hasListener(obj, 'LibraryMessage')
                        data = doric.DoricEventData();
                        data.Id = m.Id;
                        data.Text = m.Text;
                        data.Severity = m.Severity;
                        data.LibrarySource = m.Source;
                        notify(obj, 'LibraryMessage', data);
                    end
                case 'event'
                    obj.addLog('event', 'info', m.Name, [], [], [], NaN, m.Text);
                    if strcmp(m.Name, 'FATAL')
                        obj.transportLost(sprintf('Bridge fatal error %s: %s', m.Code, m.Text));
                    end
                case 'exit'
                    obj.addLog('event', 'warning', 'EXIT', [], [], [], NaN, m.Text);
                    obj.transportLost(m.Text);
            end
        end

        function transportLost(obj, reason)
            obj.DeviceOpen = false;
            obj.Initialised = false;
            obj.failAllPending('bridgeExited', reason);
            if ~any(strcmp(obj.State, {'Closing', 'Disconnected'}))
                obj.fault(reason);
            end
        end

        function complete(obj, entry, ok, code, text, latencyMs, data)
            if ~isKey(obj.Pending, entry.Id)
                return
            end
            entry = obj.Pending(entry.Id);
            remove(obj.Pending, entry.Id);
            result = struct('Id', entry.Id, 'Command', entry.Command, 'Channel', entry.Channel, ...
                'Ok', logical(ok), 'Code', code, 'Message', text, 'LatencyMs', latencyMs, ...
                'Data', data, 'LibraryText', {entry.LibraryText});
            if ok && ~isempty(entry.OnSuccess)
                try
                    entry.OnSuccess(result);
                catch err
                    obj.addLog('error', 'error', entry.Command, entry.Channel, entry.Id, [], ...
                        NaN, ['state update failed: ' err.message]);
                end
            end
            obj.recordLatency(entry.Command, ok, latencyMs);
            severity = 'info';
            if ~ok
                severity = 'error';
            end
            obj.addLog('command', severity, entry.Command, entry.Channel, entry.Id, ok, ...
                latencyMs, text);
            if obj.Verbose && ~ok
                fprintf('[doric] %s failed: %s %s\n', entry.Command, code, text);
            end
            if entry.Wait
                obj.Results(entry.Id) = result;
            end
            if event.hasListener(obj, 'CommandCompleted')
                data = doric.DoricEventData();
                data.Id = entry.Id;
                data.Command = entry.Command;
                data.Channel = entry.Channel;
                data.Ok = logical(ok);
                data.Code = code;
                data.Message = text;
                data.LatencyMs = latencyMs;
                notify(obj, 'CommandCompleted', data);
            end
            if ~ok && strcmp(code, 'libraryError') && strcmp(obj.State, 'Ready') && ...
                    doric.transport.MessageClassifier.isDeviceNotFound(text)
                obj.fault(sprintf('%s: %s', entry.Command, text));
            end
            if ~isempty(entry.Continuation)
                entry.Continuation(result);
            end
            obj.callOnDone(entry.OnDone, result);
        end

        function checkTimeouts(obj)
            if obj.Pending.Count == 0
                return
            end
            now_ = obj.clock();
            entries = values(obj.Pending);
            for k = 1:numel(entries)
                entry = entries{k};
                if (now_ - entry.SentAt) * 1000 > entry.TimeoutMs
                    message = sprintf('No reply to %s within %g ms', entry.Command, ...
                        entry.TimeoutMs);
                    obj.complete(entry, false, 'timeout', message, NaN, struct());
                    if ~any(strcmp(obj.State, {'Closing', 'Disconnected', 'Faulted'}))
                        obj.fault(message);
                    end
                end
            end
        end

        function failAllPending(obj, code, message)
            entries = values(obj.Pending);
            for k = 1:numel(entries)
                obj.complete(entries{k}, false, code, message, NaN, struct());
            end
        end

        % ---- connect sequence --------------------------------------------------------------

        function onInitDone(obj, result, generation)
            if generation ~= obj.Generation
                return
            end
            if ~result.Ok
                obj.connectFailed(result.Code, ['init failed: ' result.Message]);
                return
            end
            obj.Initialised = true;
            obj.submitInternal('LIST', ...
                @() obj.Transport.listDevices(obj.ListWaitMs, obj.SettleMs), ...
                obj.ListWaitMs + obj.SettleMs + obj.CommandTimeoutMs, ...
                @(r) obj.onListDone(r, generation));
        end

        function onListDone(obj, result, generation)
            if generation ~= obj.Generation
                return
            end
            if ~result.Ok
                obj.connectFailed(result.Code, ['device listing failed: ' result.Message]);
                return
            end
            devices = doric.LightSource.parseDevices(result.LibraryText);
            obj.Devices = devices;
            port = obj.PortValue;
            if isempty(port)
                if height(devices) == 1
                    port = devices.Port(1);
                    obj.PortValue = port;
                    obj.addLog('event', 'info', 'LIST', [], result.Id, [], NaN, ...
                        sprintf('Port not set; using the only listed device, port %d', port));
                elseif height(devices) == 0
                    obj.connectFailed('deviceNotFound', ['No Doric device listed. ' ...
                        'Check the USB connection and that no other program holds the device.']);
                    return
                else
                    obj.connectFailed('portRequired', sprintf(['Several devices are listed ' ...
                        '(%s); set Port.'], strjoin(compose('%s on port %d', devices.Name, ...
                        devices.Port), ', ')));
                    return
                end
            elseif height(devices) > 0 && ~any(devices.Port == port)
                obj.connectFailed('deviceNotFound', sprintf(['Port %d is not listed. ' ...
                    'Listed: %s.'], port, strjoin(compose('%s on port %d', devices.Name, ...
                    devices.Port), ', ')));
                return
            end
            match = devices.Port == port;
            if any(match)
                obj.DeviceName = char(devices.Name(find(match, 1)));
            end
            obj.setState('Opening', 'connect');
            obj.submitInternal('OPEN', ...
                @() obj.Transport.openDevice(port, obj.OpenWaitMs, obj.SettleMs), ...
                obj.OpenWaitMs + obj.SettleMs + obj.ConnectTimeoutMs, ...
                @(r) obj.onOpenDone(r, generation));
        end

        function onOpenDone(obj, result, generation)
            if generation ~= obj.Generation
                return
            end
            if ~result.Ok
                code = result.Code;
                if doric.transport.MessageClassifier.isDeviceNotFound(result.Message)
                    code = 'deviceNotFound';
                end
                obj.connectFailed(code, sprintf('open_device(%d) failed: %s', obj.PortValue, ...
                    result.Message));
                return
            end
            obj.DeviceOpen = true;
            port = obj.PortValue;
            obj.submitInternal('STOPALL', @() obj.Transport.stopAll(port, obj.SettleMs), ...
                obj.SettleMs + obj.CommandTimeoutMs, @(r) obj.onInitialStopDone(r, generation));
        end

        function onInitialStopDone(obj, result, generation)
            if generation ~= obj.Generation
                return
            end
            if ~result.Ok
                obj.connectFailed(result.Code, ['initial stop all failed: ' result.Message]);
                return
            end
            obj.markAllStopped();
            obj.setState('Ready', 'connect');
            outcome = obj.connectResult(true, '', sprintf('Connected to port %d', obj.PortValue));
            obj.finishConnect(outcome);
        end

        function connectFailed(obj, code, message)
            if isempty(code)
                code = 'connectFailed';
            end
            % Record the outcome first so the rollback does not report the attempt as cancelled.
            outcome = obj.connectResult(false, code, message);
            obj.ConnectOutcome = outcome;
            onDone = obj.ConnectOnDone;
            obj.ConnectOnDone = [];
            try
                obj.teardown(any(strcmp(code, {'timeout', 'bridgeExited'})));
            catch err
                obj.addLog('error', 'error', '', [], [], [], NaN, ['rollback: ' err.message]);
            end
            obj.fault(message);
            obj.callOnDone(onDone, outcome);
        end

        function finishConnect(obj, outcome)
            obj.ConnectOutcome = outcome;
            onDone = obj.ConnectOnDone;
            obj.ConnectOnDone = [];
            obj.callOnDone(onDone, outcome);
        end

        function result = connectResult(~, ok, code, message)
            result = struct('Id', 0, 'Command', 'CONNECT', 'Channel', [], 'Ok', ok, ...
                'Code', code, 'Message', message, 'LatencyMs', NaN, 'Data', struct(), ...
                'LibraryText', {{}});
        end

        % ---- teardown ----------------------------------------------------------------------

        function teardown(obj, quick)
        %TEARDOWN Best-effort stop all, close, quit, transport close. Leaves State alone.
        %   quick shortens the reply timeouts when the transport is suspected unresponsive.
            obj.Generation = obj.Generation + 1;
            if ~isempty(obj.ConnectOnDone) || (isempty(obj.ConnectOutcome) && ...
                    any(strcmp(obj.State, {'Initialising', 'Opening'})))
                obj.finishConnect(obj.connectResult(false, 'cancelled', 'connect was cancelled'));
            end
            t = obj.Transport;
            if ~isempty(t) && isvalid(t) && t.isOpen()
                shortMs = 2000;
                if quick
                    shortMs = 500;
                end
                if obj.DeviceOpen
                    port = obj.PortValue;
                    obj.quietRequest('STOPALL', @() t.stopAll(port, obj.SettleMs), ...
                        obj.SettleMs + shortMs);
                    obj.quietRequest('CLOSE', @() t.closeDevice(port, obj.CloseWaitMs, 0), ...
                        obj.CloseWaitMs + shortMs);
                end
                if obj.Initialised
                    obj.quietRequest('QUIT', @() t.quit(), 3 * shortMs);
                end
                try
                    t.close();
                catch err
                    obj.addLog('error', 'error', '', [], [], [], NaN, ['close: ' err.message]);
                end
            end
            obj.stopTimer();
            obj.failAllPending('cancelled', 'Disconnected');
            obj.DeviceOpen = false;
            obj.Initialised = false;
            obj.markAllStopped();
        end

        function quietRequest(obj, command, sendFcn, timeoutMs)
            result = obj.submitBlocking(command, sendFcn, timeoutMs);
            if ~result.Ok
                obj.addLog('error', 'warning', command, [], result.Id, false, NaN, ...
                    ['teardown: ' result.Message]);
            end
        end

        function endScan(obj)
        %ENDSCAN Finish a disconnected listDevices: quit and close whatever was started.
            try
                t = obj.Transport;
                if t.isOpen()
                    if obj.Initialised
                        obj.quietRequest('QUIT', @() t.quit(), 5000);
                    end
                    t.close();
                end
            catch err
                obj.addLog('error', 'warning', '', [], [], [], NaN, ['scan cleanup: ' err.message]);
            end
            obj.Initialised = false;
            obj.failAllPending('cancelled', 'Scan finished');
            if ~strcmp(obj.State, 'Faulted')
                obj.setState('Disconnected', 'listDevices');
            end
        end

        % ---- state and bookkeeping ---------------------------------------------------------

        function requireReady(obj)
            if ~strcmp(obj.State, 'Ready')
                if strcmp(obj.State, 'Faulted')
                    detail = sprintf(' (%s)', obj.FaultReason);
                else
                    detail = '';
                end
                error('doric:LightSource:notReady', ...
                    'The light source is %s%s; commands need Ready. Call connect() first.', ...
                    obj.State, detail);
            end
        end

        function setState(obj, newState, reason)
            oldState = obj.State;
            if strcmp(oldState, newState)
                return
            end
            obj.State = newState;
            obj.addLog('state', 'info', '', [], [], [], NaN, ...
                sprintf('%s -> %s (%s)', oldState, newState, reason));
            if obj.Verbose
                fprintf('[doric] %s -> %s (%s)\n', oldState, newState, reason);
            end
            if event.hasListener(obj, 'StateChanged')
                data = doric.DoricEventData();
                data.OldState = oldState;
                data.NewState = newState;
                data.Reason = reason;
                notify(obj, 'StateChanged', data);
            end
        end

        function fault(obj, reason)
            if strcmp(obj.State, 'Faulted')
                return
            end
            obj.FaultReason = reason;
            obj.setState('Faulted', reason);
            if event.hasListener(obj, 'Faulted')
                data = doric.DoricEventData();
                data.Reason = reason;
                data.NewState = 'Faulted';
                notify(obj, 'Faulted', data);
            end
        end

        function markAllStopped(obj)
            for k = 1:numel(obj.Channels)
                obj.Channels(k).markStopped();
            end
        end

        function markAllStarted(obj)
            for k = 1:numel(obj.Channels)
                obj.Channels(k).markStartedIfConfigured();
            end
        end

        function opts = commandOpts(~, args)
            opts = commandOptions(struct('Wait', true, 'SettleMs', [], 'OnDone', []), args, ...
                'LightSource');
            opts.Component = 'LightSource';
        end

        function settle = settleFor(obj, opts)
            settle = opts.SettleMs;
            if isempty(settle)
                settle = obj.SettleMs;
            else
                settle = doric.LightSource.checkMs(settle, 'SettleMs', 60000);
            end
        end

        function result = localResult(obj, command, ok, message)
            result = struct('Id', 0, 'Command', command, 'Channel', [], 'Ok', ok, 'Code', '', ...
                'Message', message, 'LatencyMs', NaN, 'Data', struct(), 'LibraryText', {{}});
            obj.addLog('command', 'info', command, [], 0, ok, NaN, message);
        end

        function callOnDone(obj, onDone, result)
            if isempty(onDone)
                return
            end
            try
                onDone(result);
            catch err
                obj.addLog('error', 'error', result.Command, result.Channel, result.Id, [], NaN, ...
                    ['OnDone callback failed: ' err.message]);
                warning('doric:LightSource:callbackFailed', 'OnDone callback failed: %s', ...
                    err.message);
            end
        end

        function t = clock(obj)
            t = toc(obj.ClockStart);
        end

        function addLog(obj, kind, severity, command, channel, id, ok, latencyMs, text)
            entry = struct('Time', obj.clock(), 'Kind', kind, 'Severity', severity, ...
                'Command', command, 'Channel', channel, 'Id', id, 'Ok', ok, ...
                'LatencyMs', latencyMs, 'Text', char(text));
            obj.LogEntries(end + 1) = entry;
            if numel(obj.LogEntries) > 2 * obj.LogCapacity
                obj.LogEntries = obj.LogEntries(end - obj.LogCapacity + 1:end);
            end
        end

        function recordLatency(obj, command, ok, latencyMs)
            if ~ok
                if isfield(obj.FailureCounts, command)
                    obj.FailureCounts.(command) = obj.FailureCounts.(command) + 1;
                else
                    obj.FailureCounts.(command) = 1;
                end
                return
            end
            if ~isfinite(latencyMs)
                return
            end
            if isfield(obj.LatencyMs, command)
                values = obj.LatencyMs.(command);
                if numel(values) >= 10000
                    values = values(end - 4999:end);
                end
                obj.LatencyMs.(command) = [values, latencyMs];
            else
                obj.LatencyMs.(command) = latencyMs;
            end
        end

        function startTimer(obj)
            if ~obj.AutoPoll || (~isempty(obj.PollTimer) && isvalid(obj.PollTimer))
                return
            end
            % A weak reference keeps the timer from holding the object alive.
            ref = matlab.lang.WeakReference(obj);
            obj.PollTimer = timer('Name', 'doric.LightSource poll', ...
                'ExecutionMode', 'fixedSpacing', 'BusyMode', 'drop', ...
                'Period', max(0.001, round(obj.PollPeriodMs) / 1000), ...
                'TimerFcn', @(~, ~) doric.LightSource.timerTick(ref), ...
                'ObjectVisibility', 'off');
            start(obj.PollTimer);
        end

        function stopTimer(obj)
            if ~isempty(obj.PollTimer)
                try
                    if isvalid(obj.PollTimer)
                        stop(obj.PollTimer);
                        delete(obj.PollTimer);
                    end
                catch
                end
                obj.PollTimer = [];
            end
        end

        function names = settableNames(~)
            names = {'SettleMs', 'CommandTimeoutMs', 'InitWaitMs', 'ListWaitMs', 'OpenWaitMs', ...
                'CloseWaitMs', 'ConnectTimeoutMs', 'Debugger', 'AutoPoll', 'PollPeriodMs', ...
                'Verbose', 'LogCapacity'};
        end
    end

    methods (Static, Hidden)
        function devices = parseDevices(lines)
        %PARSEDEVICES table(Port, Name) from library lines of the form "<name> (Port #<n>)".
            ports = zeros(0, 1);
            names = strings(0, 1);
            for k = 1:numel(lines)
                tokens = regexp(lines{k}, '(\S.*?)\s*\(Port #(\d+)\)', 'tokens');
                for m = 1:numel(tokens)
                    port = str2double(tokens{m}{2});
                    if ~any(ports == port)
                        ports(end + 1, 1) = port; %#ok<AGROW>
                        names(end + 1, 1) = string(strtrim(tokens{m}{1})); %#ok<AGROW>
                    end
                end
            end
            devices = table(ports, names, 'VariableNames', {'Port', 'Name'});
        end
    end

    methods (Static, Access = private)
        function timerTick(ref)
            obj = ref.Handle;
            % Timer callbacks can run inside a poll or between sending a request and recording
            % it; skipping the tick keeps message handling strictly ordered.
            if isempty(obj) || ~isvalid(obj) || obj.BusyDepth > 0
                return
            end
            try
                obj.poll();
            catch err
                % A timer callback must never throw (it would stop the timer); keep the reason.
                try
                    obj.addLog('error', 'error', '', [], [], [], NaN, ['poll: ' err.message]);
                catch
                end
            end
        end

        function value = checkMs(value, name, maxValue)
            if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) || isnan(value) || ...
                    value < 0 || value > maxValue
                error('doric:LightSource:invalidOption', '%s must be a number in [0, %g].', ...
                    name, maxValue);
            end
            value = double(value);
        end

        function entries = emptyLog()
            entries = struct('Time', {}, 'Kind', {}, 'Severity', {}, 'Command', {}, ...
                'Channel', {}, 'Id', {}, 'Ok', {}, 'LatencyMs', {}, 'Text', {});
        end

        function values = column(entries, name)
            values = NaN(numel(entries), 1);
            for k = 1:numel(entries)
                if ~isempty(entries(k).(name))
                    values(k) = double(entries(k).(name));
                end
            end
        end
    end
end
