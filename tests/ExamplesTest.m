classdef ExamplesTest < matlab.unittest.TestCase
%EXAMPLESTEST The files in examples/ run end to end on the simulated device.
%
%   The examples default to the simulated transport, so this test never touches hardware. It
%   also guards against an example drifting away from the API.
%
%   See also examples/example_basic.m, example_closed_loop, example_bpod_softcode

    properties
        ExamplesDir
    end

    methods (TestMethodSetup)
        function addExamplesToPath(testCase)
            testCase.ExamplesDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                'examples');
            previous = path();
            testCase.addTeardown(@() path(previous));
            addpath(testCase.ExamplesDir);
        end
    end

    methods (Test)
        function basicScriptRuns(testCase)
            evalin('base', 'clear');
            run(fullfile(testCase.ExamplesDir, 'example_basic.m'));
            testCase.verifyTrue(exist('session', 'var') == 1);
            % record() is taken while still connected, as a host would.
            testCase.verifyEqual(session.State, 'Ready');
            testCase.verifyEqual(session.Channels(1).MaxCurrentmA, 200);
            testCase.verifyFalse(session.Channels(1).IsRunning);
        end

        function closedLoopExampleRuns(testCase)
            session = example_closed_loop(false, 5);
            testCase.verifyEqual(session.State, 'Ready');
            testCase.verifyEqual(session.Channels(1).CommandedCurrentmA, 50 + 10 * mod(5, 5));
            testCase.verifyTrue(any(strcmp({session.Log.Command}, 'CURRENT')));
        end

        function bpodSoftCodeExampleRuns(testCase)
            session = example_bpod_softcode(false);
            testCase.verifyEqual(session.State, 'Ready');
            testCase.verifyEqual(session.Channels(1).MaxCurrentmA, 300);
            testCase.verifyEmpty(getappdata(0, 'DoricLED'));
        end
    end
end
