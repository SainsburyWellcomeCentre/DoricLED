classdef LightSourceTest < matlab.unittest.TestCase
%LIGHTSOURCETEST State machine, commands, limits, events, faults and records of doric.LightSource.
%
%   Runs on doric.transport.SimulatedTransport only; no hardware is touched. AutoPoll is off so
%   every step is deterministic: blocking commands poll themselves, non-blocking ones are
%   followed by an explicit poll().
%
%   See also doric.LightSource, doric.Channel, doric.transport.SimulatedTransport

    properties
        Transport
        LightSource
    end

    methods (TestMethodSetup)
        function makeLightSource(testCase)
            testCase.Transport = doric.transport.SimulatedTransport();
            testCase.LightSource = doric.LightSource('Transport', testCase.Transport, ...
                'AutoPoll', false, 'InitWaitMs', 0, 'ListWaitMs', 0, 'OpenWaitMs', 0, ...
                'CloseWaitMs', 0, 'SettleMs', 0, 'ConnectTimeoutMs', 2000, ...
                'CommandTimeoutMs', 1000);
            testCase.addTeardown(@() delete(testCase.LightSource));
        end
    end

    methods (Test)
        % ---- connection --------------------------------------------------------------------

        function connectWalksTheStateMachine(testCase)
            ls = testCase.LightSource;
            states = {};
            listener = addlistener(ls, 'StateChanged', @(~, e) assignState(e));
            cleanup = onCleanup(@() delete(listener));
            testCase.verifyEqual(ls.State, 'Disconnected');
            result = ls.connect();
            testCase.verifyTrue(result.Ok);
            testCase.verifyEqual(ls.State, 'Ready');
            testCase.verifyEqual(states, {'Initialising', 'Opening', 'Ready'});
            testCase.verifyEqual(ls.Port, 5);
            testCase.verifyEqual(ls.DeviceName, 'LEDFLS_465_465');
            calls = {testCase.Transport.Calls.Command};
            testCase.verifyEqual(calls(1:4), {'INIT', 'LIST', 'OPEN', 'STOPALL'});
            clear cleanup
            function assignState(e)
                states{end + 1} = e.NewState; %#ok<AGROW>
            end
        end

        function constructorTouchesNothing(testCase)
            testCase.verifyEmpty(testCase.Transport.Calls);
            testCase.verifyFalse(testCase.Transport.isOpen());
        end

        function connectIsIdempotentAndDisconnectAlwaysWorks(testCase)
            ls = testCase.LightSource;
            ls.connect();
            result = ls.connect();
            testCase.verifyTrue(result.Ok);
            ls.disconnect();
            testCase.verifyEqual(ls.State, 'Disconnected');
            ls.disconnect();
            testCase.verifyEqual(ls.State, 'Disconnected');
            calls = {testCase.Transport.Calls.Command};
            testCase.verifyEqual(calls(end - 2:end), {'STOPALL', 'CLOSE', 'QUIT'});
        end

        function connectUsesGivenPortAndRefusesUnknownOne(testCase)
            ls = testCase.LightSource;
            ls.Port = 9;
            testCase.verifyError(@() ls.connect(), 'doric:LightSource:deviceNotFound');
            testCase.verifyEqual(ls.State, 'Faulted');
            testCase.verifyNotEmpty(ls.FaultReason);
            testCase.verifyFalse(testCase.Transport.isOpen());  % rolled back
        end

        function autoPortSkipsDevicesThatAreNotTheLightSource(testCase)
            % Seen on the rig: a rotary joint listed next to the LED driver.
            testCase.Transport.Devices = struct('Port', {3, 4}, 'Name', ...
                {'Assisted Rotary Joint (ARJ_24_Gen2)', 'LED Driver'});
            ls = testCase.LightSource;
            result = ls.connect();
            testCase.verifyTrue(result.Ok);
            testCase.verifyEqual(ls.Port, 4);
            testCase.verifyEqual(ls.DeviceName, 'LED Driver');
        end

        function severalMatchingDevicesNeedAnExplicitPort(testCase)
            testCase.Transport.Devices = struct('Port', {5, 7}, 'Name', {'LEDFLS', 'LED Driver'});
            testCase.verifyError(@() testCase.LightSource.connect(), ...
                'doric:LightSource:portRequired');
        end

        function noMatchingDeviceFailsAndPatternIsTheUsersChoice(testCase)
            testCase.Transport.Devices = struct('Port', 3, 'Name', 'Assisted Rotary Joint');
            ls = testCase.LightSource;
            testCase.verifyError(@() ls.connect(), 'doric:LightSource:deviceNotFound');
            testCase.verifyFalse(testCase.Transport.isOpen());   % nothing was opened
            testCase.Transport.Devices = struct('Port', {3, 6}, 'Name', ...
                {'Assisted Rotary Joint', 'Laser Driver'});
            ls.DeviceNamePattern = 'Laser';
            result = ls.connect();
            testCase.verifyTrue(result.Ok);
            testCase.verifyEqual(ls.Port, 6);
            testCase.verifyError(@() setPattern(ls, 5), 'doric:LightSource:invalidOption');

            function setPattern(lightSource, value)
                lightSource.DeviceNamePattern = value;
            end
        end

        function noDeviceListedFails(testCase)
            testCase.Transport.Devices = struct('Port', {}, 'Name', {});
            testCase.verifyError(@() testCase.LightSource.connect(), ...
                'doric:LightSource:deviceNotFound');
        end

        function connectFailureRollsBackAndReconnectRecovers(testCase)
            ls = testCase.LightSource;
            testCase.Transport.failNext('OPEN', 'Unable to connect device... Device not found');
            testCase.verifyError(@() ls.connect(), 'doric:LightSource:deviceNotFound');
            testCase.verifyEqual(ls.State, 'Faulted');
            result = ls.reconnect();
            testCase.verifyTrue(result.Ok);
            testCase.verifyEqual(ls.State, 'Ready');
        end

        function asyncConnectReportsThroughCallback(testCase)
            ls = testCase.LightSource;
            outcome = [];
            ls.connect('Wait', false, 'OnDone', @(r) assignOutcome(r));
            testCase.verifyEqual(ls.State, 'Initialising');
            for k = 1:20
                ls.poll();
                if ~isempty(outcome)
                    break
                end
                pause(0.01);
            end
            testCase.verifyNotEmpty(outcome);
            testCase.verifyTrue(outcome.Ok);
            testCase.verifyEqual(ls.State, 'Ready');
            function assignOutcome(r)
                outcome = r;
            end
        end

        function portIsLockedWhileConnected(testCase)
            ls = testCase.LightSource;
            ls.connect();
            testCase.verifyError(@() assign(ls, 'Port', 7), 'doric:LightSource:portLocked');
        end

        function listDevicesWithoutConnectingOpensNothing(testCase)
            devices = testCase.LightSource.listDevices();
            testCase.verifyEqual(devices.Port, 5);
            testCase.verifyEqual(testCase.LightSource.State, 'Disconnected');
            calls = {testCase.Transport.Calls.Command};
            testCase.verifyEqual(calls, {'INIT', 'LIST', 'QUIT'});
        end

        % ---- commands ----------------------------------------------------------------------

        function commandsNeedReady(testCase)
            ls = testCase.LightSource;
            testCase.verifyError(@() ls.Channels(1).start(), 'doric:LightSource:notReady');
            testCase.verifyError(@() ls.startAll(), 'doric:LightSource:notReady');
        end

        function applyStartStopUpdateCommandedState(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ch = ls.Channels(1);
            testCase.verifyEqual(ch.CommandedState, 'Unconfigured');
            settings = doric.ChannelSettings.cw(120);
            ch.apply(settings);
            testCase.verifyEqual(ch.CommandedSettings, settings);
            testCase.verifyEqual(ch.CommandedCurrentmA, 120);
            testCase.verifyEqual(ch.CommandedState, 'Configured');
            ch.start();
            testCase.verifyTrue(ch.IsRunning);
            testCase.verifyEqual(ch.CommandedState, 'Running');
            ch.setCurrent(150);
            testCase.verifyEqual(ch.CommandedCurrentmA, 150);
            ch.stop();
            testCase.verifyFalse(ch.IsRunning);
            testCase.verifyEqual(ch.CommandedState, 'Stopped');
            settingsCall = testCase.Transport.callsOf('SETTINGS');
            testCase.verifyEqual(settingsCall.Args.Settings.CurrentmA, 120);
        end

        function applyRestartsARunningChannel(testCase)
            % The device keeps emitting the old settings until the next start (rig 2026-09-21).
            ls = testCase.LightSource;
            ls.connect();
            ch = ls.Channels(1);
            n = numel(testCase.Transport.Calls);
            ch.apply(doric.ChannelSettings.cw(30));     % stopped: settings only
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS'});
            ch.start();
            n = numel(testCase.Transport.Calls);
            ch.apply(doric.ChannelSettings.cw(40));     % running: settings, then start
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS', 'START'});
            testCase.verifyTrue(ch.IsRunning);
            testCase.verifyEqual(ch.CommandedSettings.CurrentmA, 40);
            n = numel(testCase.Transport.Calls);
            ch.apply(doric.ChannelSettings.cw(50), 'Restart', false);
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS'});
        end

        function nonBlockingApplyRestartsOnlyAfterTheSettingsSucceed(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ch = ls.Channels(1);
            ch.apply(doric.ChannelSettings.cw(20));
            ch.start();
            n = numel(testCase.Transport.Calls);
            heard = {};
            ch.apply(doric.ChannelSettings.cw(30), 'Wait', false, ...
                'OnDone', @(r) hear(r.Command));
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS'});
            ls.poll();
            ls.poll();
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS', 'START'});
            testCase.verifyEqual(heard, {'START'});

            % Refused settings never restart the old ones.
            n = numel(testCase.Transport.Calls);
            testCase.Transport.failNext('SETTINGS', 'Error: settings refused');
            testCase.verifyError(@() ch.apply(doric.ChannelSettings.cw(35)), ...
                'doric:Channel:libraryError');
            testCase.verifyEqual(commandsSince(testCase.Transport, n), {'SETTINGS'});

            function hear(command)
                heard{end + 1} = command;
            end
        end

        function applyWithoutArgumentUsesPendingSettings(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(2).Settings = doric.ChannelSettings.extTTL(75);
            ls.Channels(2).apply();
            testCase.verifyEqual(ls.Channels(2).CommandedSettings.CurrentmA, 75);
            call = testCase.Transport.callsOf('SETTINGS');
            testCase.verifyEqual(call.Args.ch, 1);
        end

        function applyBothChannels(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.apply(doric.ChannelSettings.cw(10), doric.ChannelSettings.cw(20));
            testCase.verifyEqual(ls.Channels(1).CommandedCurrentmA, 10);
            testCase.verifyEqual(ls.Channels(2).CommandedCurrentmA, 20);
            ls.apply([], doric.ChannelSettings.cw(30));
            testCase.verifyEqual(ls.Channels(1).CommandedCurrentmA, 10);
            testCase.verifyEqual(ls.Channels(2).CommandedCurrentmA, 30);
        end

        function startAllAndStopAllTrackChannels(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).apply(doric.ChannelSettings.cw(10));
            ls.startAll();
            testCase.verifyTrue(ls.Channels(1).IsRunning);
            testCase.verifyFalse(ls.Channels(2).IsRunning);   % never configured
            ls.stopAll();
            testCase.verifyFalse(ls.Channels(1).IsRunning);
        end

        function stopAllWorksInEveryState(testCase)
            ls = testCase.LightSource;
            result = ls.stopAll();          % disconnected: nothing to stop
            testCase.verifyTrue(result.Ok);
            ls.connect();
            testCase.verifyTrue(ls.stopAll().Ok);
            testCase.Transport.failNext('CURRENT', 'Unable to send current... Device not found');
            testCase.verifyError(@() ls.Channels(1).setCurrent(10), ...
                'doric:Channel:libraryError');
            testCase.verifyEqual(ls.State, 'Faulted');
            testCase.verifyTrue(ls.stopAll().Ok);   % still allowed while Faulted
        end

        function nonBlockingCommandsCompleteOnPoll(testCase)
            ls = testCase.LightSource;
            ls.connect();
            completed = {};
            listener = addlistener(ls, 'CommandCompleted', @(~, e) record(e));
            cleanup = onCleanup(@() delete(listener));
            result = ls.Channels(1).apply(doric.ChannelSettings.cw(20), 'Wait', false);
            testCase.verifyEmpty(result.Ok);
            testCase.verifyEmpty(ls.Channels(1).CommandedSettings);
            ls.poll();
            testCase.verifyEqual(ls.Channels(1).CommandedCurrentmA, 20);
            testCase.verifyEqual(completed, {'SETTINGS'});
            clear cleanup
            function record(e)
                completed{end + 1} = e.Command; %#ok<AGROW>
            end
        end

        function onDoneCallbackRuns(testCase)
            ls = testCase.LightSource;
            ls.connect();
            seen = [];
            ls.Channels(1).setCurrent(5, 'Wait', false, 'OnDone', @(r) assignSeen(r));
            ls.poll();
            testCase.verifyTrue(seen.Ok);
            function assignSeen(r)
                seen = r;
            end
        end

        % ---- limits ------------------------------------------------------------------------

        function theLedRatingCannotBeRaisedAway(testCase)
            % 465 nm head: rated 1000 mA, 700 mA recommended (Doric LED Light Source manual
            % V2.1.1, tables 5.8 and 5.2). No path may command more than the rating.
            ls = testCase.LightSource;
            testCase.verifyEqual(doric.Channel.DeviceMaxCurrentmA, 1000);
            testCase.verifyEqual(doric.Channel.RecommendedMaxCurrentmA, 700);
            testCase.verifyEqual(ls.Channels(1).MaxCurrentmA, 700);
            testCase.verifyEqual(ls.Channels(2).MaxCurrentmA, 700);

            testCase.verifyError(@() assign(ls.Channels(1), 'MaxCurrentmA', 1001), ...
                'doric:Channel:aboveDeviceLimit');
            testCase.verifyError(@() assign(ls.Channels(1), 'MaxCurrentmA', 2000), ...
                'doric:Channel:aboveDeviceLimit');
            testCase.verifyEqual(ls.Channels(1).MaxCurrentmA, 700);   % unchanged

            ls.Channels(1).MaxCurrentmA = 1000;                       % the rating itself is fine
            testCase.verifyEqual(ls.Channels(1).MaxCurrentmA, 1000);

            ls.connect();
            testCase.verifyError(@() ls.Channels(1).setCurrent(1001), 'doric:Channel:overCurrent');
            testCase.verifyError(@() ls.Channels(1).apply(doric.ChannelSettings.cw(1500)), ...
                'doric:Channel:overCurrent');
            testCase.verifyEmpty(testCase.Transport.callsOf('CURRENT'));
            testCase.verifyEmpty(testCase.Transport.callsOf('SETTINGS'));
        end

        function aConfigAboveTheLedRatingLoadsNothing(testCase)
            ls = testCase.LightSource;
            file = [tempname '.json'];
            cleanup = onCleanup(@() delete(file));
            ls.Channels(1).MaxCurrentmA = 500;
            ls.Channels(2).Settings = doric.ChannelSettings.cw(50);
            ls.saveConfig(file);
            text = regexprep(fileread(file), '("MaxCurrentmA":\s*)500', '$11500');
            fid = fopen(file, 'w'); fwrite(fid, text); fclose(fid);

            testCase.verifyError(@() ls.loadConfig(file), 'doric:Channel:aboveDeviceLimit');
            % All or nothing: the second channel's settings must not have been applied either.
            testCase.verifyEqual(ls.Channels(1).MaxCurrentmA, 500);
            testCase.verifyEqual(ls.Channels(2).Settings.CurrentmA, 50);
            clear cleanup
        end

        function currentAboveLimitIsRefusedNotClamped(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).MaxCurrentmA = 200;
            testCase.verifyError(@() ls.Channels(1).setCurrent(201), 'doric:Channel:overCurrent');
            testCase.verifyError(@() ls.Channels(1).apply(doric.ChannelSettings.cw(500)), ...
                'doric:Channel:overCurrent');
            testCase.verifyEmpty(testCase.Transport.callsOf('CURRENT'));
            ls.Channels(1).setCurrent(200);
            testCase.verifyEqual(ls.Channels(1).CommandedCurrentmA, 200);
        end

        function limitAppliesToSegmentsAndCustomPoints(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).MaxCurrentmA = 100;
            settings = doric.ChannelSettings.complex(doric.ComplexSegment('CurrentmA', 300));
            testCase.verifyError(@() ls.Channels(1).apply(settings), 'doric:Channel:overCurrent');
            settings = doric.ChannelSettings.custom([0 50 500]);
            testCase.verifyError(@() ls.Channels(1).apply(settings), 'doric:Channel:overCurrent');
        end

        function limitCannotDropBelowCommandedCurrent(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).setCurrent(300);
            testCase.verifyError(@() assign(ls.Channels(1), 'MaxCurrentmA', 100), ...
                'doric:Channel:limitBelowCommanded');
            ls.Channels(1).setCurrent(50);
            ls.Channels(1).MaxCurrentmA = 100;
            testCase.verifyEqual(ls.Channels(1).MaxCurrentmA, 100);
        end

        function invalidCurrentsAreRejected(testCase)
            ls = testCase.LightSource;
            ls.connect();
            testCase.verifyError(@() ls.Channels(1).setCurrent(10.5), ...
                'doric:Channel:invalidCurrent');
            testCase.verifyError(@() ls.Channels(1).setCurrent(-1), ...
                'doric:Channel:invalidCurrent');
            testCase.verifyError(@() ls.Channels(1).apply(42), 'doric:Channel:invalidSettings');
        end

        % ---- faults ------------------------------------------------------------------------

        function libraryErrorOnCommandFailsAndFaultsOnDeviceLoss(testCase)
            ls = testCase.LightSource;
            ls.connect();
            faults = {};
            listener = addlistener(ls, 'Faulted', @(~, e) assignFault(e));
            cleanup = onCleanup(@() delete(listener));
            testCase.Transport.failNext('SETTINGS', 'Unable to send settings... Device not found');
            testCase.verifyError(@() ls.Channels(1).apply(doric.ChannelSettings.cw(10)), ...
                'doric:Channel:libraryError');
            testCase.verifyEqual(ls.State, 'Faulted');
            testCase.verifyNumElements(faults, 1);
            testCase.verifyEmpty(ls.Channels(1).CommandedSettings);
            clear cleanup
            function assignFault(e)
                faults{end + 1} = e.Reason; %#ok<AGROW>
            end
        end

        function otherLibraryErrorsFailTheCommandWithoutFaulting(testCase)
            ls = testCase.LightSource;
            ls.connect();
            testCase.Transport.failNext('START', ...
                'Unable to start channel... Wrong controller for LightSource driver');
            testCase.verifyError(@() ls.Channels(1).start(), 'doric:Channel:libraryError');
            testCase.verifyEqual(ls.State, 'Ready');
            testCase.verifyFalse(ls.Channels(1).IsRunning);
        end

        function timeoutFaultsAndIsReported(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.CommandTimeoutMs = 100;
            testCase.Transport.hangNext('CURRENT');
            testCase.verifyError(@() ls.Channels(1).setCurrent(10), 'doric:Channel:timeout');
            testCase.verifyEqual(ls.State, 'Faulted');
            testCase.verifySubstring(ls.FaultReason, 'CURRENT');
        end

        function bridgeExitFaultsAndFailsPendingCommands(testCase)
            ls = testCase.LightSource;
            ls.connect();
            outcome = [];
            testCase.Transport.hangNext('CURRENT');   % in flight when the bridge dies
            ls.Channels(1).setCurrent(10, 'Wait', false, 'OnDone', @(r) assignOutcome(r));
            testCase.Transport.crash(3);
            ls.poll();
            testCase.verifyEqual(ls.State, 'Faulted');
            testCase.verifyFalse(outcome.Ok);
            testCase.verifyEqual(outcome.Code, 'bridgeExited');
            testCase.verifyError(@() ls.Channels(1).setCurrent(1), 'doric:LightSource:notReady');
            function assignOutcome(r)
                outcome = r;
            end
        end

        function faultedStateClearsOnDisconnect(testCase)
            ls = testCase.LightSource;
            ls.connect();
            testCase.Transport.crash(1);
            ls.poll();
            testCase.verifyEqual(ls.State, 'Faulted');
            ls.disconnect();
            testCase.verifyEqual(ls.State, 'Disconnected');
            testCase.verifyEmpty(ls.FaultReason);
        end

        % ---- safety ------------------------------------------------------------------------

        function deleteStopsTheLightAndClosesTheDevice(testCase)
            ls = testCase.LightSource;
            transport = testCase.Transport;
            ls.connect();
            ls.Channels(1).apply(doric.ChannelSettings.cw(10));
            ls.Channels(1).start();
            delete(ls);
            testCase.verifyFalse(transport.Device(1).Channels(1).Running);
            testCase.verifyFalse(transport.Device(1).Open);
            testCase.verifyFalse(transport.isOpen());
        end

        function connectStopsEverythingFirst(testCase)
            ls = testCase.LightSource;
            ls.connect();
            calls = {testCase.Transport.Calls.Command};
            testCase.verifyEqual(calls{end}, 'STOPALL');
            testCase.verifyEqual(ls.Channels(1).CommandedState, 'Unconfigured');
        end

        % ---- records -----------------------------------------------------------------------

        function logCollectsCommandsAndLibraryText(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).setCurrent(10);
            entries = ls.log();
            testCase.verifyTrue(any(entries.Command == "CURRENT"));
            testCase.verifyTrue(any(entries.Kind == "library"));
            testCase.verifyTrue(any(entries.Kind == "state"));
        end

        function statsSummariseLatencies(testCase)
            ls = testCase.LightSource;
            ls.connect();
            for k = 1:3
                ls.Channels(1).setCurrent(k);
            end
            t = ls.stats();
            row = t(t.Command == "CURRENT", :);
            testCase.verifyEqual(row.Count, 3);
            testCase.verifyGreaterThanOrEqual(row.MaxMs, 0);
        end

        function recordIsAPlainStruct(testCase)
            ls = testCase.LightSource;
            ls.connect();
            ls.Channels(1).apply(doric.ChannelSettings.cw(10));
            s = ls.record();
            testCase.verifyClass(s, 'struct');
            testCase.verifyEqual(s.Port, 5);
            testCase.verifyEqual(s.Channels(1).CommandedSettings.Mode, 'CW');
            testCase.verifyClass(s.Channels(1).PendingSettings, 'struct');
            testCase.verifyClass(s.Log, 'struct');
            % Nothing in the record may be a handle or an object.
            text = jsonencode(s);
            testCase.verifyGreaterThan(numel(text), 100);
        end

        function configRoundTripsThroughJson(testCase)
            ls = testCase.LightSource;
            file = [tempname '.json'];
            cleanup = onCleanup(@() delete(file));
            ls.Channels(1).Settings = doric.ChannelSettings.complex();
            ls.Channels(2).Settings = doric.ChannelSettings.custom([1 2 3]);
            ls.Channels(1).MaxCurrentmA = 555;
            ls.saveConfig(file);

            other = doric.LightSource('Transport', doric.transport.SimulatedTransport(), ...
                'AutoPoll', false);
            otherCleanup = onCleanup(@() delete(other));
            other.loadConfig(file);
            testCase.verifyEqual(other.Channels(1).Settings, ls.Channels(1).Settings);
            testCase.verifyEqual(other.Channels(2).Settings, ls.Channels(2).Settings);
            testCase.verifyEqual(other.Channels(1).MaxCurrentmA, 555);
            testCase.verifyEmpty(other.Transport.Calls);   % loading sends nothing
            clear cleanup otherCleanup
        end

        function libraryMessagesReachListeners(testCase)
            ls = testCase.LightSource;
            texts = {};
            listener = addlistener(ls, 'LibraryMessage', @(~, e) collect(e));
            cleanup = onCleanup(@() delete(listener));
            ls.connect();
            testCase.verifyTrue(any(contains(texts, 'Port #5')));
            clear cleanup
            function collect(e)
                texts{end + 1} = e.Text; %#ok<AGROW>
            end
        end
    end
end

function assign(obj, name, value)
% Assign a property from a function handle, so verifyError sees the setter's own error.
    obj.(name) = value;
end

function commands = commandsSince(transport, n)
% Commands the transport received after the first n calls.
    commands = {transport.Calls(n + 1:end).Command};
end
