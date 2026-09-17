classdef LibraryTransport < doric.transport.Transport
%LIBRARYTRANSPORT Fallback transport: DoricSystem.dll loaded into MATLAB with loadlibrary.
%
%   t = doric.transport.LibraryTransport()
%   t = doric.transport.LibraryTransport('DllDir', folder, 'PumpMs', 10)
%
%   **Experimental.** doric.transport.BridgeTransport is the supported transport (decision D1 in
%   docs/architecture.md). This class exists for the case where the bridge cannot be used, and
%   it has never been run against the device (see the pending item in docs/rig-checks.md).
%
%   Known limitations compared with the bridge:
%     * The library's debug text cannot be captured inside MATLAB, so a command is reported as
%       successful whenever the call itself returns. Library errors are invisible: no
%       libraryError replies, no LIBMSG messages, and LIST always reports zero devices.
%     * wait() is pumped only while a command runs, not continuously; each call to the library
%       is followed by one wait(PumpMs).
%     * Complex-mode settings need a pointer to an array of ComplexModulation structs, which
%       loadlibrary cannot build; sending them errors doric:LibraryTransport:unsupported.
%     * A crash inside the DLL (or a Qt/HDF5/FFmpeg clash) takes MATLAB down with it.
%     * If MATLAB is killed, nothing switches the light off.
%
%   Errors
%       doric:LibraryTransport:notWindows, :vendorDllNotFound, :loadFailed, :unsupported,
%       :notOpen
%
%   See also doric.transport.BridgeTransport, doric.transport.Transport, docs/vendor-dll.md

    properties
        DllDir = ''
        PumpMs = 10
        Debugger = true
        LibraryName = 'DoricSystem'
    end

    properties (Access = private)
        Loaded = false
        OpenPorts = zeros(1, 0)
        Initialised = false
        Outbox
    end

    methods
        function obj = LibraryTransport(varargin)
            obj.DllDir = doric.config().DllDir;
            obj.Outbox = doric.transport.Transport.emptyMessages();
            valid = properties(obj);
            for k = 1:2:numel(varargin)
                match = strcmpi(valid, char(varargin{k}));
                if ~any(match)
                    error('doric:LibraryTransport:invalidOption', 'Unknown option "%s".', ...
                        char(varargin{k}));
                end
                obj.(valid{match}) = varargin{k + 1};
            end
        end

        function open(obj)
            if obj.Loaded
                return
            end
            if ~ispc
                error('doric:LibraryTransport:notWindows', 'DoricSystem.dll is Windows only.');
            end
            dllPath = fullfile(obj.DllDir, [obj.LibraryName '.dll']);
            if ~isfile(dllPath)
                error('doric:LibraryTransport:vendorDllNotFound', ...
                    'DoricSystem.dll not found in %s.', obj.DllDir);
            end
            header = fullfile(fileparts(mfilename('fullpath')), 'private', 'doric_flat.h');
            previousDir = getenv('PATH');
            restore = onCleanup(@() setenv('PATH', previousDir));
            setenv('PATH', [obj.DllDir ';' previousDir]);   % let Qt and friends resolve
            if ~libisloaded(obj.LibraryName)
                try
                    loadlibrary(dllPath, header, 'alias', obj.LibraryName);
                catch err
                    error('doric:LibraryTransport:loadFailed', ...
                        'loadlibrary failed for %s: %s', dllPath, err.message);
                end
            end
            obj.Loaded = true;
            clear restore
            ready = doric.transport.Transport.newMessage('event');
            ready.Name = 'READY';
            ready.Data = struct('bridge', 'loadlibrary', 'simulate', '0');
            ready.Time = obj.now();
            obj.Outbox(end + 1) = ready;
        end

        function close(obj)
            if ~obj.Loaded
                return
            end
            try
                for port = obj.OpenPorts
                    calllib(obj.LibraryName, 'ls_stop_all', port);
                    calllib(obj.LibraryName, 'wait', obj.PumpMs);
                    calllib(obj.LibraryName, 'close_device', port);
                end
                if obj.Initialised
                    calllib(obj.LibraryName, 'wait', 500);
                    calllib(obj.LibraryName, 'quit');
                end
            catch err
                warning('doric:LibraryTransport:teardownFailed', '%s', err.message);
            end
            obj.OpenPorts = zeros(1, 0);
            obj.Initialised = false;
            obj.Loaded = false;
            if libisloaded(obj.LibraryName)
                unloadlibrary(obj.LibraryName);
            end
        end

        function tf = isOpen(obj)
            tf = obj.Loaded && libisloaded(obj.LibraryName);
        end

        function delete(obj)
            try
                obj.close();
            catch
            end
        end
    end

    methods (Access = protected)
        function sendImpl(obj, id, command, args)
            if ~obj.isOpen() && ~strcmp(command, 'HELLO')
                error('doric:LibraryTransport:notOpen', 'The library is not loaded; call open.');
            end
            reply = doric.transport.Transport.newMessage('reply');
            reply.Id = id;
            reply.Ok = true;
            try
                reply.Data = obj.execute(command, args);
            catch err
                reply.Ok = false;
                reply.Code = 'libraryError';
                reply.Text = err.message;
            end
            reply.Time = obj.now();
            obj.Outbox(end + 1) = reply;
        end

        function messages = readImpl(obj)
            messages = obj.Outbox;
            obj.Outbox = doric.transport.Transport.emptyMessages();
        end
    end

    methods (Access = private)
        function data = execute(obj, command, args)
            data = struct();
            name = obj.LibraryName;
            switch command
                case 'HELLO'
                    data = struct('bridge', 'loadlibrary', 'dll', ...
                        fullfile(obj.DllDir, [obj.LibraryName '.dll']), 'simulate', '0');
                case 'INIT'
                    calllib(name, 'init', uint8(obj.Debugger));
                    obj.Initialised = true;
                    obj.pump(obj.field(args, 'waitms', 5000));
                case 'LIST'
                    calllib(name, 'available_devices_with_ports');
                    obj.pump(obj.field(args, 'waitms', 500));
                    data = struct('n', '0');   % the printed listing cannot be read in-process
                case 'OPEN'
                    calllib(name, 'open_device', args.port);
                    obj.pump(obj.field(args, 'waitms', 5000));
                    obj.OpenPorts = union(obj.OpenPorts, args.port);
                case 'CLOSE'
                    calllib(name, 'close_device', args.port);
                    obj.pump(obj.field(args, 'waitms', 1000));
                    obj.OpenPorts = setdiff(obj.OpenPorts, args.port);
                case 'START'
                    obj.call('ls_start_channel', args.port, args.ch);
                case 'STOP'
                    obj.call('ls_stop_channel', args.port, args.ch);
                case 'STARTALL'
                    obj.call('ls_start_all', args.port);
                case 'STOPALL'
                    ports = obj.OpenPorts;
                    if isfield(args, 'port')
                        ports = args.port;
                    end
                    for port = ports
                        obj.call('ls_stop_all', port);
                    end
                    data = struct('ports', sprintf('%d', numel(ports)));
                case 'CURRENT'
                    obj.call('ls_send_current', args.port, args.ch, uint16(args.ma));
                case 'SETTINGS'
                    settings = obj.buildSettings(args.Settings, args.ch);
                    obj.call('ls_send_settings', args.port, settings);
                case 'QUIT'
                    obj.close();
                otherwise
                    error('doric:LibraryTransport:unsupported', 'Unknown command %s.', command);
            end
        end

        function call(obj, fn, varargin)
            calllib(obj.LibraryName, fn, varargin{:});
            calllib(obj.LibraryName, 'wait', obj.PumpMs);
        end

        function pump(obj, waitMs)
            remaining = waitMs;
            while remaining > 0
                slice = min(remaining, 65535);
                calllib(obj.LibraryName, 'wait', slice);
                remaining = remaining - slice;
            end
        end

        function pointer = buildSettings(~, settings, channelIndex0)
            if ~isempty(settings.ComplexSegments)
                error('doric:LibraryTransport:unsupported', ...
                    ['Complex-mode segments need a pointer to an array of structs, which ' ...
                    'loadlibrary cannot build. Use doric.transport.BridgeTransport.']);
            end
            pointer = libstruct('DoricLightSourceSettings');
            pointer.channelIdx = int32(channelIndex0);
            pointer.mode = int32(settings.Mode);
            pointer.isTTLOutput = uint8(settings.IsTTLOutput);
            pointer.triggerType = int32(settings.TriggerType);
            pointer.triggerMode = int32(settings.TriggerMode);
            pointer.isRepeatableSequence = uint8(settings.IsRepeatableSequence);
            pointer.currentMode = int32(settings.CurrentMode);
            points = zeros(1, 1000, 'uint16');
            points(1:numel(settings.CustomDataPoints)) = uint16(settings.CustomDataPoints);
            pointer.customDataPoint = points;
            ttl = libstruct('DoricTTLModulation');
            ttl.current = uint16(settings.CurrentmA);
            ttl.startingDelayMs = uint32(settings.StartingDelayMs);
            ttl.delayBetweenSeqMs = uint32(settings.DelayBetweenSeqMs);
            ttl.periodMs = settings.PeriodMs;
            ttl.timeOnMs = settings.TimeOnMs;
            ttl.risingTimeMs = uint16(settings.RisingTimeMs);
            ttl.fallingTimeMs = uint16(settings.FallingTimeMs);
            ttl.nbOfSeq = uint16(settings.NbOfSeq);
            ttl.nbOfPulsesPerSeq = uint16(settings.NbOfPulsesPerSeq);
            pointer.ttlModulation = ttl;
            pointer.nbComplexModulations = uint8(0);
        end
    end

    methods (Static, Access = private)
        function value = field(args, name, default)
            if isfield(args, name)
                value = args.(name);
            else
                value = default;
            end
        end
    end
end
