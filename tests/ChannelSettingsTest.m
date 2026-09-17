classdef ChannelSettingsTest < matlab.unittest.TestCase
%CHANNELSETTINGSTEST Validation, factories and conversions of doric.ChannelSettings.
%
%   Run with: runtests('tests')
%   Uses no hardware and no transport.
%
%   See also doric.ChannelSettings, doric.ComplexSegment, tests/run_tests.m

    methods (Test)
        function defaultsMatchVendorHeader(testCase)
            s = doric.ChannelSettings();
            testCase.verifyEqual(s.Mode, doric.Mode.Off);
            testCase.verifyFalse(s.IsTTLOutput);
            testCase.verifyEqual(s.TriggerType, doric.TriggerType.Manual);
            testCase.verifyEqual(s.TriggerMode, doric.TriggerMode.Uninterrupted);
            testCase.verifyFalse(s.IsRepeatableSequence);
            testCase.verifyEqual(s.CurrentMode, doric.CurrentMode.Normal);
            testCase.verifyEqual(s.CurrentmA, 0);
            testCase.verifyEqual(s.PeriodMs, 100);
            testCase.verifyEqual(s.TimeOnMs, 50);
            testCase.verifyEqual(s.NbOfSeq, 1);
            testCase.verifyEqual(s.NbOfPulsesPerSeq, 0);
            testCase.verifyEmpty(s.ComplexSegments);
            testCase.verifyEmpty(s.CustomDataPoints);
        end

        function enumsAcceptNamesAndValues(testCase)
            s = doric.ChannelSettings('Mode', 'square', 'TriggerType', 1, 'CurrentMode', "Overdrive");
            testCase.verifyEqual(s.Mode, doric.Mode.Square);
            testCase.verifyEqual(s.TriggerType, doric.TriggerType.Gated);
            testCase.verifyEqual(s.CurrentMode, doric.CurrentMode.Overdrive);
            testCase.verifyError(@() doric.ChannelSettings('Mode', 'Blinky'), ...
                'doric:ChannelSettings:invalidSettings');
            testCase.verifyError(@() doric.ChannelSettings('Mode', 7), ...
                'doric:ChannelSettings:invalidSettings');
        end

        function rangesAreEnforcedNotClamped(testCase)
            id = 'doric:ChannelSettings:invalidSettings';
            testCase.verifyError(@() doric.ChannelSettings('CurrentmA', 65536), id);
            testCase.verifyError(@() doric.ChannelSettings('CurrentmA', -1), id);
            testCase.verifyError(@() doric.ChannelSettings('CurrentmA', 10.5), id);
            testCase.verifyError(@() doric.ChannelSettings('PeriodMs', -0.1), id);
            testCase.verifyError(@() doric.ChannelSettings('PeriodMs', Inf), id);
            testCase.verifyError(@() doric.ChannelSettings('NbOfSeq', 70000), id);
            testCase.verifyError(@() doric.ChannelSettings('StartingDelayMs', 2^32), id);
            testCase.verifyError(@() doric.ChannelSettings('IsTTLOutput', 2), id);
            testCase.verifyError(@() doric.ChannelSettings('Nonsense', 1), id);
            s = doric.ChannelSettings('CurrentmA', 65535, 'StartingDelayMs', 4294967295);
            testCase.verifyEqual(s.CurrentmA, 65535);
            testCase.verifyEqual(s.StartingDelayMs, 4294967295);
        end

        function complexSegmentsAreLimitedTo32(testCase)
            segments = repmat(doric.ComplexSegment(), 1, 32);
            s = doric.ChannelSettings('ComplexSegments', segments);
            testCase.verifyEqual(numel(s.ComplexSegments), 32);
            testCase.verifyError(@() doric.ChannelSettings('ComplexSegments', ...
                repmat(doric.ComplexSegment(), 1, 33)), 'doric:ChannelSettings:invalidSettings');
        end

        function customDataPointsAreValidated(testCase)
            s = doric.ChannelSettings('CustomDataPoints', 0:999);
            testCase.verifyEqual(numel(s.CustomDataPoints), 1000);
            testCase.verifyError(@() doric.ChannelSettings('CustomDataPoints', 0:1000), ...
                'doric:ChannelSettings:invalidSettings');
            testCase.verifyError(@() doric.ChannelSettings('CustomDataPoints', [1 2 70000]), ...
                'doric:ChannelSettings:invalidSettings');
            testCase.verifyError(@() doric.ChannelSettings('CustomDataPoints', [1 2.5]), ...
                'doric:ChannelSettings:invalidSettings');
        end

        function factoriesMatchVendorExamples(testCase)
            % docs/vendor-dll.md section 6.
            cw = doric.ChannelSettings.cw();
            testCase.verifyEqual(cw.Mode, doric.Mode.CW);
            testCase.verifyEqual(cw.CurrentmA, 100);

            square = doric.ChannelSettings.square();
            testCase.verifyEqual(square.Mode, doric.Mode.Square);
            testCase.verifyTrue(square.IsTTLOutput);
            testCase.verifyEqual([square.CurrentmA, square.PeriodMs, square.TimeOnMs], ...
                [50, 1000, 500]);
            testCase.verifyEqual([square.NbOfSeq, square.NbOfPulsesPerSeq], [0, 0]);

            ttl = doric.ChannelSettings.extTTL();
            testCase.verifyEqual(ttl.Mode, doric.Mode.ExtTTL);
            testCase.verifyEqual(ttl.CurrentmA, 100);

            analog = doric.ChannelSettings.extAnalog();
            testCase.verifyEqual(analog.Mode, doric.Mode.ExtAnalog);
            testCase.verifyEqual(analog.CurrentmA, 1000);

            triggered = doric.ChannelSettings.triggered();
            testCase.verifyEqual(triggered.TriggerType, doric.TriggerType.Triggered);
            testCase.verifyEqual(triggered.TriggerMode, doric.TriggerMode.Pause);
            testCase.verifyEqual([triggered.NbOfSeq, triggered.NbOfPulsesPerSeq, ...
                triggered.DelayBetweenSeqMs], [5, 5, 2000]);

            gated = doric.ChannelSettings.gated();
            testCase.verifyEqual(gated.TriggerType, doric.TriggerType.Gated);
            testCase.verifyEqual(gated.TriggerMode, doric.TriggerMode.Restart);
            testCase.verifyEqual(gated.CurrentmA, 250);

            complex = doric.ChannelSettings.complex();
            testCase.verifyEqual(complex.Mode, doric.Mode.Complex);
            testCase.verifyEqual(numel(complex.ComplexSegments), 3);
            testCase.verifyEqual(complex.ComplexSegments(2).Mode, doric.ComplexMode.Delay);
            testCase.verifyEqual(complex.ComplexSegments(3).Mode, doric.ComplexMode.Triangle);

            custom = doric.ChannelSettings.custom();
            testCase.verifyEqual(custom.Mode, doric.Mode.Custom);
            testCase.verifyEqual(custom.CustomDataPoints, 0:999);
            testCase.verifyEqual([custom.PeriodMs, custom.StartingDelayMs, ...
                custom.DelayBetweenSeqMs, custom.NbOfSeq], [2500, 2000, 500, 6]);

            testCase.verifyEqual(doric.ChannelSettings.off().Mode, doric.Mode.Off);
        end

        function factoryOverridesWin(testCase)
            s = doric.ChannelSettings.square(80, 1000, 500, 'TriggerType', 'Gated', 'NbOfSeq', 3);
            testCase.verifyEqual(s.CurrentmA, 80);
            testCase.verifyEqual(s.TriggerType, doric.TriggerType.Gated);
            testCase.verifyEqual(s.NbOfSeq, 3);
        end

        function withReturnsCopy(testCase)
            a = doric.ChannelSettings.cw(50);
            b = a.with('CurrentmA', 60);
            testCase.verifyEqual(a.CurrentmA, 50);
            testCase.verifyEqual(b.CurrentmA, 60);
        end

        function peakCurrentCoversEveryField(testCase)
            s = doric.ChannelSettings.cw(10);
            s.ComplexSegments = doric.ComplexSegment('CurrentmA', 300);
            s.CustomDataPoints = [1 2 700];
            testCase.verifyEqual(s.peakCurrentmA(), 700);
        end

        function checkReportsSuspiciousCombinations(testCase)
            s = doric.ChannelSettings('PeriodMs', 10, 'TimeOnMs', 20);
            testCase.verifyNotEmpty(s.check());
            testCase.verifyNotEmpty(doric.ChannelSettings('Mode', 'Complex').check());
            testCase.verifyNotEmpty(doric.ChannelSettings('Mode', 'Custom').check());
            testCase.verifyEmpty(doric.ChannelSettings.cw(10).check());
        end

        function structAndJsonRoundTrip(testCase)
            s = doric.ChannelSettings.complex();
            s.CustomDataPoints = [0 5 10];
            s.CurrentmA = 42;
            testCase.verifyEqual(doric.ChannelSettings.fromStruct(s.toStruct()), s);
            testCase.verifyEqual(doric.ChannelSettings.fromJSON(s.toJSON()), s);

            plain = doric.ChannelSettings.cw(7);
            testCase.verifyEqual(doric.ChannelSettings.fromJSON(plain.toJSON()), plain);

            partial = doric.ChannelSettings.fromStruct(struct('Mode', 'CW', 'CurrentmA', 5));
            testCase.verifyEqual(partial.Mode, doric.Mode.CW);
            testCase.verifyEqual(partial.PeriodMs, 100);
        end

        function describeMentionsModeAndCurrent(testCase)
            text = doric.ChannelSettings.square(80, 1000, 500).describe();
            testCase.verifySubstring(text, 'Square');
            testCase.verifySubstring(text, '80 mA');
            testCase.verifySubstring(text, '1000');
        end

        function segmentValidation(testCase)
            id = 'doric:ComplexSegment:invalidSettings';
            testCase.verifyError(@() doric.ComplexSegment('Mode', 'Nope'), id);
            testCase.verifyError(@() doric.ComplexSegment('CurrentmA', -5), id);
            testCase.verifyError(@() doric.ComplexSegment('Unknown', 1), id);
            seg = doric.ComplexSegment('Mode', 'Delay', 'PeriodMs', 2000);
            testCase.verifyEqual(seg.Mode, doric.ComplexMode.Delay);
            testCase.verifyEqual(doric.ComplexSegment.fromStruct(seg.toStruct()), seg);
        end
    end
end
