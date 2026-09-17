function results = run_tests(varargin)
%RUN_TESTS Run the doric test suite headless (no hardware).
%
%   results = run_tests() runs every test in this folder and prints a summary.
%   results = run_tests('Filter', 'LightSource') runs test classes whose name contains Filter.
%   results = run_tests('Verbosity', 2) passes a verbosity to the test runner.
%
%   Tests that need bin/doric_bridge.exe (BridgeProtocolTest) are skipped when it is missing or
%   when not on Windows; build it with doric.build().
%
%   From the operating-system shell:
%       matlab -batch "results = run_tests; exit(any([results.Failed]))"
%
%   See also runtests, doric.build

    parser = inputParser;
    parser.addParameter('Filter', '', @(x) ischar(x) || isstring(x));
    parser.addParameter('Verbosity', 1, @isnumeric);
    parser.parse(varargin{:});

    testDir = fileparts(mfilename('fullpath'));
    packageDir = fileparts(testDir);
    previous = path();
    restore = onCleanup(@() path(previous));
    addpath(packageDir);

    suite = matlab.unittest.TestSuite.fromFolder(testDir);
    if ~isempty(parser.Results.Filter)
        names = string({suite.Name});
        suite = suite(contains(names, string(parser.Results.Filter)));
    end
    runner = matlab.unittest.TestRunner.withTextOutput('OutputDetail', parser.Results.Verbosity);
    results = runner.run(suite);
    disp(table(results));
    clear restore
end
