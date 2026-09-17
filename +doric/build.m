function exePath = build(varargin)
%BUILD Build bin/doric_bridge.exe with the MinGW-w64 compiler.
%
%   exePath = doric.build() compiles the bridge once after installation (or after an update of
%   native/doric_bridge/doric_bridge.cpp). It needs the MATLAB Add-On "MATLAB Support for
%   MinGW-w64 C/C++ Compiler" and does not touch the device.
%
%   exePath = doric.build('Verbose', true, 'Compiler', gppPath, 'OutDir', folder)
%   Options are passed to native/doric_bridge/build_bridge.m.
%
%   Errors: see build_bridge (doric:build:*).
%
%   See also doric.config, doric.transport.BridgeTransport

    nativeDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'native', 'doric_bridge');
    % build_bridge.m lives outside the package; reach it without changing folder or saved path.
    previous = path();
    restore = onCleanup(@() path(previous));
    addpath(nativeDir);
    exePath = build_bridge(varargin{:});
    clear restore
end
