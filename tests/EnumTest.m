classdef EnumTest < matlab.unittest.TestCase
%ENUMTEST Enumeration values against the vendor headers (docs/vendor-dll.md section 4).
%
%   A mismatch here would send a wrong integer to the device, so the values are pinned.
%
%   See also doric.Mode, doric.CurrentMode, doric.TriggerType, doric.TriggerMode, doric.ComplexMode

    methods (Test)
        function modeValues(testCase)
            testCase.verifyEqual(int32(doric.Mode.Off), int32(0));
            testCase.verifyEqual(int32(doric.Mode.CW), int32(1));
            testCase.verifyEqual(int32(doric.Mode.ExtTTL), int32(2));
            testCase.verifyEqual(int32(doric.Mode.ExtAnalog), int32(3));
            testCase.verifyEqual(int32(doric.Mode.Square), int32(4));
            testCase.verifyEqual(int32(doric.Mode.Complex), int32(5));
            testCase.verifyEqual(int32(doric.Mode.Custom), int32(6));
            testCase.verifyEqual(numel(enumeration('doric.Mode')), 7);
        end

        function currentModeValues(testCase)
            testCase.verifyEqual(int32(doric.CurrentMode.Normal), int32(0));
            testCase.verifyEqual(int32(doric.CurrentMode.LowPower), int32(1));
            testCase.verifyEqual(int32(doric.CurrentMode.Overdrive), int32(2));
        end

        function triggerValues(testCase)
            testCase.verifyEqual(int32(doric.TriggerType.Triggered), int32(0));
            testCase.verifyEqual(int32(doric.TriggerType.Gated), int32(1));
            testCase.verifyEqual(int32(doric.TriggerType.Manual), int32(255));
            testCase.verifyEqual(int32(doric.TriggerMode.Uninterrupted), int32(0));
            testCase.verifyEqual(int32(doric.TriggerMode.Pause), int32(1));
            testCase.verifyEqual(int32(doric.TriggerMode.Continue), int32(2));
            testCase.verifyEqual(int32(doric.TriggerMode.Restart), int32(3));
        end

        function complexModeValues(testCase)
            expected = {'Off', 0; 'CW', 1; 'Square', 2; 'Input', 3; 'Triangle', 4; 'RampUp', 5; ...
                'RampDown', 6; 'Sine', 7; 'Stairs', 8; 'Custom', 9; 'Delay', 10; 'LockIn', 11};
            for k = 1:size(expected, 1)
                testCase.verifyEqual(int32(doric.ComplexMode.(expected{k, 1})), ...
                    int32(expected{k, 2}));
            end
            testCase.verifyEqual(numel(enumeration('doric.ComplexMode')), size(expected, 1));
        end

        function channelIndicesAreOneBasedInMatlab(testCase)
            % The transport converts to the vendor's 0-based Channel enum.
            t = doric.transport.SimulatedTransport();
            t.open();
            cleanup = onCleanup(@() t.close());
            t.init(true, 0);
            t.listDevices(0);
            t.openDevice(5, 0);
            t.startChannel(5, 2);
            calls = t.callsOf('START');
            testCase.verifyEqual(calls(end).Args.ch, 1);
            clear cleanup
        end
    end
end
