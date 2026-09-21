classdef Channel < handle
%CHANNEL One output of the light source (created by doric.LightSource; do not construct).
%
%   ch = lightSource.Channels(k)   k = 1 or 2
%
%   Properties
%       Index               1 or 2 (read-only)
%       Settings            pending doric.ChannelSettings (settable; not sent until apply)
%       MaxCurrentmA        user limit in mA (settable, default RecommendedMaxCurrentmA = 700).
%                           Requests above it error doric:Channel:overCurrent; lowering it below
%                           the commanded current errors doric:Channel:limitBelowCommanded;
%                           raising it above DeviceMaxCurrentmA errors
%                           doric:Channel:aboveDeviceLimit. Nothing is clamped.
%       DeviceMaxCurrentmA  1000 mA, constant. The rated maximum of the 465 nm LED head, from
%                           Doric's LED Light Source manual (see below). No API or GUI path can
%                           command more.
%       RecommendedMaxCurrentmA
%                           700 mA, constant. Doric's recommended operating current for a
%                           1000 mA LED, and the default of MaxCurrentmA.
%       CommandedSettings   last settings the device acknowledged, [] before any
%       CommandedCurrentmA  last current acknowledged (via settings or setCurrent), [] before
%       IsRunning           commanded running flag
%       CommandedState      'Unconfigured' | 'Configured' | 'Running' | 'Stopped'
%       LastCommandAt       datetime of the last acknowledged command (NaT before)
%
%   Methods (all accept 'Wait', true|false and 'SettleMs', n; Wait defaults to true)
%       result = apply()            send Settings (ls_send_settings)
%       result = apply(settings)    set Settings, then send it
%                                   On a running channel apply also restarts it (ls_start_channel
%                                   after a successful ls_send_settings), because the device keeps
%                                   emitting its previous settings until the next start. The
%                                   returned result is the SETTINGS one; with 'Wait', true a
%                                   failed restart errors, with 'Wait', false OnDone receives the
%                                   START outcome. 'Restart', false only sends the settings: the
%                                   device then keeps the old ones until start().
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
%       doric:Channel:aboveDeviceLimit  a MaxCurrentmA above DeviceMaxCurrentmA
%       doric:Channel:invalidSettings   not a doric.ChannelSettings
%       doric:Channel:libraryError      the library reported an error (Wait true)
%       doric:Channel:timeout / bridgeExited / <bridge error code>
%
%   Current limits (Doric LED Light Source user manual V2.1.1, table 5.8 "Typical Connectorized
%   LED, LEDFRJ1 and LEDFLS Output Power", and table 5.2 "General Specifications for
%   Connectorized LEDs"): a 465 nm head is rated **1000 mA maximum**, and Doric recommends
%   **700 mA** for LEDs whose maximum is 1000 mA. The driver itself would deliver up to 2000 mA
%   (its "Overdrive @2000 mA (pulsed)" column). The manual's own warning, in capitals: overdrive
%   "allows the system to exceed the normal safe current limit of the light source. THIS SHOULD
%   ONLY BE USED WITH PULSED SIGNALS, AS IT CAN OTHERWISE DAMAGE THE LIGHT SOURCE." This package
%   never allows it, in any mode. Low-power mode tops out at 200 mA in the
%   hardware, which is below the ceiling here and so needs no separate guard.
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

    properties (Constant)
        % Rated maximum of the 465 nm LED head (Doric LED Light Source manual V2.1.1, table 5.8).
        % A hard ceiling: MaxCurrentmA cannot be raised above it, so nothing this package sends
        % can exceed it.
        %
        % NOTE FOR DEVELOPERS: this value is hard-coded for the LEDFLS_465_465. If the light
        % source changes (another Doric LED head, a laser, another driver), this cap must be
        % revisited against that device's own rating in its vendor manual. It may be changed,
        % with caution; whoever changes it takes full responsibility for any damage to the
        % light source, the fibers or the preparation. See docs/vendor-dll.md section 10.
        DeviceMaxCurrentmA = 1000
        % Doric's recommended operating current for a 1000 mA LED (manual table 5.2), and the
        % default limit. The user may raise MaxCurrentmA up to DeviceMaxCurrentmA.
        RecommendedMaxCurrentmA = 700
    end

    properties (Access = private)
        Parent
        MaxCurrentValue = doric.Channel.RecommendedMaxCurrentmA
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
            % The LED's own rating, not a preference: refuse rather than clamp, so the caller
            % sees that the request was impossible.
            if value > doric.Channel.DeviceMaxCurrentmA
                error('doric:Channel:aboveDeviceLimit', ...
                    ['Channel %d: MaxCurrentmA = %d exceeds the LED''s rated maximum of %d mA ' ...
                    '(465 nm head, Doric LED Light Source manual table 5.8). %d mA is the ' ...
                    'recommended operating current. The limit was not changed.'], obj.Index, ...
                    value, doric.Channel.DeviceMaxCurrentmA, ...
                    doric.Channel.RecommendedMaxCurrentmA);
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
            opts = obj.options(varargin, struct('Restart', true));
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
            onSent = @(r) obj.onSettingsSent(settings);
            if ~(logical(opts.Restart) && obj.IsRunning)
                result = obj.Parent.channelCommand(obj.Index, 'SETTINGS', settings, opts, onSent);
                return
            end
            % A running channel keeps emitting its previous settings until the next
            % ls_start_channel (seen at the rig, 2026-09-21), so it is restarted for the new ones
            % to take effect. START follows only a successful SETTINGS: refused settings never
            % restart the old ones.
            startArgs = {'Wait', opts.Wait, 'OnDone', opts.OnDone};
            if ~isempty(opts.SettleMs)
                startArgs = [startArgs, {'SettleMs', opts.SettleMs}];
            end
            settingsOpts = opts;
            if opts.Wait
                settingsOpts.OnDone = [];
                result = obj.Parent.channelCommand(obj.Index, 'SETTINGS', settings, ...
                    settingsOpts, onSent);
                obj.start(startArgs{:});
            else
                settingsOpts.OnDone = @(r) obj.startAfterSettings(r, startArgs, opts.OnDone);
                result = obj.Parent.channelCommand(obj.Index, 'SETTINGS', settings, ...
                    settingsOpts, onSent);
            end
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
        function opts = options(obj, args, extra)
            defaults = struct('Wait', true, 'SettleMs', [], 'OnDone', []);
            if nargin > 2
                for name = fieldnames(extra)'
                    defaults.(name{1}) = extra.(name{1});
                end
            end
            opts = commandOptions(defaults, args, 'Channel');
            opts.Component = 'Channel';
            if isempty(obj.Parent) || ~isvalid(obj.Parent)
                error('doric:LightSource:notReady', 'The owning LightSource was deleted.');
            end
        end

        function startAfterSettings(obj, result, startArgs, onDone)
        % Continuation of a non-blocking apply on a running channel. The caller's OnDone hears
        % the START outcome, or the SETTINGS failure when there was no START.
            if result.Ok
                try
                    obj.start(startArgs{:});
                    return
                catch err
                    result.Ok = false;
                    result.Command = 'START';
                    result.Code = 'notReady';
                    result.Message = err.message;
                end
            end
            if ~isempty(onDone)
                onDone(result);
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
