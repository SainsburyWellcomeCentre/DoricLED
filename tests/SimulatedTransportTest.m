classdef SimulatedTransportTest < matlab.unittest.TestCase
%SIMULATEDTRANSPORTTEST The hardware-free transport: replies, call log, fault injection, safety.
%
%   See also doric.transport.SimulatedTransport, doric.transport.Transport

    properties
        Transport
    end

    methods (TestMethodSetup)
        function makeTransport(testCase)
            testCase.Transport = doric.transport.SimulatedTransport();
            testCase.addTeardown(@() delete(testCase.Transport));
        end
    end

    methods (Test)
        function openAnnouncesReady(testCase)
            t = testCase.Transport;
            testCase.verifyFalse(t.isOpen());
            t.open();
            testCase.verifyTrue(t.isOpen());
            messages = t.poll();
            testCase.verifyEqual(messages(1).Kind, 'event');
            testCase.verifyEqual(messages(1).Name, 'READY');
        end

        function commandsNeedInit(testCase)
            t = testCase.Transport;
            t.open();
            reply = t.request('OPEN', struct('port', 5), 1000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifyEqual(reply.Code, 'notInitialised');
        end

        function listReportsDevicesAsLibraryText(testCase)
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 1000);
            [reply, others] = t.request('LIST', struct('waitms', 0), 1000);
            testCase.verifyTrue(reply.Ok);
            library = others(strcmp({others.Kind}, 'libmsg'));
            testCase.verifyEqual(library(end).Text, 'LEDFLS_465_465 (Port #5)');
            devices = doric.LightSource.parseDevices({library.Text});
            testCase.verifyEqual(devices.Port, 5);
        end

        function openingAnUnknownPortFails(testCase)
            t = testCase.Transport;
            t.open();
            t.request('INIT', struct('waitms', 0), 1000);
            reply = t.request('OPEN', struct('port', 9), 1000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifyEqual(reply.Code, 'libraryError');
            testCase.verifySubstring(reply.Text, 'Device not found');
        end

        function callsAreLoggedWithProtocolArguments(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.sendCurrent(5, 2, 250);
            calls = t.callsOf('CURRENT');
            testCase.verifyEqual(calls.Args.ch, 1);      % 0-based on the wire
            testCase.verifyEqual(calls.Args.ma, 250);
            settings = doric.ChannelSettings.cw(33);
            t.sendSettings(5, 1, settings);
            calls = t.callsOf('SETTINGS');
            testCase.verifyEqual(calls.Args.Settings, settings);
        end

        function deviceStateFollowsCommands(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.sendSettings(5, 1, doric.ChannelSettings.cw(40));
            t.startChannel(5, 1);
            t.poll();
            testCase.verifyTrue(t.Device(1).Channels(1).Running);
            testCase.verifyEqual(t.Device(1).Channels(1).CurrentmA, 40);
            t.stopAll(5);
            t.poll();
            testCase.verifyFalse(t.Device(1).Channels(1).Running);
        end

        function failNextInjectsLibraryError(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.failNext('CURRENT', 'Unable to send current... Device not found');
            reply = t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 5), 1000);
            testCase.verifyFalse(reply.Ok);
            testCase.verifyEqual(reply.Code, 'libraryError');
            reply = t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 5), 1000);
            testCase.verifyTrue(reply.Ok);  % only the next one fails
        end

        function failNextWithInfoTextKeepsCommandSuccessful(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.failNext('CURRENT', 'Some chatty message');
            [reply, others] = t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 5), 1000);
            testCase.verifyTrue(reply.Ok);
            testCase.verifyTrue(any(strcmp({others.Text}, 'Some chatty message')));
        end

        function hangNextNeverReplies(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.hangNext('CURRENT');
            testCase.verifyError(@() t.request('CURRENT', struct('port', 5, 'ch', 0, 'ma', 1), ...
                200), 'doric:Transport:timeout');
        end

        function crashReportsExitAndRefusesSends(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.crash(9);
            messages = t.poll();
            testCase.verifyTrue(any(strcmp({messages.Kind}, 'exit')));
            testCase.verifyFalse(t.isOpen());
            testCase.verifyError(@() t.sendCurrent(5, 1, 1), ...
                'doric:SimulatedTransport:bridgeExited');
        end

        function closeRunsTheStdinEofSafetyPath(testCase)
            t = testCase.Transport;
            testCase.openDevice();
            t.sendSettings(5, 1, doric.ChannelSettings.cw(40));
            t.startChannel(5, 1);
            t.poll();
            t.close();
            testCase.verifyFalse(t.Device(1).Channels(1).Running);
            testCase.verifyFalse(t.Device(1).Open);
            implicit = t.Calls([t.Calls.Implicit]);
            testCase.verifyEqual({implicit.Command}, {'STOPALL', 'CLOSE', 'QUIT'});
        end

        function latencyIsMeasuredForReplies(testCase)
            t = testCase.Transport;
            t.LatencyMs = 20;
            t.open();
            id = t.init(true, 0);
            pause(0.05);
            messages = t.poll();
            reply = messages(strcmp({messages.Kind}, 'reply') & [messages.Id] == id);
            testCase.verifyGreaterThanOrEqual(reply.LatencyMs, 20);
        end
    end

    methods (Access = private)
        function openDevice(testCase)
            t = testCase.Transport;
            t.open();
            t.init(true, 0);
            t.listDevices(0);
            t.openDevice(5, 0);
            t.poll();
        end
    end
end
