classdef LibraryTransportTest < matlab.unittest.TestCase
%LIBRARYTRANSPORTTEST The loadlibrary fallback, without loading the vendor DLL.
%
%   The DLL is never loaded here: doing so would pull Qt6, OpenCV, HDF5 and FFmpeg into MATLAB
%   and, after init, would reach the device. Only the parts that can be checked safely are:
%   options, the missing-DLL path and the flat C header that loadlibrary parses.
%
%   The class itself is experimental and unverified against hardware (docs/rig-checks.md).
%
%   See also doric.transport.LibraryTransport, doric.transport.BridgeTransport

    methods (Test)
        function missingDllIsReported(testCase)
            testCase.assumeTrue(ispc, 'Windows only.');
            t = doric.transport.LibraryTransport('DllDir', fullfile(tempdir, 'no_such_folder'));
            cleanup = onCleanup(@() delete(t));
            testCase.verifyError(@() t.open(), 'doric:LibraryTransport:vendorDllNotFound');
            testCase.verifyFalse(t.isOpen());
            clear cleanup
        end

        function unknownOptionIsReported(testCase)
            testCase.verifyError(@() doric.transport.LibraryTransport('Nonsense', 1), ...
                'doric:LibraryTransport:invalidOption');
        end

        function defaultsComeFromConfig(testCase)
            t = doric.transport.LibraryTransport();
            cleanup = onCleanup(@() delete(t));
            testCase.verifyEqual(t.DllDir, doric.config().DllDir);
            clear cleanup
        end

        function flatHeaderMatchesTheDocumentedLayout(testCase)
            header = fullfile(fileparts(which('doric.transport.LibraryTransport')), 'private', ...
                'doric_flat.h');
            testCase.verifyTrue(isfile(header));
            text = fileread(header);
            testCase.verifySubstring(text, 'unsigned short customDataPoint[1000];');
            testCase.verifySubstring(text, 'DoricComplexModulation *complexModulations;');
            testCase.verifySubstring(text, 'void ls_send_current(int portNumber, int channelIndex, unsigned short current);');
        end
    end
end
