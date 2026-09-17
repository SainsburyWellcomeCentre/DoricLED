classdef Channel < handle
%CHANNEL One output of the light source (created by doric.LightSource; do not construct).
%
%   ch = lightSource.Channels(k)   k = 1 or 2
%
%   Properties
%       Index               1 or 2 (read-only)
%       Settings            pending doric.ChannelSettings (settable; not sent until apply)
%       MaxCurrentmA        user limit in mA (settable, default 2000). Requests above it error
%                           doric:Channel:overCurrent; lowering it below the commanded current
%                           errors doric:Channel:limitBelowCommanded. Nothing is clamped.
%       CommandedSettings   last settings the device acknowledged, [] before any
%       CommandedCurrentmA  last current acknowledged (via settings or setCurrent), [] before
%       IsRunning           commanded running flag
%       CommandedState      'Unconfigured' | 'Configured' | 'Running' | 'Stopped'
%       LastCommandAt       datetime of the last acknowledged command (NaT before)
%
%   Methods (all accept 'Wait', true|false and 'SettleMs', n; Wait defaults to true)
%       result = apply()            send Settings (ls_send_settings)
%       result = apply(settings)    set Settings, then send it
%       result = start()            ls_start_channel
%       result = stop()             ls_stop_channel
%       result = setCurrent(mA)     ls_send_current; allowed while running (fast path)
%
%   With 'Wait', true a command returns a result struct (Id, Command, Channel, Ok, Code,
%   Message, LatencyMs, LibraryText) and errors if the device or library refused it. With
%   'Wait', false it returns at once with Ok = [] and the outcome arrives through the
%   LightSource's CommandCompleted event, log() and the commanded properties.
%   'OnDone', fn calls fn(result) when the outcome is known (both modes).
%
%   Errors
%       doric:LightSource:notReady      not connected
%       doric:Channel:overCurrent       a current above MaxCurrentmA
%       doric:Channel:invalidSettings   not a doric.ChannelSettings
%       doric:Channel:libraryError      the library reported an error (Wait true)
%       doric:Channel:timeout / bridgeExited / <bridge error code>
%
%   See also doric.LightSource, doric.ChannelSettings

    properties (SetAccess = private)
        Index
        CommandedSettings = []
        CommandedCurrentmA = []
        IsRunning = false
        CommandedState = 'Unconfigured'
        LastCommandAt = NaT
    end

    properties
        Settings = doric.ChannelSettings()
    end

    properties (Dependent)
        MaxCurrentmA
    end

    properties (Access = private)
        Parent
        MaxCurrentValue = 2000
    end

    methods
        function obj = Channel(parent, index)
            obj.Parent = parent;
            obj.Index = index;
        end

        function set.Settings(obj, value)
            if isstruct(value)
                value = doric.ChannelSettings.fromStruct(value);
            end
            if ~isa(value, 'doric.ChannelSettings') || ~isscalar(value)
                error('doric:Channel:invalidSettings', ...
                    'Settings must be a scalar doric.ChannelSettings.');
            end
            obj.Settings = value;
        end

        function value = get.MaxCurrentmA(obj)
            value = obj.MaxCurrentValue;
        end

        function set.MaxCurrentmA(obj, value)
            if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) || ~isfinite(value) || ...
                    value < 0 || value > 65535 || value ~= fix(value)
                error('doric:Channel:invalidLimit', ...
                    'MaxCurrentmA must be an integer in [0, 65535].');
            end
            if ~isempty(obj.CommandedCurrentmA) && obj.CommandedCurrentmA > value
                error('doric:Channel:limitBelowCommanded', ...
                    ['Channel %d: the commanded current is %d mA, above the new limit of %d mA. ' ...
                    'Send a lower current first (setCurrent).'], obj.Index, ...
                    obj.CommandedCurrentmA, value);
            end
            obj.MaxCurrentValue = double(value);
        end

        function result = apply(obj, varargin)
            settings = obj.Settings;
            if ~isempty(varargin) && ~(ischar(varargin{1}) || isstring(varargin{1}))
                settings = varargin{1};
                if isstruct(settings)
                    settings = doric.ChannelSettings.fromStruct(settings);
                end
                if ~isa(settings, 'doric.ChannelSettings') || ~isscalar(settings)
                    error('doric:Channel:invalidSettings', ...
                        'apply needs a scalar doric.ChannelSettings.');
                end
                varargin(1) = [];
            end
            opts = obj.options(varargin);
            peak = settings.peakCurrentmA();
            if peak > obj.MaxCurrentValue
                error('doric:Channel:overCurrent', ...
                    'Channel %d: settings request %d mA, above MaxCurrentmA = %d. Nothing sent.', ...
                    obj.Index, peak, obj.MaxCurrentValue);
            end
            obj.Settings = settings;
            warnings = settings.check();
            for k = 1:numel(warnings)
                warning('doric:ChannelSettings:suspicious', 'Channel %d: %s', obj.Index, ...
                    warnings{k});
            end
            result = obj.Parent.channelCommand(obj.Index, 'SETTINGS', settings, opts, ...
                @(r) obj.onSettingsSent(settings));
        end

        function result = start(obj, varargin)
            opts = obj.options(varargin);
            result = obj.Parent.channelCommand(obj.Index, 'START', [], opts, ...
                @(r) obj.onRunning(true));
        end

        function result = stop(obj, varargin)
            opts = obj.options(varargin);
            result = obj.Parent.channelCommand(obj.Index, 'STOP', [], opts, ...
                @(r) obj.onRunning(false));
        end

        function result = setCurrent(obj, currentmA, varargin)
            if ~isnumeric(currentmA) || ~isscalar(currentmA) || ~isreal(currentmA) || ...
                    ~isfinite(currentmA) || currentmA ~= fix(currentmA) || currentmA < 0 || ...
                    currentmA > 65535
                error('doric:Channel:invalidCurrent', ...
                    'Current must be an integer in [0, 65535] mA.');
            end
            if currentmA > obj.MaxCurrentValue
                error('doric:Channel:overCurrent', ...
                    'Channel %d: %d mA is above MaxCurrentmA = %d. Nothing sent.', obj.Index, ...
                    currentmA, obj.MaxCurrentValue);
            end
            opts = obj.options(varargin);
            currentmA = double(currentmA);
            result = obj.Parent.channelCommand(obj.Index, 'CURRENT', currentmA, opts, ...
                @(r) obj.onCurrentSent(currentmA));
        end
    end

    methods (Access = {?doric.LightSource})
        function resetCommanded(obj)
        %RESETCOMMANDED Forget commanded state (new connection: assume nothing).
            obj.CommandedSettings = [];
            obj.CommandedCurrentmA = [];
            obj.IsRunning = false;
            obj.CommandedState = 'Unconfigured';
            obj.LastCommandAt = NaT;
        end

        function markStopped(obj)
            obj.onRunning(false);
        end

        function markStartedIfConfigured(obj)
            if ~isempty(obj.CommandedSettings)
                obj.onRunning(true);
            end
        end
    end

    methods (Access = private)
        function opts = options(obj, args)
            opts = commandOptions(struct('Wait', true, 'SettleMs', [], 'OnDone', []), args, ...
                'Channel');
            opts.Component = 'Channel';
            if isempty(obj.Parent) || ~isvalid(obj.Parent)
                error('doric:LightSource:notReady', 'The owning LightSource was deleted.');
            end
        end

        function onSettingsSent(obj, settings)
            obj.CommandedSettings = settings;
            obj.CommandedCurrentmA = settings.CurrentmA;
            obj.LastCommandAt = datetime('now');
            if ~obj.IsRunning
                obj.CommandedState = 'Configured';
            end
        end

        function onCurrentSent(obj, currentmA)
            obj.CommandedCurrentmA = currentmA;
            obj.LastCommandAt = datetime('now');
        end

        function onRunning(obj, running)
            obj.IsRunning = running;
            obj.LastCommandAt = datetime('now');
            if running
                obj.CommandedState = 'Running';
            elseif ~strcmp(obj.CommandedState, 'Unconfigured')
                obj.CommandedState = 'Stopped';
            end
        end
    end
end
