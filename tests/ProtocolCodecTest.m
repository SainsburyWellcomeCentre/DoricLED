classdef ProtocolCodecTest < matlab.unittest.TestCase
%PROTOCOLCODECTEST Encoding and decoding of the bridge line protocol, and message severities.
%
%   Checks what MATLAB puts on the wire against docs/bridge-protocol.md. The bridge's own
%   parsing of the same lines is covered by BridgeProtocolTest (needs bin/doric_bridge.exe).
%
%   See also doric.transport.ProtocolCodec, doric.transport.MessageClassifier

    methods (Test)
        function encodesSimpleRequests(testCase)
            line = doric.transport.ProtocolCodec.encodeRequest(7, 'current', ...
                struct('port', 5, 'ch', 1, 'ma', 100));
            testCase.verifyEqual(line, '7 CURRENT port=5 ch=1 ma=100');
            testCase.verifyEqual(doric.transport.ProtocolCodec.encodeRequest(1, 'QUIT'), '1 QUIT');
        end

        function rejectsValuesWithSpaces(testCase)
            testCase.verifyError(@() doric.transport.ProtocolCodec.encodeRequest(1, 'X', ...
                struct('name', 'two words')), 'doric:ProtocolCodec:invalidArgument');
        end

        function settingsTokensCoverEveryField(testCase)
            s = doric.ChannelSettings.square(80, 1000, 500, 'TriggerType', 'Gated', ...
                'TriggerMode', 'Restart', 'IsRepeatableSequence', true, ...
                'CurrentMode', 'Overdrive', 'RisingTimeMs', 3, 'FallingTimeMs', 4, ...
                'StartingDelayMs', 20, 'DelayBetweenSeqMs', 30);
            tokens = doric.transport.ProtocolCodec.settingsTokens(s);
            expected = {'mode=4', 'ttlout=1', 'trigtype=1', 'trigmode=3', 'repeat=1', ...
                'curmode=2', 'ttl.current=80', 'ttl.startdelay=20', 'ttl.seqdelay=30', ...
                'ttl.period=1000', 'ttl.on=500', 'ttl.rise=3', 'ttl.fall=4', 'ttl.nseq=0', ...
                'ttl.npulses=0', 'ncx=0'};
            testCase.verifyEqual(tokens, expected);
        end

        function settingsTokensEncodeSegmentsAndCustomPoints(testCase)
            s = doric.ChannelSettings.complex();
            tokens = doric.transport.ProtocolCodec.settingsTokens(s);
            testCase.verifyTrue(any(strcmp(tokens, 'ncx=3')));
            testCase.verifyTrue(any(strcmp(tokens, 'cx1.mode=10')));     % Delay segment
            testCase.verifyTrue(any(strcmp(tokens, 'cx2.startdelay=7000')));

            s = doric.ChannelSettings.custom([5 0 7 0 0]);
            tokens = doric.transport.ProtocolCodec.settingsTokens(s);
            custom = tokens(startsWith(tokens, 'custom='));
            testCase.verifyEqual(custom{1}, 'custom=5,0,7');  % trailing zeros are implicit

            tokens = doric.transport.ProtocolCodec.settingsTokens(doric.ChannelSettings.cw(1));
            testCase.verifyEmpty(tokens(startsWith(tokens, 'custom=')));
        end

        function decodesReplies(testCase)
            ok = doric.transport.ProtocolCodec.decodeLine('@D 12 OK n=2 msgs=3', 1.5);
            testCase.verifyEqual(ok.Kind, 'reply');
            testCase.verifyEqual(ok.Id, 12);
            testCase.verifyTrue(ok.Ok);
            testCase.verifyEqual(ok.Data.n, '2');
            testCase.verifyEqual(ok.Time, 1.5);

            err = doric.transport.ProtocolCodec.decodeLine( ...
                '@D 13 ERR libraryError Unable to send current... Device not found');
            testCase.verifyFalse(err.Ok);
            testCase.verifyEqual(err.Code, 'libraryError');
            testCase.verifyEqual(err.Text, 'Unable to send current... Device not found');
        end

        function decodesEventsAndLibraryText(testCase)
            msg = doric.transport.ProtocolCodec.decodeLine( ...
                '@D EVT LIBMSG id=4 src=stdio sev=error text=Unable%20to%20start%20channel');
            testCase.verifyEqual(msg.Kind, 'libmsg');
            testCase.verifyEqual(msg.Id, 4);
            testCase.verifyEqual(msg.Source, 'stdio');
            testCase.verifyEqual(msg.Severity, 'error');
            testCase.verifyEqual(msg.Text, 'Unable to start channel');

            evt = doric.transport.ProtocolCodec.decodeLine('@D EVT EXITING reason=stdinClosed');
            testCase.verifyEqual(evt.Kind, 'event');
            testCase.verifyEqual(evt.Name, 'EXITING');
            testCase.verifyEqual(evt.Data.reason, 'stdinClosed');
        end

        function decodesUnexpectedLinesAsLibraryText(testCase)
            msg = doric.transport.ProtocolCodec.decodeLine('Could not open device. System not initialized yet');
            testCase.verifyEqual(msg.Kind, 'libmsg');
            testCase.verifyEqual(msg.Source, 'raw');
            testCase.verifyEqual(msg.Severity, 'error');
        end

        function percentDecodingHandlesPercentAndSpaces(testCase)
            testCase.verifyEqual(doric.transport.ProtocolCodec.decodeValue('a%20b%25c'), 'a b%c');
            testCase.verifyEqual(doric.transport.ProtocolCodec.decodeValue('plain'), 'plain');
        end

        function classifierMatchesVendorStrings(testCase)
            classify = @(t) doric.transport.MessageClassifier.classify(t);
            testCase.verifyEqual(classify('Unable to connect device... Device not found'), 'error');
            testCase.verifyEqual(classify('Could not list available device(s). System not initialized yet'), 'error');
            testCase.verifyEqual(classify('Unable to start all... Wrong controller for LightSource driver'), 'error');
            testCase.verifyEqual(classify('No available device(s)'), 'warning');
            testCase.verifyEqual(classify('System already initialized'), 'warning');
            testCase.verifyEqual(classify('LEDFLS_465_465 (Port #5)'), 'info');
            testCase.verifyTrue(doric.transport.MessageClassifier.isDeviceNotFound( ...
                'Unable to send settings... Device not found'));
            testCase.verifyFalse(doric.transport.MessageClassifier.isDeviceNotFound( ...
                'No available device(s)'));
        end

        function parseDevicesReadsPortLines(testCase)
            devices = doric.LightSource.parseDevices({'LEDFLS_465_465 (Port #5)', ...
                'Other device (Port #7)', 'noise'});
            testCase.verifyEqual(devices.Port, [5; 7]);
            testCase.verifyEqual(devices.Name(1), "LEDFLS_465_465");
            testCase.verifyEqual(height(doric.LightSource.parseDevices({'No available device(s)'})), 0);
        end

        function parseDevicesStripsTheLibrarysOwnQuotingAndTag(testCase)
            % The real library quotes the line and prefixes its own tag (rig check 2026-09-17):
            %   "[Doric System] : LED Driver (Port #4)"
            devices = doric.LightSource.parseDevices( ...
                {'"[Doric System] : LED Driver (Port #4)"'});
            testCase.verifyEqual(devices.Port, 4);
            testCase.verifyEqual(devices.Name(1), "LED Driver");
        end
    end
end
