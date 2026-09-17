classdef BridgeProtocolTest < matlab.unittest.TestCase
%BRIDGEPROTOCOLTEST doric_bridge.exe and BridgeTransport against the real protocol, no hardware.
%
%   Every test runs the bridge with --simulate: the executable, its argument parsing, its
%   SETTINGS parser, its error codes and its stdin-EOF safety path are exercised, but
%   DoricSystem.dll is never loaded and no device is touched.
%
%   Skipped when not on Windows or when bin/doric_bridge.exe is missing (build it with
%   doric.build()).
%
%   See also doric.transport.BridgeTransport, docs/bridge-protocol.md, native/doric_bridge

    properties
        Transport
    end

    methods (TestMethodSetup)
        function makeTransport(testCase)
            testCase.assumeTrue(ispc, 'The bridge runs on Windows only.');
            cfg = doric.config();
            testCase.assumeTrue(isfile(cfg.BridgeExe), ...
                sprintf('%s is missing; run doric.build().', cfg.BridgeExe));
            testCase.Transport = doric.transport.BridgeTransport('Simulate', true, ...
                'SettleMs', 0);
            testCase.addTeardown(@() delete(testCase.Transport));
        end
    end

    methods (Test)
        function openPerformsHandshake(testCase)
            t = testCase.Transport;
            t.open();
            testCase.verifyTrue(t.isOpen());
            testCase.verifyNotEmpty(t.BridgeVersion);
            testCase.verifyGreaterThan(t.Pid, 0);
            testCase.verifyEqual(t.DllPath, 'none');   % --simulate loads no DLL
        end

        function missingExecutableIsReported(testCase)
            t = doric.transport.BridgeTransport('Simulate', true, ...
                'ExePath', fullfile(tempdir, 'no_such_bridge.exe'));
            testCase.verifyError(@() t.open(), 'doric:BridgeTransport:bridgeNotFound');
        end

        function missingDllIsReported(testCase)
            t = doric.transport.BridgeTransport('DllDir', fullfile(tempdir, 'no_such_dll_dir'));
            testCase.verifyError(@() t.open(), 'doric:BridgeTransport:vendorDllNotFound');
        end

        function structSizesMatchTheDocumentedLayout(testCase)
            % docs/vendor-dll.md section 5. A mismatch means the bridge and the DLL disagree
            % about the Settings struct.
            t = testCase.Transport;
            t.open();
            reply = t.request('SIZES', struct(), 5000);
            testCase.verifyTrue(reply.Ok);
            testCase.verifyEqual(reply.Data.settings, '2088');
            testCase.verifyEqual(reply.Data.ttl, '40');
            testCase.verifyEqual(reply.Data.complex, '40');
            testCase.verifyEqual(reply.Data.off_customDataPoint, '28');
            testCase.verifyEqual(reply.Data.off_ttlModulation, '2032');
            testCase.verifyEqual(reply.Data.off_nbComplexModulations, '2072');
            testCase.verifyEqual(reply.Data.off_complexModulations, '2080');
            testCase.verifyEqual(reply.Data.ttl_periodMs, '16');
            testCase.verifyEqual(reply.Data.cx_startingDelayMs, '36');
        end

        function commandsBeforeInitAreRefused(testCase)
            t = testCase.Transport;
            t.open();
            reply = t.request('OPEN', struct('port', 5, 'waitms', 0), 5000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifyEqual(reply.Code, 'notInitialised');
        end

        function unknownCommandsAndBadArgumentsAreRefused(testCase)
            t = testCase.Transport;
            t.open();
            reply = t.request('NONSENSE', struct(), 5000);
            testCase.verifyEqual(reply.Code, 'unknownCommand');
            t.request('INIT', struct('waitms', 0), 5000);
            reply = t.request('SETTINGS', struct('port', 5, 'ch', 0, 'mode', 99), 5000);
            testCase.verifyEqual(reply.Code, 'invalidArgument');
            testCase.verifySubstring(reply.Text, 'mode');
            reply = t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 70000), 5000);
            testCase.verifyEqual(reply.Code, 'invalidArgument');
        end

        function settingsSurviveTheRoundTrip(testCase)
            % The bridge echoes what it parsed as EVT SIMCALL; compare it with what was sent.
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 5000);
            t.request('OPEN', struct('port', 5, 'waitms', 0), 5000);
            settings = doric.ChannelSettings.square(1234, 987.5, 12.25, ...
                'TriggerType', 'Triggered', 'TriggerMode', 'Continue', ...
                'IsRepeatableSequence', true, 'CurrentMode', 'LowPower', 'RisingTimeMs', 7, ...
                'FallingTimeMs', 9, 'NbOfSeq', 11, 'NbOfPulsesPerSeq', 13, ...
                'StartingDelayMs', 4000000000, 'DelayBetweenSeqMs', 17);
            settings.ComplexSegments = [doric.ComplexSegment('Mode', 'Delay', 'PeriodMs', 2000), ...
                doric.ComplexSegment('Mode', 'Triangle', 'CurrentmA', 300)];
            settings.CustomDataPoints = [3 0 9];

            id = t.sendSettings(5, 2, settings);
            [reply, others] = t.request('HELLO', struct(), 5000);   % flushes the SIMCALL event
            testCase.verifyTrue(reply.Ok);
            simcalls = others(strcmp({others.Kind}, 'event') & strcmp({others.Name}, 'SIMCALL'));
            data = simcalls(end).Data;
            testCase.verifyEqual(data.fn, 'ls_send_settings');
            testCase.verifyEqual(data.ch, '1');                     % 0-based on the wire
            testCase.verifyEqual(data.mode, '4');
            testCase.verifyEqual(data.ttlout, '1');
            testCase.verifyEqual(data.trigtype, '0');
            testCase.verifyEqual(data.trigmode, '2');
            testCase.verifyEqual(data.repeat, '1');
            testCase.verifyEqual(data.curmode, '1');
            testCase.verifyEqual(data.ttl_current, '1234');
            testCase.verifyEqual(data.ttl_period, '987.5');
            testCase.verifyEqual(data.ttl_on, '12.25');
            testCase.verifyEqual(data.ttl_rise, '7');
            testCase.verifyEqual(data.ttl_fall, '9');
            testCase.verifyEqual(data.ttl_nseq, '11');
            testCase.verifyEqual(data.ttl_npulses, '13');
            testCase.verifyEqual(data.ttl_startdelay, '4000000000');
            testCase.verifyEqual(data.ttl_seqdelay, '17');
            testCase.verifyEqual(data.ncx, '2');
            testCase.verifyEqual(data.ncustom, '3');
            testCase.verifyEqual(data.customsum, '12');
            testCase.verifyGreaterThan(id, 0);
        end

        function libraryErrorTextFailsTheCommand(testCase)
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 5000);
            t.request('OPEN', struct('port', 5, 'waitms', 0), 5000);
            t.send('SIMFAIL', struct('Positional', ...
                {{'CURRENT', 'Unable', 'to', 'send', 'current...', 'Device', 'not', 'found'}}));
            reply = t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 10, 'settle', 20), 5000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifyEqual(reply.Code, 'libraryError');
            testCase.verifySubstring(reply.Text, 'Device not found');
        end

        function openingAnUnlistedPortFails(testCase)
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 5000);
            reply = t.request('OPEN', struct('port', 9, 'waitms', 0, 'settle', 20), 5000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifySubstring(reply.Text, 'Device not found');
        end

        function closingStdinStopsEverythingAndExits(testCase)
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 5000);
            t.request('OPEN', struct('port', 5, 'waitms', 0), 5000);
            t.request('START', struct('port', 5, 'ch', 0), 5000);
            t.close();                       % closes the bridge's stdin
            testCase.verifyFalse(t.isOpen());
            testCase.verifyEqual(t.ExitCode, 0);
            messages = t.poll();             % lines read while the bridge was shutting down
            simcalls = messages(strcmp({messages.Name}, 'SIMCALL'));
            functions = cellfun(@(d) string(d.fn), {simcalls.Data});
            testCase.verifyTrue(any(functions == "ls_stop_all"));
            testCase.verifyTrue(any(functions == "close_device"));
            testCase.verifyTrue(any(functions == "quit"));
            testCase.verifyTrue(any(strcmp({messages.Name}, 'EXITING')));
        end

        function aDyingBridgeIsReportedAsExit(testCase)
            t = testCase.Transport;
            t.open();
            t.send('SIMCRASH', struct());    % test hook: exit without the safety path
            exited = false;
            for k = 1:100
                messages = t.poll();
                if any(strcmp({messages.Kind}, 'exit'))
                    exited = true;
                    break
                end
                pause(0.02);
            end
            testCase.verifyTrue(exited);
            testCase.verifyEqual(t.ExitCode, 9);
            testCase.verifyError(@() t.send('HELLO', struct()), ...
                'doric:BridgeTransport:bridgeExited');
        end

        function aBurstOfCommandsDoesNotDeadlock(testCase)
            % Sending many commands without polling must not fill the bridge's stdout pipe:
            % the transport drains it on every send.
            ls = doric.LightSource('Transport', testCase.Transport, 'InitWaitMs', 0, ...
                'ListWaitMs', 0, 'OpenWaitMs', 0, 'SettleMs', 0, 'AutoPoll', false, ...
                'CommandTimeoutMs', 20000);
            cleanup = onCleanup(@() delete(ls));
            ls.connect();
            n = 200;
            for k = 1:n
                ls.Channels(1).setCurrent(mod(k, 100), 'Wait', false);
            end
            for k = 1:200
                ls.poll();
                stats = ls.stats();
                done = stats.Count(strcmp(stats.Command, 'CURRENT'));
                if ~isempty(done) && done >= n
                    break
                end
                pause(0.005);
            end
            stats = ls.stats();
            testCase.verifyEqual(stats.Count(strcmp(stats.Command, 'CURRENT')), n);
            testCase.verifyEqual(stats.Failures(strcmp(stats.Command, 'CURRENT')), 0);
            testCase.verifyEqual(ls.Channels(1).CommandedCurrentmA, mod(n, 100));
            testCase.verifyGreaterThan(stats.MeanMs(strcmp(stats.Command, 'CURRENT')), 0);
            clear cleanup
        end

        function lightSourceWorksOverTheBridge(testCase)
            ls = doric.LightSource('Transport', testCase.Transport, 'InitWaitMs', 0, ...
                'ListWaitMs', 0, 'OpenWaitMs', 0, 'CloseWaitMs', 0, 'SettleMs', 20, ...
                'AutoPoll', false);
            cleanup = onCleanup(@() delete(ls));
            ls.connect();
            testCase.verifyEqual(ls.State, 'Ready');
            testCase.verifyEqual(ls.Port, 5);
            testCase.verifyEqual(ls.DeviceName, 'LEDFLS_465_465');
            ls.Channels(2).apply(doric.ChannelSettings.cw(33));
            ls.Channels(2).start();
            ls.Channels(2).setCurrent(44, 'SettleMs', 0);
            testCase.verifyEqual(ls.Channels(2).CommandedCurrentmA, 44);
            testCase.verifyTrue(ls.Channels(2).IsRunning);
            stats = ls.stats();
            testCase.verifyGreaterThan(stats.MeanMs(stats.Command == "CURRENT"), 0);
            ls.disconnect();
            testCase.verifyEqual(ls.State, 'Disconnected');
            testCase.verifyFalse(testCase.Transport.isOpen());
            clear cleanup
        end
    end
end
