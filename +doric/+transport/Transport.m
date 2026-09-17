classdef (Abstract) Transport < handle
%TRANSPORT Abstract link between doric.LightSource and the vendor library.
%
%   A transport speaks the request/reply model of the bridge protocol
%   (docs/bridge-protocol.md) whether or not a bridge process is involved:
%
%       id = t.send(command, args)   queue a request, return at once with its id
%       msgs = t.poll()              drain replies, library text and events that arrived
%       reply = t.request(command, args, timeoutMs)   blocking convenience
%
%   Primitive methods (all non-blocking, all return the request id). Channels are 1-based here
%   and converted to the vendor's 0-based index in the request arguments. An empty settleMs
%   uses the transport's default settle window.
%       hello()  init(debugger, waitMs)  listDevices(waitMs)  openDevice(port, waitMs)
%       closeDevice(port, waitMs)  startChannel(port, channel)  stopChannel(port, channel)
%       startAll(port)  stopAll(port)  sendSettings(port, channel, settings)
%       sendCurrent(port, channel, currentmA)  sizes()  quit()
%   Each accepts a trailing settleMs argument (except hello, sizes and quit).
%
%   Message struct fields (from poll)
%       Kind       'reply' | 'libmsg' | 'event' | 'exit'
%       Id         request id (0 when not tied to a request)
%       Ok         reply outcome (logical; false for other kinds)
%       Code       error code of an ERR reply, or exit code as text
%       Text       error text, library text or event text
%       Severity   'error' | 'warning' | 'info' for library text
%       Source     where library text came from ('stdio', 'ods', 'raw', 'sim', ...)
%       Name       event name (READY, EXITING, FATAL, SIMCALL, INFO)
%       Data       struct of key=value data (values as char)
%       LatencyMs  send-to-arrival time of a reply, NaN otherwise
%       Time       seconds since the transport was created, at arrival
%
%   Subclasses implement open, close, isOpen, sendImpl and readImpl.
%
%   Events
%       MessageReceived  fired by poll for each message when anyone listens
%                        (event data: doric.DoricEventData with Message set)
%
%   See also doric.transport.BridgeTransport, doric.transport.SimulatedTransport,
%            doric.transport.LibraryTransport, doric.LightSource

    events
        MessageReceived
    end

    properties (SetAccess = protected)
        % Default settle window (ms) the transport applies when a request gives none.
        DefaultSettleMs = 100
    end

    properties (Access = private)
        NextId = 0
        SentAt       % containers.Map id -> send time (s)
        Backlog      % messages read while request() was waiting for another id
        ClockStart
    end

    methods (Abstract)
        open(obj)
        close(obj)
        tf = isOpen(obj)
    end

    methods (Abstract, Access = protected)
        sendImpl(obj, id, command, args)
        messages = readImpl(obj)
    end

    methods
        function obj = Transport()
            obj.SentAt = containers.Map('KeyType', 'double', 'ValueType', 'double');
            obj.Backlog = doric.transport.Transport.emptyMessages();
            obj.ClockStart = tic;
        end

        function id = send(obj, command, args)
        %SEND Queue a request and return its id without waiting.
            if nargin < 3
                args = struct();
            end
            obj.NextId = obj.NextId + 1;
            id = obj.NextId;
            obj.SentAt(id) = obj.now();
            try
                obj.sendImpl(id, upper(char(command)), args);
            catch err
                remove(obj.SentAt, id);
                rethrow(err);
            end
        end

        function messages = poll(obj)
        %POLL Return every message that arrived since the last poll (never blocks).
            messages = [obj.Backlog, obj.readNew()];
            obj.Backlog = doric.transport.Transport.emptyMessages();
        end

        function [reply, others] = request(obj, command, args, timeoutMs)
        %REQUEST Send and wait for the reply (blocking, pause-based).
        %   [reply, others] = request(command, args, timeoutMs)
        %   Messages other than the reply are returned as others and also stay queued for the
        %   next poll. Errors doric:Transport:timeout or doric:Transport:bridgeExited.
            if nargin < 3, args = struct(); end
            if nargin < 4, timeoutMs = 5000; end
            id = obj.send(command, args);
            start = tic;
            others = doric.transport.Transport.emptyMessages();
            while true
                messages = obj.poll();
                match = strcmp({messages.Kind}, 'reply') & [messages.Id] == id;
                others = [others, messages(~match)]; %#ok<AGROW>
                if any(match)
                    reply = messages(find(match, 1));
                    obj.stash(others);
                    return
                end
                if any(strcmp({messages.Kind}, 'exit'))
                    obj.stash(others);
                    error('doric:Transport:bridgeExited', ...
                        'The transport exited while waiting for %s.', upper(char(command)));
                end
                if toc(start) * 1000 > timeoutMs
                    obj.stash(others);
                    error('doric:Transport:timeout', 'No reply to %s within %g ms.', ...
                        upper(char(command)), timeoutMs);
                end
                pause(0.002);
            end
        end

        % ---- primitives --------------------------------------------------------------------

        function id = hello(obj)
            id = obj.send('HELLO', struct());
        end

        function id = sizes(obj)
            id = obj.send('SIZES', struct());
        end

        function id = init(obj, debugger, waitMs, settleMs)
            if nargin < 2 || isempty(debugger), debugger = true; end
            if nargin < 3 || isempty(waitMs), waitMs = 5000; end
            if nargin < 4, settleMs = []; end
            id = obj.send('INIT', obj.withSettle(struct('debugger', double(logical(debugger)), ...
                'waitms', waitMs), settleMs));
        end

        function id = listDevices(obj, waitMs, settleMs)
            if nargin < 2 || isempty(waitMs), waitMs = 500; end
            if nargin < 3, settleMs = []; end
            id = obj.send('LIST', obj.withSettle(struct('waitms', waitMs), settleMs));
        end

        function id = openDevice(obj, port, waitMs, settleMs)
            if nargin < 3 || isempty(waitMs), waitMs = 5000; end
            if nargin < 4, settleMs = []; end
            id = obj.send('OPEN', obj.withSettle(struct('port', port, 'waitms', waitMs), settleMs));
        end

        function id = closeDevice(obj, port, waitMs, settleMs)
            if nargin < 3 || isempty(waitMs), waitMs = 1000; end
            if nargin < 4, settleMs = []; end
            id = obj.send('CLOSE', obj.withSettle(struct('port', port, 'waitms', waitMs), ...
                settleMs));
        end

        function id = startChannel(obj, port, channel, settleMs)
            if nargin < 4, settleMs = []; end
            id = obj.send('START', obj.withSettle(struct('port', port, 'ch', channel - 1), ...
                settleMs));
        end

        function id = stopChannel(obj, port, channel, settleMs)
            if nargin < 4, settleMs = []; end
            id = obj.send('STOP', obj.withSettle(struct('port', port, 'ch', channel - 1), ...
                settleMs));
        end

        function id = startAll(obj, port, settleMs)
            if nargin < 3, settleMs = []; end
            id = obj.send('STARTALL', obj.withSettle(struct('port', port), settleMs));
        end

        function id = stopAll(obj, port, settleMs)
        %STOPALL Stop every channel of port; an empty port means every port the transport opened.
            if nargin < 2, port = []; end
            if nargin < 3, settleMs = []; end
            if isempty(port)
                args = struct();
            else
                args = struct('port', port);
            end
            id = obj.send('STOPALL', obj.withSettle(args, settleMs));
        end

        function id = sendCurrent(obj, port, channel, currentmA, settleMs)
            if nargin < 5, settleMs = []; end
            id = obj.send('CURRENT', obj.withSettle(struct('port', port, 'ch', channel - 1, ...
                'ma', currentmA), settleMs));
        end

        function id = sendSettings(obj, port, channel, settings, settleMs)
            if nargin < 5, settleMs = []; end
            if ~isa(settings, 'doric.ChannelSettings') || ~isscalar(settings)
                error('doric:Transport:invalidArgument', ...
                    'sendSettings needs a scalar doric.ChannelSettings.');
            end
            id = obj.send('SETTINGS', obj.withSettle(struct('port', port, 'ch', channel - 1, ...
                'Settings', settings), settleMs));
        end

        function id = quit(obj)
            id = obj.send('QUIT', struct());
        end
    end

    methods (Access = protected)
        function messages = readNew(obj)
        %READNEW Read messages, time their round trip and announce them, exactly once each.
        %   Subclasses call this (not readImpl) when they need to drain the link early, so a
        %   message is never timed or announced twice.
            messages = obj.readImpl();
            for k = 1:numel(messages)
                if strcmp(messages(k).Kind, 'reply') && isKey(obj.SentAt, messages(k).Id)
                    messages(k).LatencyMs = 1000 * (messages(k).Time - obj.SentAt(messages(k).Id));
                    remove(obj.SentAt, messages(k).Id);
                end
            end
            if ~isempty(messages) && event.hasListener(obj, 'MessageReceived')
                for k = 1:numel(messages)
                    data = doric.DoricEventData();
                    data.Message = messages(k);
                    notify(obj, 'MessageReceived', data);
                end
            end
        end

        function t = now(obj)
        %NOW Seconds since this transport was created (message time base).
            t = toc(obj.ClockStart);
        end

        function stash(obj, messages)
        %STASH Put messages back so the next poll returns them first.
            obj.Backlog = [obj.Backlog, messages];
        end
    end

    methods (Static)
        function m = newMessage(kind)
        %NEWMESSAGE Message struct with every field present.
            m = struct('Kind', kind, 'Id', 0, 'Ok', false, 'Code', '', 'Text', '', ...
                'Severity', '', 'Source', '', 'Name', '', 'Data', struct(), ...
                'LatencyMs', NaN, 'Time', 0);
        end

        function m = emptyMessages()
        %EMPTYMESSAGES 1-by-0 message struct array.
            m = repmat(doric.transport.Transport.newMessage(''), 1, 0);
        end
    end

    methods (Static, Access = private)
        function args = withSettle(args, settleMs)
            if ~isempty(settleMs)
                args.settle = settleMs;
            end
        end
    end
end
