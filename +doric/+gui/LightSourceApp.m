classdef LightSourceApp < handle
%LIGHTSOURCEAPP Interactive control window for a doric.LightSource (programmatic uifigure).
%
%   app = doric.gui.LightSourceApp()            owns a new LightSource (real device); closing
%                                               the window disconnects it
%   app = doric.gui.LightSourceApp('Transport', t, 'Port', 5, ...)
%                                               owns a LightSource built with these options
%   app = doric.gui.LightSourceApp(lightSource) attaches to an existing LightSource; closing
%                                               the window never disconnects it
%   app = doric.gui.LightSourceApp(..., 'Visible', false)   hidden windows (tests)
%
%   Main window: port selection and Scan, Connect, per-channel selection / mode / intensity,
%   Apply / Start / Stop for the selected channels, Live intensity, Advanced settings..., STOP ALL
%   (also the Esc key) and a message log. Advanced settings: every other vendor field, limits,
%   settle window, verbose output, save/load configuration. Both windows edit the same pending
%   Channel.Settings; nothing reaches the device until Apply or Start. See docs/gui.md.
%
%   Properties (read-only)
%       LightSource       the doric.LightSource shown
%       OwnsLightSource   true when the app created it
%       Figure            main uifigure
%       AdvancedFigure    advanced settings uifigure, [] until opened
%       Controls          struct of main-window components (for scripting and tests)
%       AdvancedControls  struct of advanced-window components
%       LastError         text of the last error shown to the user
%
%   Methods
%       openAdvanced()        open or raise the advanced settings window
%       idx = selectedChannels()
%       refresh()             redraw every control from the LightSource
%       saveConfigTo(file) / loadConfigFrom(file)   what the Save/Load buttons do
%       close()               close both windows (disconnects only an owned LightSource)
%
%   See also doric.app, doric.LightSource, doric.Channel, doric.ChannelSettings

    properties (SetAccess = private)
        LightSource
        OwnsLightSource = false
        Figure = []
        AdvancedFigure = []
        Controls = struct()
        AdvancedControls = struct()
        LastError = ''
    end

    properties (Constant, Hidden)
        Accent = [0.12 0.42 0.85]      % 465 nm blue
        Danger = [0.80 0.10 0.10]
        PendingColor = [1.00 0.96 0.78]
        DimColor = [0.55 0.55 0.55]
        LiveIntervalS = 0.05           % live intensity throttle while dragging (about 20 Hz)
        % Live intensity waits for the ack only. The library prints ls_send_current's text
        % during the call (rig check 2026-09-17), and a 100 ms settle per step made drags queue
        % up behind each other (rig check 2026-09-21); late text still reaches the log.
        LiveSettleMs = 0
    end

    properties (Access = private)
        Listeners = {}
        LastLiveSend
        LiveBusy = [false false]       % a live CURRENT is in flight on that channel
        LiveQueued = {[], []}          % newest value waiting for it, [] when none
        LogDirty = false
        LogLines = {}
        Visible = 'on'
        Closing = false
    end

    methods
        function obj = LightSourceApp(varargin)
            visible = true;
            if ~isempty(varargin) && isa(varargin{1}, 'doric.LightSource')
                lightSource = varargin{1};
                varargin(1) = [];
                owns = false;
            else
                lightSource = [];
                owns = true;
            end
            rest = {};
            for k = 1:2:numel(varargin)
                if strcmpi(varargin{k}, 'Visible')
                    visible = logical(varargin{k + 1});
                else
                    rest = [rest, varargin(k:min(k + 1, end))]; %#ok<AGROW>
                end
            end
            if owns
                lightSource = doric.LightSource(rest{:});
            elseif ~isempty(rest)
                error('doric:LightSourceApp:invalidOption', ...
                    'Only ''Visible'' can be given when attaching to an existing LightSource.');
            end
            obj.LightSource = lightSource;
            obj.OwnsLightSource = owns;
            obj.Visible = matlab.lang.OnOffSwitchState(visible);
            obj.LastLiveSend = {tic, tic};

            obj.initialisePending();
            obj.buildMain();
            ref = matlab.lang.WeakReference(obj);
            events_ = {'StateChanged', 'CommandCompleted', 'LibraryMessage', 'Faulted'};
            for k = 1:numel(events_)
                obj.Listeners{end + 1} = addlistener(lightSource, events_{k}, ...
                    @(~, evt) doric.gui.LightSourceApp.dispatch(ref, events_{k}, evt));
            end
            obj.refresh();
        end

        function delete(obj)
            try
                obj.close();
            catch
            end
        end

        function close(obj)
            if obj.Closing
                return
            end
            obj.Closing = true;
            for k = 1:numel(obj.Listeners)
                try
                    delete(obj.Listeners{k});
                catch
                end
            end
            obj.Listeners = {};
            obj.closeAdvanced();
            if obj.OwnsLightSource && ~isempty(obj.LightSource) && isvalid(obj.LightSource)
                obj.LightSource.disconnect();
                delete(obj.LightSource);
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                delete(obj.Figure);
            end
        end

        function idx = selectedChannels(obj)
            idx = find([obj.Controls.Select.Value]);
        end

        function openAdvanced(obj)
            if ~isempty(obj.AdvancedFigure) && isvalid(obj.AdvancedFigure)
                figure(obj.AdvancedFigure);
                return
            end
            obj.buildAdvanced();
            obj.refresh();
        end

        function refresh(obj)
            if obj.Closing || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end
            obj.refreshMain();
            if ~isempty(obj.AdvancedFigure) && isvalid(obj.AdvancedFigure)
                obj.refreshAdvanced();
            end
            obj.flushLog();
        end

        function saveConfigTo(obj, file)
            obj.guard(@() obj.LightSource.saveConfig(file));
            obj.appendLog(sprintf('Configuration saved to %s', file));
        end

        function loadConfigFrom(obj, file)
            if obj.guard(@() obj.LightSource.loadConfig(file))
                obj.appendLog(sprintf('Configuration loaded from %s (not sent)', file));
            end
            obj.refresh();
        end
    end

    % ---- main window -----------------------------------------------------------------------

    methods (Access = private)
        function initialisePending(obj)
        % Owned: the GUI defaults (ExtTTL, 0 mA). Attached: keep the host's pending settings
        % unless they are the untouched API default.
            for k = 1:numel(obj.LightSource.Channels)
                ch = obj.LightSource.Channels(k);
                if obj.OwnsLightSource || isequal(ch.Settings, doric.ChannelSettings())
                    ch.Settings = ch.Settings.with('Mode', doric.Mode.ExtTTL, 'CurrentmA', 0);
                end
            end
        end

        function buildMain(obj)
            fig = uifigure('Name', 'Doric LED light source', 'Position', [100 100 660 420], ...
                'Visible', obj.Visible, 'Tag', 'doric.gui.LightSourceApp');
            fig.CloseRequestFcn = @(~, ~) obj.close();
            fig.WindowKeyPressFcn = @(~, evt) obj.onKey(evt);
            obj.Figure = fig;
            c = struct();

            main = uigridlayout(fig, [6 1], 'RowHeight', {30, 'fit', 'fit', 30, 30, '1x'}, ...
                'RowSpacing', 6, 'Padding', [10 10 10 10]);

            top = uigridlayout(main, [1 7], 'ColumnWidth', {40, 190, 70, 90, 20, '1x', 0}, ...
                'Padding', [0 0 0 0]);
            uilabel(top, 'Text', 'Port');
            c.Port = uidropdown(top, 'Items', {'Auto'}, 'Editable', 'on', 'Value', 'Auto', ...
                'Tooltip', ['Doric port number. Auto uses the one listed device whose name ' ...
                'matches DeviceNamePattern (default ''LED''), so a rotary joint on the same ' ...
                'PC is skipped. Type a number or pick one after Scan.']);
            c.Scan = uibutton(top, 'Text', 'Scan', 'ButtonPushedFcn', @(~, ~) obj.onScan(), ...
                'Tooltip', 'List Doric devices (init, list, quit; opens nothing)');
            c.Connect = uibutton(top, 'Text', 'Connect', ...
                'ButtonPushedFcn', @(~, ~) obj.onConnect());
            c.Lamp = uilamp(top, 'Color', [0.6 0.6 0.6]);
            c.State = uilabel(top, 'Text', 'Disconnected');

            modeNames = cellstr(string(enumeration('doric.Mode')));
            for k = 1:2
                row = uigridlayout(main, [2 6], 'ColumnWidth', {90, 40, 100, '1x', 70, 25}, ...
                    'RowHeight', {26, 18}, 'Padding', [0 0 0 0], 'RowSpacing', 0);
                c.Select(k) = uicheckbox(row, 'Text', sprintf('Channel %d', k), 'Value', true, ...
                    'ValueChangedFcn', @(~, ~) obj.refresh(), ...
                    'Tooltip', 'Apply, Start and Stop act on the selected channels');
                uilabel(row, 'Text', 'Mode');
                c.Mode(k) = uidropdown(row, 'Items', modeNames, ...
                    'ValueChangedFcn', @(src, ~) obj.onMode(k, src.Value), ...
                    'Tooltip', 'Operating mode (sent on Apply/Start)');
                c.Slider(k) = uislider(row, 'Limits', [0 doric.Channel.DeviceMaxCurrentmA], ...
                    'MajorTicks', [], 'MinorTicks', [], ...
                    'ValueChangingFcn', @(~, evt) obj.onIntensityChanging(k, evt.Value), ...
                    'ValueChangedFcn', @(src, ~) obj.onSlider(k, src.Value), ...
                    'Tooltip', 'Intensity (mA); range follows MaxCurrentmA');
                % The box stops at the LED's rating, so an over-rating value cannot even be typed.
                c.Intensity(k) = uieditfield(row, 'numeric', ...
                    'Limits', [0 doric.Channel.DeviceMaxCurrentmA], ...
                    'ValueDisplayFormat', '%.0f', ...
                    'ValueChangedFcn', @(src, ~) obj.onIntensity(k, src.Value), ...
                    'Tooltip', sprintf(['Intensity in mA (integer, 0-%d: the LED''s rated ' ...
                    'maximum). Requests above MaxCurrentmA are refused.'], ...
                    doric.Channel.DeviceMaxCurrentmA));
                uilabel(row, 'Text', 'mA');
                c.Commanded(k) = uilabel(row, 'Text', '', 'FontSize', 11, ...
                    'FontColor', obj.DimColor);
                c.Commanded(k).Layout.Row = 2;
                c.Commanded(k).Layout.Column = [2 4];
                c.Hint(k) = uilabel(row, 'Text', '', 'FontSize', 11, 'FontColor', obj.Accent, ...
                    'HorizontalAlignment', 'right');
                c.Hint(k).Layout.Row = 2;
                c.Hint(k).Layout.Column = [5 6];
            end

            actions = uigridlayout(main, [1 6], ...
                'ColumnWidth', {120, 70, 70, 70, 110, '1x'}, 'Padding', [0 0 0 0]);
            uilabel(actions, 'Text', 'Selected channels:');
            c.Apply = uibutton(actions, 'Text', 'Apply', 'ButtonPushedFcn', @(~, ~) obj.onApply(), ...
                'Tooltip', ['Send the pending settings of the selected channels. A running ' ...
                'channel is restarted so they take effect; a stopped one stays off until Start.']);
            c.Start = uibutton(actions, 'Text', 'Start', 'ButtonPushedFcn', @(~, ~) obj.onStart(), ...
                'Tooltip', 'Apply pending changes (if any), then start the selected channels');
            c.Stop = uibutton(actions, 'Text', 'Stop', 'ButtonPushedFcn', @(~, ~) obj.onStop());
            c.Live = uicheckbox(actions, 'Text', 'Live intensity', 'Value', true, ...
                'ValueChangedFcn', @(~, ~) obj.refresh(), 'Tooltip', ['While a channel runs, intensity changes are sent at once ' ...
                '(ls_send_current). Off: sent on Apply.']);

            bottom = uigridlayout(main, [1 3], 'ColumnWidth', {140, '1x', 110}, ...
                'Padding', [0 0 0 0]);
            c.Advanced = uibutton(bottom, 'Text', 'Advanced settings...', ...
                'ButtonPushedFcn', @(~, ~) obj.openAdvanced());
            c.Status = uilabel(bottom, 'Text', '', 'FontColor', obj.Danger);
            c.StopAll = uibutton(bottom, 'Text', 'STOP ALL', 'FontWeight', 'bold', ...
                'BackgroundColor', obj.Danger, 'FontColor', [1 1 1], ...
                'ButtonPushedFcn', @(~, ~) obj.onStopAll(), ...
                'Tooltip', 'Stop every channel (Esc). Works in every state.');

            c.Log = uitextarea(main, 'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 10);
            obj.Controls = c;
        end

        function refreshMain(obj)
            ls = obj.LightSource;
            c = obj.Controls;
            state = ls.State;
            disconnected = any(strcmp(state, {'Disconnected', 'Faulted'}));
            ready = strcmp(state, 'Ready');
            c.State.Text = state;
            if strcmp(state, 'Faulted')
                c.State.Text = ['Faulted: ' ls.FaultReason];
            elseif ready && ~isempty(ls.DeviceName)
                c.State.Text = sprintf('Ready - %s on port %d', ls.DeviceName, ls.Port);
            end
            switch state
                case 'Ready'
                    c.Lamp.Color = obj.Accent;
                case 'Faulted'
                    c.Lamp.Color = obj.Danger;
                case 'Disconnected'
                    c.Lamp.Color = [0.6 0.6 0.6];
                otherwise
                    c.Lamp.Color = [0.95 0.7 0.1];
            end
            c.Port.Enable = disconnected;
            c.Scan.Enable = disconnected;
            if disconnected
                c.Connect.Text = 'Connect';
            elseif ready
                c.Connect.Text = 'Disconnect';
            else
                c.Connect.Text = 'Cancel';
            end
            c.Apply.Enable = ready;
            c.Start.Enable = ready;
            c.Stop.Enable = ready;
            c.StopAll.Enable = 'on';

            for k = 1:2
                ch = ls.Channels(k);
                s = ch.Settings;
                c.Mode(k).Value = char(s.Mode);
                upper_ = max(1, ch.MaxCurrentmA);
                c.Slider(k).Limits = [0 upper_];
                c.Slider(k).Value = min(s.CurrentmA, upper_);
                c.Intensity(k).Value = s.CurrentmA;
                pending = isempty(ch.CommandedSettings) || ~isequal(s, ch.CommandedSettings);
                modePending = isempty(ch.CommandedSettings) || s.Mode ~= ch.CommandedSettings.Mode;
                currentPending = isempty(ch.CommandedCurrentmA) || s.CurrentmA ~= ch.CommandedCurrentmA;
                c.Mode(k).BackgroundColor = obj.pick(modePending, obj.PendingColor, [1 1 1]);
                c.Intensity(k).BackgroundColor = obj.pick(currentPending, obj.PendingColor, [1 1 1]);
                if isempty(ch.CommandedSettings)
                    text = 'Commanded: nothing sent';
                else
                    text = sprintf('Commanded: %s, %d mA, %s', char(ch.CommandedSettings.Mode), ...
                        ch.CommandedCurrentmA, lower(ch.CommandedState));
                    if ~ch.IsRunning
                        text = [text ' - press Start to turn on']; %#ok<AGROW>
                    end
                end
                if pending && ~isempty(ch.CommandedSettings)
                    text = [text '  (pending changes)']; %#ok<AGROW>
                end
                c.Commanded(k).Text = text;
                needsAdvanced = any(s.Mode == [doric.Mode.Square, doric.Mode.Complex, ...
                    doric.Mode.Custom]) || s.TriggerType ~= doric.TriggerType.Manual;
                c.Hint(k).Text = obj.pick(needsAdvanced, 'see Advanced settings', '');
            end
        end

        % ---- main callbacks ----------------------------------------------------------------

        function onKey(obj, evt)
            if strcmpi(evt.Key, 'escape')
                obj.onStopAll();
            end
        end

        function onScan(obj)
            fig = obj.Figure;
            obj.Controls.State.Text = 'Scanning...';
            drawnow limitrate
            devices = [];
            obj.guard(@() assignDevices());
            if ~isempty(devices)
                items = [{'Auto'}, compose('%d - %s', devices.Port, devices.Name)'];
                obj.Controls.Port.Items = items;
                obj.appendLog(sprintf('Scan: %d device(s)', height(devices)));
            elseif isempty(obj.LastError)
                obj.appendLog('Scan: no device listed');
            end
            if isvalid(fig)
                obj.refresh();
            end
            function assignDevices()
                obj.LastError = '';
                devices = obj.LightSource.listDevices();
            end
        end

        function onConnect(obj)
            ls = obj.LightSource;
            switch ls.State
                case {'Disconnected', 'Faulted'}
                    port = obj.portFromControl();
                    if isnan(port)
                        obj.showError(sprintf('"%s" is not a port number.', obj.Controls.Port.Value));
                        return
                    end
                    ok = obj.guard(@() setPort(port));
                    if ok
                        obj.guard(@() ls.connect('Wait', false, ...
                            'OnDone', @(r) obj.onConnectDone(r)));
                    end
                otherwise
                    ls.disconnect();
            end
            obj.refresh();
            function setPort(value)
                if value < 0
                    ls.Port = [];
                else
                    ls.Port = value;
                end
            end
        end

        function onConnectDone(obj, result)
            if ~isvalid(obj) || obj.Closing
                return
            end
            if result.Ok
                obj.appendLog(result.Message);
            else
                obj.showError(['Connect failed: ' result.Message]);
            end
            obj.refresh();
        end

        function port = portFromControl(obj)
        % -1 for Auto, NaN when unreadable.
            text = strtrim(char(obj.Controls.Port.Value));
            if strcmpi(text, 'Auto') || isempty(text)
                port = -1;
                return
            end
            token = regexp(text, '^\s*(\d+)', 'tokens', 'once');
            if isempty(token)
                port = NaN;
            else
                port = str2double(token{1});
            end
        end

        function onMode(obj, k, value)
            obj.editPending(k, 'Mode', value);
        end

        function onIntensityChanging(obj, k, value)
            value = round(value);
            obj.Controls.Intensity(k).Value = value;
            % Keep the pending value in step with the thumb, so a refresh triggered by a reply
            % mid-drag does not throw the slider back to the old value.
            if value <= obj.LightSource.Channels(k).MaxCurrentmA
                obj.guard(@() obj.setPending(k, 'CurrentmA', value));
            end
            if obj.liveActive(k) && toc(obj.LastLiveSend{k}) >= obj.LiveIntervalS
                obj.sendLive(k, value);
            end
        end

        function onSlider(obj, k, value)
        % A slider position is continuous; snapping it to the nearest mA is the slider's
        % resolution, not a clamp. The typed box still refuses a fractional value.
            obj.onIntensity(k, round(value));
        end

        function onIntensity(obj, k, value)
            if value ~= fix(value)
                obj.showError(sprintf('Channel %d: intensity must be a whole number of mA.', k));
                obj.refresh();
                return
            end
            if ~obj.editPending(k, 'CurrentmA', value)
                return
            end
            if obj.liveActive(k)
                obj.sendLive(k, value);
                obj.refresh();
            end
        end

        function tf = liveActive(obj, k)
            ch = obj.LightSource.Channels(k);
            tf = obj.Controls.Live.Value && strcmp(obj.LightSource.State, 'Ready') && ch.IsRunning;
        end

        function sendLive(obj, k, value)
        % At most one live CURRENT in flight per channel; while it is, only the newest value is
        % kept and sent when it completes. Sending every step instead queues them in the bridge
        % and the light lags the slider. A reply lost for 2 s no longer blocks live sends.
            if obj.LiveBusy(k) && toc(obj.LastLiveSend{k}) < 2
                obj.LiveQueued{k} = value;
                return
            end
            obj.LiveQueued{k} = [];
            ch = obj.LightSource.Channels(k);
            if ~obj.LiveBusy(k) && isequal(ch.CommandedCurrentmA, value)
                return
            end
            obj.LastLiveSend{k} = tic;
            obj.LiveBusy(k) = true;
            if ~obj.guard(@() ch.setCurrent(value, 'Wait', false, ...
                    'SettleMs', obj.LiveSettleMs, 'OnDone', @(~) obj.onLiveDone(k)))
                obj.LiveBusy(k) = false;
            end
        end

        function onLiveDone(obj, k)
            if ~isvalid(obj)
                return
            end
            obj.LiveBusy(k) = false;
            value = obj.LiveQueued{k};
            obj.LiveQueued{k} = [];
            if ~isempty(value) && obj.liveActive(k)
                obj.sendLive(k, value);
            end
        end

        function onApply(obj)
            for k = obj.selectedChannels()
                % Channel.apply restarts a running channel so the new settings take effect.
                obj.guard(@() obj.LightSource.Channels(k).apply('Wait', false));
            end
            obj.refresh();
        end

        function onStart(obj)
            for k = obj.selectedChannels()
                ch = obj.LightSource.Channels(k);
                if isempty(ch.CommandedSettings) || ~isequal(ch.Settings, ch.CommandedSettings)
                    % Wait for the settings so a refused apply never starts old settings.
                    if ~obj.guard(@() ch.apply('Wait', true, 'Restart', false))
                        continue
                    end
                end
                obj.guard(@() ch.start('Wait', false));
            end
            obj.refresh();
        end

        function onStop(obj)
            for k = obj.selectedChannels()
                obj.guard(@() obj.LightSource.Channels(k).stop('Wait', false));
            end
            obj.refresh();
        end

        function onStopAll(obj)
            obj.guard(@() obj.LightSource.stopAll('Wait', false));
            obj.appendLog('STOP ALL sent');
            obj.refresh();
        end

        % ---- events from the LightSource ---------------------------------------------------

        function onEvent(obj, name, evt)
            if obj.Closing || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end
            switch name
                case 'StateChanged'
                    obj.appendLog(sprintf('State: %s -> %s', evt.OldState, evt.NewState));
                case 'CommandCompleted'
                    if isempty(evt.Ok) || ~evt.Ok
                        obj.showError(sprintf('%s%s failed: %s', evt.Command, ...
                            obj.channelSuffix(evt.Channel), evt.Message));
                    end
                case 'LibraryMessage'
                    % One settings echo is ~30 lines; redrawing the window for each one froze
                    % it. Info lines wait for the next refresh, which follows with the reply.
                    obj.appendLog(sprintf('Library (%s): %s', evt.Severity, evt.Text), ...
                        strcmp(evt.Severity, 'info'));
                    if strcmp(evt.Severity, 'info')
                        return
                    end
                case 'Faulted'
                    obj.showError(['Faulted: ' evt.Reason]);
            end
            obj.refresh();
        end

        % ---- advanced window ---------------------------------------------------------------

        function buildAdvanced(obj)
            fig = uifigure('Name', 'Advanced settings - Doric LED', ...
                'Position', [780 100 720 640], 'Visible', obj.Visible, ...
                'Tag', 'doric.gui.LightSourceApp.Advanced');
            fig.CloseRequestFcn = @(~, ~) obj.closeAdvanced();
            fig.WindowKeyPressFcn = @(~, evt) obj.onKey(evt);
            obj.AdvancedFigure = fig;
            outer = uigridlayout(fig, [1 1], 'Padding', [6 6 6 6]);
            tabs = uitabgroup(outer);
            a = struct();
            for k = 1:2
                a.Channel(k) = obj.buildChannelTab(uitab(tabs, 'Title', sprintf('Channel %d', k)), k);
            end
            a.Limits = obj.buildLimitsTab(uitab(tabs, 'Title', 'Limits & config'));
            a.Tabs = tabs;
            obj.AdvancedControls = a;
        end

        function closeAdvanced(obj)
            if ~isempty(obj.AdvancedFigure) && isvalid(obj.AdvancedFigure)
                delete(obj.AdvancedFigure);
            end
            obj.AdvancedFigure = [];
            obj.AdvancedControls = struct();
        end

        function t = buildChannelTab(obj, tab, k)
            t = struct();
            grid = uigridlayout(tab, [7 1], 'RowHeight', {26, 60, 150, 60, 190, 190, 30}, ...
                'Scrollable', 'on', 'Padding', [8 8 8 8], 'RowSpacing', 8);

            presetRow = uigridlayout(grid, [1 3], 'ColumnWidth', {60, 160, '1x'}, ...
                'Padding', [0 0 0 0]);
            uilabel(presetRow, 'Text', 'Preset');
            t.Preset = uidropdown(presetRow, 'Items', {'-', 'Off', 'CW', 'ExtTTL', 'ExtAnalog', ...
                'Square', 'Triggered', 'Gated', 'Complex', 'Custom'}, 'Value', '-', ...
                'ValueChangedFcn', @(src, ~) obj.onPreset(k, src), ...
                'Tooltip', ['Fill every field from a doric.ChannelSettings factory (vendor ' ...
                'example values), keeping the intensity. Nothing is sent.']);
            uilabel(presetRow, 'Text', 'Mode and intensity are set in the main window.', ...
                'FontColor', obj.DimColor);

            t.CurrentPanel = uipanel(grid, 'Title', 'Current mode');
            g = uigridlayout(t.CurrentPanel, [1 2], 'ColumnWidth', {120, 160});
            uilabel(g, 'Text', 'Current mode');
            t.CurrentMode = uidropdown(g, 'Items', cellstr(string(enumeration('doric.CurrentMode'))), ...
                'ValueChangedFcn', @(src, ~) obj.editPending(k, 'CurrentMode', src.Value), ...
                'Tooltip', sprintf(['Normal, LowPower or Overdrive current range (currentMode). ' ...
                'The %d mA ceiling applies in every mode, so the driver''s pulsed 2000 mA ' ...
                'overdrive is not reachable from here.'], doric.Channel.DeviceMaxCurrentmA));

            t.TimingPanel = uipanel(grid, 'Title', 'Timing');
            g = uigridlayout(t.TimingPanel, [4 4], 'ColumnWidth', {140, '1x', 140, '1x'});
            fields = { ...
                'PeriodMs', 'Period (ms)', 'Pulse period (ttlModulation.periodMs)'; ...
                'TimeOnMs', 'Time on (ms)', 'On time per period (ttlModulation.timeOnMs)'; ...
                'StartingDelayMs', 'Starting delay (ms)', 'Delay before the first sequence'; ...
                'DelayBetweenSeqMs', 'Delay between seq (ms)', 'Pause between sequences'; ...
                'RisingTimeMs', 'Rising time (ms)', 'Rise ramp (ttlModulation.risingTimeMs)'; ...
                'FallingTimeMs', 'Falling time (ms)', 'Fall ramp (ttlModulation.fallingTimeMs)'; ...
                'NbOfSeq', 'Nb of sequences', 'Number of sequences; 0 = infinite'; ...
                'NbOfPulsesPerSeq', 'Pulses per sequence', 'Pulses in each sequence; 0 = infinite'};
            for f = 1:size(fields, 1)
                name = fields{f, 1};
                uilabel(g, 'Text', fields{f, 2}, 'Tooltip', fields{f, 3});
                t.(name) = uieditfield(g, 'numeric', 'ValueDisplayFormat', '%.10g', ...
                    'Tooltip', fields{f, 3}, ...
                    'ValueChangedFcn', @(src, ~) obj.editPending(k, name, src.Value));
            end

            t.TriggerPanel = uipanel(grid, 'Title', 'Trigger');
            g = uigridlayout(t.TriggerPanel, [1 6], 'ColumnWidth', {40, 100, 40, 120, '1x', '1x'});
            uilabel(g, 'Text', 'Type');
            t.TriggerType = uidropdown(g, 'Items', cellstr(string(enumeration('doric.TriggerType'))), ...
                'ValueChangedFcn', @(src, ~) obj.editPending(k, 'TriggerType', src.Value), ...
                'Tooltip', 'Triggered: edge starts; Gated: runs while high; Manual: software only');
            uilabel(g, 'Text', 'Mode');
            t.TriggerMode = uidropdown(g, 'Items', cellstr(string(enumeration('doric.TriggerMode'))), ...
                'ValueChangedFcn', @(src, ~) obj.editPending(k, 'TriggerMode', src.Value), ...
                'Tooltip', 'What a trigger does to a running sequence');
            t.IsRepeatableSequence = uicheckbox(g, 'Text', 'Repeatable sequence', ...
                'ValueChangedFcn', @(src, ~) obj.editPending(k, 'IsRepeatableSequence', src.Value), ...
                'Tooltip', 'isRepeatableSequence');
            t.IsTTLOutput = uicheckbox(g, 'Text', 'TTL output', ...
                'ValueChangedFcn', @(src, ~) obj.editPending(k, 'IsTTLOutput', src.Value), ...
                'Tooltip', 'Output connector: TTL (checked) or analog/ADC (unchecked)');

            t.ComplexPanel = uipanel(grid, 'Title', 'Complex sequence');
            g = uigridlayout(t.ComplexPanel, [2 3], 'RowHeight', {'1x', 26}, ...
                'ColumnWidth', {90, 90, '1x'});
            t.ComplexTable = uitable(g, 'ColumnEditable', true, ...
                'CellEditCallback', @(src, ~) obj.onComplexEdit(k, src), ...
                'Tooltip', 'Up to 32 segments, sent in order');
            t.ComplexTable.Layout.Column = [1 3];
            t.AddSegment = uibutton(g, 'Text', 'Add segment', ...
                'ButtonPushedFcn', @(~, ~) obj.onAddSegment(k));
            t.RemoveSegment = uibutton(g, 'Text', 'Remove', ...
                'ButtonPushedFcn', @(~, ~) obj.onRemoveSegment(k));

            t.CustomPanel = uipanel(grid, 'Title', 'Custom waveform');
            g = uigridlayout(t.CustomPanel, [4 3], 'ColumnWidth', {150, 150, '1x'}, ...
                'RowHeight', {26, 26, 26, '1x'});
            t.CustomVariable = uieditfield(g, 'text', 'Placeholder', 'workspace variable', ...
                'Tooltip', 'Name of a base-workspace vector of mA values (<= 1000 points)');
            t.ImportWorkspace = uibutton(g, 'Text', 'Import from workspace', ...
                'ButtonPushedFcn', @(~, ~) obj.onImportWorkspace(k));
            t.CustomAxes = uiaxes(g);
            t.CustomAxes.Layout.Row = [1 4];
            t.CustomAxes.Layout.Column = 3;
            xlabel(t.CustomAxes, 'point');
            ylabel(t.CustomAxes, 'mA');
            t.ImportCsv = uibutton(g, 'Text', 'Import CSV...', ...
                'ButtonPushedFcn', @(~, ~) obj.onImportCsv(k));
            t.ClearCustom = uibutton(g, 'Text', 'Clear', ...
                'ButtonPushedFcn', @(~, ~) obj.editPending(k, 'CustomDataPoints', []));
            t.CustomInfo = uilabel(g, 'Text', '');
            t.CustomInfo.Layout.Column = [1 2];

            buttons = uigridlayout(grid, [1 4], 'ColumnWidth', {'1x', 90, 120, 90}, ...
                'Padding', [0 0 0 0]);
            uilabel(buttons, 'Text', '');
            t.Revert = uibutton(buttons, 'Text', 'Revert', ...
                'ButtonPushedFcn', @(~, ~) obj.onRevert(k), ...
                'Tooltip', 'Reload the commanded settings into the pending settings');
            t.ApplyChannel = uibutton(buttons, 'Text', 'Apply to channel', ...
                'ButtonPushedFcn', @(~, ~) obj.onApplyChannel(k), ...
                'Tooltip', 'Send every pending setting of this channel, including mode and intensity');
            t.Close = uibutton(buttons, 'Text', 'Close', 'ButtonPushedFcn', @(~, ~) obj.closeAdvanced());
        end

        function t = buildLimitsTab(obj, tab)
            t = struct();
            g = uigridlayout(tab, [6 3], 'RowHeight', {26, 26, 26, 26, 30, '1x'}, ...
                'ColumnWidth', {200, 120, '1x'});
            for k = 1:2
                uilabel(g, 'Text', sprintf('Channel %d max current (mA)', k));
                t.MaxCurrent(k) = uieditfield(g, 'numeric', 'ValueDisplayFormat', '%.0f', ...
                    'Limits', [0 doric.Channel.DeviceMaxCurrentmA], ...
                    'ValueChangedFcn', @(src, ~) obj.onLimit(k, src.Value), ...
                    'Tooltip', sprintf(['Requests above this limit are refused, never reduced. ' ...
                    'It cannot go above %d mA, the LED''s rated maximum; %d mA is Doric''s ' ...
                    'recommended operating current. Check the LED and preparation before ' ...
                    'raising it.'], doric.Channel.DeviceMaxCurrentmA, ...
                    doric.Channel.RecommendedMaxCurrentmA));
                uilabel(g, 'Text', '');
            end
            uilabel(g, 'Text', 'Settle window (ms)');
            t.SettleMs = uieditfield(g, 'numeric', 'ValueDisplayFormat', '%.0f', ...
                'ValueChangedFcn', @(src, ~) obj.guardRefresh(@() setSettle(src.Value)), ...
                'Tooltip', 'Time to wait for library error text after each command (0 = ack only)');
            uilabel(g, 'Text', '');
            uilabel(g, 'Text', 'Verbose output');
            t.Verbose = uicheckbox(g, 'Text', 'print to Command Window', ...
                'ValueChangedFcn', @(src, ~) obj.guardRefresh(@() setVerbose(src.Value)));
            uilabel(g, 'Text', '');
            t.SaveConfig = uibutton(g, 'Text', 'Save config...', ...
                'ButtonPushedFcn', @(~, ~) obj.onSaveConfig());
            t.LoadConfig = uibutton(g, 'Text', 'Load config...', ...
                'ButtonPushedFcn', @(~, ~) obj.onLoadConfig(), ...
                'Tooltip', 'Sets pending settings and limits; nothing is sent until Apply');
            function setSettle(value)
                obj.LightSource.SettleMs = value;
            end
            function setVerbose(value)
                obj.LightSource.Verbose = value;
            end
        end

        function refreshAdvanced(obj)
            a = obj.AdvancedControls;
            ls = obj.LightSource;
            for k = 1:2
                t = a.Channel(k);
                s = ls.Channels(k).Settings;
                t.CurrentMode.Value = char(s.CurrentMode);
                names = {'PeriodMs', 'TimeOnMs', 'StartingDelayMs', 'DelayBetweenSeqMs', ...
                    'RisingTimeMs', 'FallingTimeMs', 'NbOfSeq', 'NbOfPulsesPerSeq'};
                for f = 1:numel(names)
                    t.(names{f}).Value = s.(names{f});
                end
                t.TriggerType.Value = char(s.TriggerType);
                t.TriggerMode.Value = char(s.TriggerMode);
                t.IsRepeatableSequence.Value = s.IsRepeatableSequence;
                t.IsTTLOutput.Value = s.IsTTLOutput;
                t.ComplexTable.Data = obj.segmentsTable(s.ComplexSegments);
                points = s.CustomDataPoints;
                t.CustomInfo.Text = sprintf('%d points, peak %d mA', numel(points), ...
                    max([0, points]));
                cla(t.CustomAxes);
                if ~isempty(points)
                    plot(t.CustomAxes, 0:numel(points) - 1, points, 'Color', obj.Accent);
                end
                timed = any(s.Mode == [doric.Mode.Square, doric.Mode.Custom, doric.Mode.Complex]);
                obj.dim(t.TimingPanel, 'Timing', timed, s.Mode);
                obj.dim(t.TriggerPanel, 'Trigger', timed, s.Mode);
                obj.dim(t.ComplexPanel, 'Complex sequence', s.Mode == doric.Mode.Complex, s.Mode);
                obj.dim(t.CustomPanel, 'Custom waveform', s.Mode == doric.Mode.Custom, s.Mode);
                t.Revert.Enable = ~isempty(ls.Channels(k).CommandedSettings);
                t.ApplyChannel.Enable = strcmp(ls.State, 'Ready');
                a.Limits.MaxCurrent(k).Value = ls.Channels(k).MaxCurrentmA;
            end
            a.Limits.SettleMs.Value = ls.SettleMs;
            a.Limits.Verbose.Value = ls.Verbose;
        end

        function dim(obj, panel, title, relevant, mode)
            if relevant
                panel.Title = title;
                panel.ForegroundColor = [0 0 0];
            else
                panel.Title = sprintf('%s (not used by %s; still sent)', title, char(mode));
                panel.ForegroundColor = obj.DimColor;
            end
        end

        % ---- advanced callbacks ------------------------------------------------------------

        function onPreset(obj, k, src)
            name = src.Value;
            src.Value = '-';
            if strcmp(name, '-')
                return
            end
            ch = obj.LightSource.Channels(k);
            current = ch.Settings.CurrentmA;
            factory = str2func(['doric.ChannelSettings.' lower(name(1)) name(2:end)]);
            if obj.guard(@() setSettings(factory()))
                obj.appendLog(sprintf('Channel %d: preset %s (pending)', k, name));
            end
            obj.refresh();
            function setSettings(s)
                ch.Settings = s.with('CurrentmA', current);
            end
        end

        function onComplexEdit(obj, k, src)
            data = src.Data;
            obj.guardRefresh(@() obj.setPending(k, 'ComplexSegments', obj.tableSegments(data)));
        end

        function onAddSegment(obj, k)
            segments = obj.LightSource.Channels(k).Settings.ComplexSegments;
            obj.guardRefresh(@() obj.setPending(k, 'ComplexSegments', ...
                [segments, doric.ComplexSegment()]));
        end

        function onRemoveSegment(obj, k)
            segments = obj.LightSource.Channels(k).Settings.ComplexSegments;
            if isempty(segments)
                return
            end
            tableControl = obj.AdvancedControls.Channel(k).ComplexTable;
            row = numel(segments);
            if ~isempty(tableControl.Selection)
                row = tableControl.Selection(1, 1);
            end
            segments(row) = [];
            obj.guardRefresh(@() obj.setPending(k, 'ComplexSegments', segments));
        end

        function onImportWorkspace(obj, k)
            name = strtrim(obj.AdvancedControls.Channel(k).CustomVariable.Value);
            if ~isvarname(name)
                obj.showError('Enter the name of a base-workspace variable.');
                return
            end
            obj.guardRefresh(@() obj.setPending(k, 'CustomDataPoints', evalin('base', name)));
        end

        function onImportCsv(obj, k)
            [file, folder] = uigetfile({'*.csv;*.txt', 'CSV files'}, 'Custom waveform (mA)');
            if isequal(file, 0)
                return
            end
            obj.guardRefresh(@() obj.setPending(k, 'CustomDataPoints', ...
                readmatrix(fullfile(folder, file))));
        end

        function onRevert(obj, k)
            ch = obj.LightSource.Channels(k);
            if ~isempty(ch.CommandedSettings)
                ch.Settings = ch.CommandedSettings;
            end
            obj.refresh();
        end

        function onApplyChannel(obj, k)
            obj.guard(@() obj.LightSource.Channels(k).apply('Wait', false));
            obj.refresh();
        end

        function onLimit(obj, k, value)
            obj.guardRefresh(@() setLimit());
            function setLimit()
                obj.LightSource.Channels(k).MaxCurrentmA = value;
            end
        end

        function onSaveConfig(obj)
            [file, folder] = uiputfile('*.json', 'Save Doric LED configuration', 'doric_config.json');
            if ~isequal(file, 0)
                obj.saveConfigTo(fullfile(folder, file));
            end
        end

        function onLoadConfig(obj)
            [file, folder] = uigetfile('*.json', 'Load Doric LED configuration');
            if ~isequal(file, 0)
                obj.loadConfigFrom(fullfile(folder, file));
            end
        end

        % ---- helpers -----------------------------------------------------------------------

        function ok = editPending(obj, k, name, value)
            ok = obj.guard(@() obj.setPending(k, name, value));
            obj.refresh();
        end

        function setPending(obj, k, name, value)
            ch = obj.LightSource.Channels(k);
            s = ch.Settings;
            s.(name) = value;
            ch.Settings = s;
        end

        function ok = guardRefresh(obj, fn)
            ok = obj.guard(fn);
            obj.refresh();
        end

        function ok = guard(obj, fn)
        %GUARD Run fn; show any error to the user instead of letting a callback throw.
            try
                fn();
                ok = true;
            catch err
                ok = false;
                obj.showError(err.message);
            end
        end

        function showError(obj, message)
            obj.LastError = message;
            obj.appendLog(['ERROR: ' message]);
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.Controls.Status.Text = message;
            end
        end

        function appendLog(obj, text, deferred)
        % deferred: keep the line and show it at the next refresh (or flushLog).
            stamp = char(datetime('now', 'Format', 'HH:mm:ss.SSS'));
            obj.LogLines{end + 1} = sprintf('%s  %s', stamp, text);
            if numel(obj.LogLines) > 200
                obj.LogLines = obj.LogLines(end - 199:end);
            end
            obj.LogDirty = true;
            if nargin < 3 || ~deferred
                obj.flushLog();
            end
        end

        function flushLog(obj)
            if ~obj.LogDirty || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end
            obj.LogDirty = false;
            obj.Controls.Log.Value = obj.LogLines;
            try
                scroll(obj.Controls.Log, 'bottom');
            catch
            end
        end

        function data = segmentsTable(~, segments)
            modes = categorical(cellstr(string(enumeration('doric.ComplexMode'))));
            categoriesList = categories(modes);
            n = numel(segments);
            if n == 0
                data = table(categorical(cell(0, 1), categoriesList), zeros(0, 1), zeros(0, 1), ...
                    zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
                    'VariableNames', doric.gui.LightSourceApp.segmentColumns());
                return
            end
            data = table(categorical(arrayfun(@(s) char(s.Mode), segments, ...
                'UniformOutput', false)', categoriesList), [segments.CurrentmA]', ...
                [segments.PeriodMs]', [segments.TimeOnMs]', [segments.NbOfSeq]', ...
                [segments.NbOfPulsesPerSeq]', [segments.DelayBetweenSeqMs]', ...
                [segments.StartingDelayMs]', ...
                'VariableNames', doric.gui.LightSourceApp.segmentColumns());
        end

        function segments = tableSegments(~, data)
            segments = doric.ComplexSegment.empty(1, 0);
            names = doric.gui.LightSourceApp.segmentColumns();
            for r = 1:height(data)
                seg = doric.ComplexSegment('Mode', char(data.Mode(r)));
                for f = 2:numel(names)
                    seg.(names{f}) = data.(names{f})(r);
                end
                segments(r) = seg;
            end
        end

        function text = channelSuffix(~, channel)
            text = '';
            if ~isempty(channel)
                text = sprintf(' (channel %d)', channel);
            end
        end
    end

    methods (Static, Access = private)
        function dispatch(ref, name, evt)
            obj = ref.Handle;
            if isempty(obj) || ~isvalid(obj)
                return
            end
            try
                obj.onEvent(name, evt);
            catch
                % A listener must not break the LightSource's event processing.
            end
        end

        function value = pick(condition, a, b)
            if condition
                value = a;
            else
                value = b;
            end
        end

        function names = segmentColumns()
            names = {'Mode', 'CurrentmA', 'PeriodMs', 'TimeOnMs', 'NbOfSeq', 'NbOfPulsesPerSeq', ...
                'DelayBetweenSeqMs', 'StartingDelayMs'};
        end
    end
end
