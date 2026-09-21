classdef GuiTest < matlab.unittest.TestCase
%GUITEST doric.gui.LightSourceApp on the simulated transport, with hidden windows.
%
%   Controls are driven the way a user would: set a component's Value, then invoke its callback.
%   Nothing may reach the device before Apply or Start.
%
%   See also doric.gui.LightSourceApp, doric.LightSource

    properties
        Transport
        App
    end

    methods (TestMethodSetup)
        function makeApp(testCase)
            testCase.Transport = doric.transport.SimulatedTransport();
            testCase.App = doric.gui.LightSourceApp('Transport', testCase.Transport, ...
                'Visible', false, 'AutoPoll', false, 'InitWaitMs', 0, 'ListWaitMs', 0, ...
                'OpenWaitMs', 0, 'CloseWaitMs', 0, 'SettleMs', 0);
            testCase.addTeardown(@() testCase.App.close());
        end
    end

    methods (Test)
        function opensWithBothChannelsExtTtlAndZeroCurrent(testCase)
            app = testCase.App;
            testCase.verifyEqual(app.selectedChannels(), [1 2]);
            for k = 1:2
                testCase.verifyEqual(app.Controls.Mode(k).Value, 'ExtTTL');
                testCase.verifyEqual(app.Controls.Intensity(k).Value, 0);
                testCase.verifyEqual(app.LightSource.Channels(k).Settings.Mode, doric.Mode.ExtTTL);
                testCase.verifyEqual(app.LightSource.Channels(k).Settings.CurrentmA, 0);
            end
            testCase.verifyEmpty(testCase.Transport.Calls);        % nothing sent
            testCase.verifyEqual(app.LightSource.State, 'Disconnected');
            testCase.verifyEqual(app.Controls.StopAll.Enable, matlab.lang.OnOffSwitchState('on'));
        end

        function apiDefaultsAreUnchangedByTheGui(testCase)
            testCase.verifyEqual(doric.ChannelSettings().Mode, doric.Mode.Off);
        end

        function connectButtonConnectsAndDisconnects(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.verifyEqual(app.LightSource.State, 'Ready');
            testCase.verifyEqual(app.Controls.Connect.Text, 'Disconnect');
            testCase.press(app.Controls.Connect);
            testCase.verifyEqual(app.LightSource.State, 'Disconnected');
        end

        function editingControlsChangesOnlyPendingSettings(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.setValue(app.Controls.Mode(1), 'CW');
            testCase.setValue(app.Controls.Intensity(1), 150);
            testCase.verifyEqual(app.LightSource.Channels(1).Settings.Mode, doric.Mode.CW);
            testCase.verifyEqual(app.LightSource.Channels(1).Settings.CurrentmA, 150);
            testCase.verifyEmpty(testCase.Transport.callsOf('SETTINGS'));
            testCase.verifyEqual(app.Controls.Intensity(1).BackgroundColor, app.PendingColor);

            testCase.press(app.Controls.Apply);
            app.LightSource.poll();
            calls = testCase.Transport.callsOf('SETTINGS');
            testCase.verifyNumElements(calls, 2);          % both channels are selected
            testCase.verifyEqual(calls(1).Args.Settings.CurrentmA, 150);
            app.refresh();
            testCase.verifySubstring(app.Controls.Commanded(1).Text, 'CW');
        end

        function applyAndStartFollowTheSelection(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.setValue(app.Controls.Select(2), false);
            testCase.verifyEqual(app.selectedChannels(), 1);
            testCase.press(app.Controls.Start);
            app.LightSource.poll();
            testCase.verifyNumElements(testCase.Transport.callsOf('START'), 1);
            testCase.verifyTrue(app.LightSource.Channels(1).IsRunning);
            testCase.verifyFalse(app.LightSource.Channels(2).IsRunning);
            testCase.press(app.Controls.Stop);
            app.LightSource.poll();
            testCase.verifyFalse(app.LightSource.Channels(1).IsRunning);
        end

        function startAppliesPendingChangesFirst(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.setValue(app.Controls.Intensity(1), 60);
            testCase.press(app.Controls.Start);
            app.LightSource.poll();
            settings = testCase.Transport.callsOf('SETTINGS');
            testCase.verifyEqual(settings(1).Args.Settings.CurrentmA, 60);
            testCase.verifyNotEmpty(testCase.Transport.callsOf('START'));
        end

        function liveIntensitySendsCurrentWhileRunning(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.press(app.Controls.Apply);
            testCase.press(app.Controls.Start);
            app.LightSource.poll();
            testCase.setValue(app.Controls.Intensity(1), 90);
            app.LightSource.poll();
            calls = testCase.Transport.callsOf('CURRENT');
            testCase.verifyEqual(calls(end).Args.ma, 90);

            testCase.setValue(app.Controls.Live, false);
            testCase.setValue(app.Controls.Intensity(1), 95);
            app.LightSource.poll();
            calls = testCase.Transport.callsOf('CURRENT');
            testCase.verifyEqual(calls(end).Args.ma, 90);   % nothing new was sent
        end

        function stopAllWorksFromTheButtonAndTheEscapeKey(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.press(app.Controls.Apply);
            testCase.press(app.Controls.Start);
            app.LightSource.poll();
            testCase.press(app.Controls.StopAll);
            app.LightSource.poll();
            testCase.verifyFalse(app.LightSource.Channels(1).IsRunning);

            testCase.press(app.Controls.Start);
            app.LightSource.poll();
            app.Figure.WindowKeyPressFcn(app.Figure, struct('Key', 'escape'));
            app.LightSource.poll();
            testCase.verifyFalse(app.LightSource.Channels(1).IsRunning);
        end

        function overCurrentIsRefusedWithAMessage(testCase)
            app = testCase.App;
            testCase.connectApp();
            app.LightSource.Channels(1).MaxCurrentmA = 100;
            testCase.setValue(app.Controls.Select(2), false);
            testCase.setValue(app.Controls.Intensity(1), 500);
            testCase.press(app.Controls.Apply);
            app.LightSource.poll();
            testCase.verifyEmpty(testCase.Transport.callsOf('SETTINGS'));
            testCase.verifySubstring(app.LastError, 'MaxCurrentmA');
        end

        function faultIsShownInTheWindow(testCase)
            app = testCase.App;
            testCase.connectApp();
            testCase.Transport.crash(7);
            app.LightSource.poll();
            app.refresh();
            testCase.verifySubstring(app.Controls.State.Text, 'Faulted');
            testCase.verifyEqual(app.Controls.Lamp.Color, app.Danger);
        end

        % ---- advanced window ---------------------------------------------------------------

        function advancedWindowEditsTheSamePendingSettings(testCase)
            app = testCase.App;
            app.openAdvanced();
            channel = app.AdvancedControls.Channel(1);
            testCase.setValue(channel.PeriodMs, 250);
            testCase.setValue(channel.TimeOnMs, 125);
            testCase.setValue(channel.TriggerType, 'Gated');
            testCase.setValue(channel.IsTTLOutput, true);
            testCase.setValue(channel.CurrentMode, 'Overdrive');
            s = app.LightSource.Channels(1).Settings;
            testCase.verifyEqual([s.PeriodMs, s.TimeOnMs], [250, 125]);
            testCase.verifyEqual(s.TriggerType, doric.TriggerType.Gated);
            testCase.verifyTrue(s.IsTTLOutput);
            testCase.verifyEqual(s.CurrentMode, doric.CurrentMode.Overdrive);
            testCase.verifyEmpty(testCase.Transport.Calls);
            testCase.verifySubstring(app.Controls.Hint(1).Text, 'Advanced');
        end

        function invalidAdvancedValueIsRefusedAndReverted(testCase)
            app = testCase.App;
            app.openAdvanced();
            testCase.setValue(app.AdvancedControls.Channel(1).NbOfSeq, 70000);
            testCase.verifyNotEmpty(app.LastError);
            testCase.verifyEqual(app.LightSource.Channels(1).Settings.NbOfSeq, 1);
            testCase.verifyEqual(app.AdvancedControls.Channel(1).NbOfSeq.Value, 1);
        end

        function presetFillsEveryFieldAndKeepsIntensity(testCase)
            app = testCase.App;
            app.openAdvanced();
            testCase.setValue(app.Controls.Intensity(2), 70);
            testCase.setValue(app.AdvancedControls.Channel(2).Preset, 'Complex');
            s = app.LightSource.Channels(2).Settings;
            testCase.verifyEqual(s.Mode, doric.Mode.Complex);
            testCase.verifyEqual(numel(s.ComplexSegments), 3);
            testCase.verifyEqual(s.CurrentmA, 70);
            testCase.verifyEqual(app.Controls.Mode(2).Value, 'Complex');    % windows stay in sync
            testCase.verifyEqual(height(app.AdvancedControls.Channel(2).ComplexTable.Data), 3);
        end

        function complexSegmentsCanBeAddedEditedAndRemoved(testCase)
            app = testCase.App;
            app.openAdvanced();
            channel = app.AdvancedControls.Channel(1);
            testCase.press(channel.AddSegment);
            testCase.verifyEqual(numel(app.LightSource.Channels(1).Settings.ComplexSegments), 1);
            data = channel.ComplexTable.Data;
            data.CurrentmA(1) = 123;
            data.Mode(1) = 'Sine';
            channel.ComplexTable.Data = data;
            channel.ComplexTable.CellEditCallback(channel.ComplexTable, []);
            segment = app.LightSource.Channels(1).Settings.ComplexSegments(1);
            testCase.verifyEqual(segment.CurrentmA, 123);
            testCase.verifyEqual(segment.Mode, doric.ComplexMode.Sine);
            testCase.press(channel.RemoveSegment);
            testCase.verifyEmpty(app.LightSource.Channels(1).Settings.ComplexSegments);
        end

        function customWaveformImportsFromTheWorkspace(testCase)
            app = testCase.App;
            app.openAdvanced();
            assignin('base', 'doricTestWaveform', [0 10 20 30]);
            cleanup = onCleanup(@() evalin('base', 'clear doricTestWaveform'));
            channel = app.AdvancedControls.Channel(1);
            channel.CustomVariable.Value = 'doricTestWaveform';
            testCase.press(channel.ImportWorkspace);
            testCase.verifyEqual(app.LightSource.Channels(1).Settings.CustomDataPoints, ...
                [0 10 20 30]);
            testCase.verifySubstring(channel.CustomInfo.Text, '4 points');
            testCase.press(channel.ClearCustom);
            testCase.verifyEmpty(app.LightSource.Channels(1).Settings.CustomDataPoints);
            clear cleanup
        end

        function noControlCanAskForMoreThanTheLedRating(testCase)
            % The rating is the LED's, not a preference: the boxes themselves stop at it.
            app = testCase.App;
            rated = doric.Channel.DeviceMaxCurrentmA;
            for k = 1:2
                testCase.verifyEqual(app.Controls.Intensity(k).Limits, [0 rated]);
                % The slider tracks MaxCurrentmA, which can never be above the rating.
                testCase.verifyLessThanOrEqual(app.Controls.Slider(k).Limits(2), rated);
            end
            app.openAdvanced();
            for k = 1:2
                testCase.verifyEqual(app.AdvancedControls.Limits.MaxCurrent(k).Limits, [0 rated]);
            end
            testCase.connectApp();
            % Raising the limit past the rating is refused and leaves the limit alone.
            app.AdvancedControls.Limits.MaxCurrent(1).Value = rated;
            app.AdvancedControls.Limits.MaxCurrent(1).ValueChangedFcn( ...
                app.AdvancedControls.Limits.MaxCurrent(1), []);
            testCase.verifyEqual(app.LightSource.Channels(1).MaxCurrentmA, rated);
            testCase.verifyError(@() assignLimit(app.LightSource.Channels(1), rated + 1), ...
                'doric:Channel:aboveDeviceLimit');
            testCase.verifyEqual(app.LightSource.Channels(1).MaxCurrentmA, rated);

            function assignLimit(channel, value)
                channel.MaxCurrentmA = value;
            end
        end

        function limitsTabRefusesALimitBelowTheCommandedCurrent(testCase)
            app = testCase.App;
            testCase.connectApp();
            app.openAdvanced();
            testCase.setValue(app.AdvancedControls.Limits.MaxCurrent(1), 500);
            testCase.verifyEqual(app.LightSource.Channels(1).MaxCurrentmA, 500);
            app.LightSource.Channels(1).setCurrent(400);
            testCase.setValue(app.AdvancedControls.Limits.MaxCurrent(1), 100);
            testCase.verifySubstring(app.LastError, 'limit');
            testCase.verifyEqual(app.LightSource.Channels(1).MaxCurrentmA, 500);
        end

        function configurationCanBeSavedAndLoaded(testCase)
            app = testCase.App;
            file = [tempname '.json'];
            cleanup = onCleanup(@() delete(file));
            testCase.setValue(app.Controls.Mode(1), 'Square');
            testCase.setValue(app.Controls.Intensity(1), 77);
            app.saveConfigTo(file);
            testCase.setValue(app.Controls.Intensity(1), 10);
            app.loadConfigFrom(file);
            testCase.verifyEqual(app.LightSource.Channels(1).Settings.CurrentmA, 77);
            testCase.verifyEqual(app.Controls.Intensity(1).Value, 77);
            testCase.verifyEmpty(testCase.Transport.Calls);   % loading sends nothing
            clear cleanup
        end

        % ---- ownership ---------------------------------------------------------------------

        function closingAnOwningWindowDisconnects(testCase)
            app = testCase.App;
            transport = testCase.Transport;
            testCase.connectApp();
            app.openAdvanced();
            app.close();
            testCase.verifyFalse(transport.isOpen());
            testCase.verifyFalse(transport.Device(1).Channels(1).Running);
        end

        function attachedWindowLeavesTheDeviceOpen(testCase)
            ls = doric.LightSource('Transport', doric.transport.SimulatedTransport(), ...
                'AutoPoll', false, 'InitWaitMs', 0, 'ListWaitMs', 0, 'OpenWaitMs', 0, ...
                'SettleMs', 0);
            cleanup = onCleanup(@() delete(ls));
            ls.connect();
            ls.Channels(1).Settings = doric.ChannelSettings.cw(42);
            attached = doric.gui.LightSourceApp(ls, 'Visible', false);
            testCase.verifyFalse(attached.OwnsLightSource);
            % An attached window keeps the host's pending settings.
            testCase.verifyEqual(ls.Channels(1).Settings.CurrentmA, 42);
            testCase.verifyEqual(attached.Controls.Mode(1).Value, 'CW');
            attached.close();
            testCase.verifyEqual(ls.State, 'Ready');
            testCase.verifyTrue(ls.Transport.isOpen());
            clear cleanup
        end

        function attachingRejectsLightSourceOptions(testCase)
            ls = doric.LightSource('Transport', doric.transport.SimulatedTransport());
            cleanup = onCleanup(@() delete(ls));
            testCase.verifyError(@() doric.gui.LightSourceApp(ls, 'Port', 5), ...
                'doric:LightSourceApp:invalidOption');
            clear cleanup
        end
    end

    % ---- helpers ---------------------------------------------------------------------------

    methods (Access = private)
        function connectApp(testCase)
            app = testCase.App;
            testCase.press(app.Controls.Connect);
            for k = 1:50
                app.LightSource.poll();
                if ~strcmp(app.LightSource.State, 'Initialising') && ...
                        ~strcmp(app.LightSource.State, 'Opening')
                    break
                end
                pause(0.01);
            end
            app.refresh();
            testCase.assertEqual(app.LightSource.State, 'Ready');
        end

        function press(~, button)
            button.ButtonPushedFcn(button, []);
        end

        function setValue(~, control, value)
            control.Value = value;
            if ~isempty(control.ValueChangedFcn)
                control.ValueChangedFcn(control, []);
            end
        end
    end
end
