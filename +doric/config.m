function cfg = config(varargin)
%CONFIG Resolved paths and defaults of the doric package.
%
%   cfg = doric.config() returns a struct:
%       RootDir     package root (the folder containing +doric)
%       BridgeExe   doric_bridge.exe used by BridgeTransport
%       DllDir      folder with DoricSystem.dll and its Qt runtime
%       Version     package version (doric.version)
%
%   cfg = doric.config('BridgeExe', path, 'DllDir', folder) overrides entries for this call.
%   Persistent overrides use MATLAB preferences, e.g.
%       setpref('doric', 'DllDir', 'D:\Doric\Qt')
%   Precedence: arguments, then preferences, then the defaults relative to the package.
%
%   Errors
%       doric:config:invalidOption  unknown or malformed option
%
%   See also doric.transport.BridgeTransport, doric.build

    rootDir = fileparts(fileparts(mfilename('fullpath')));
    cfg = struct();
    cfg.RootDir = rootDir;
    cfg.BridgeExe = fullfile(rootDir, 'bin', 'doric_bridge.exe');
    cfg.DllDir = fullfile(rootDir, 'DoricSystemDLL', 'API', 'lib', 'x64', 'release', 'Qt');
    cfg.Version = doric.version();

    overridable = {'BridgeExe', 'DllDir'};
    for k = 1:numel(overridable)
        name = overridable{k};
        if ispref('doric', name)
            cfg.(name) = char(getpref('doric', name));
        end
    end
    if mod(numel(varargin), 2) ~= 0
        error('doric:config:invalidOption', 'Options must be name-value pairs.');
    end
    for k = 1:2:numel(varargin)
        match = strcmpi(overridable, char(varargin{k}));
        if ~any(match)
            error('doric:config:invalidOption', 'Unknown option "%s". Valid: %s.', ...
                char(varargin{k}), strjoin(overridable, ', '));
        end
        cfg.(overridable{match}) = char(varargin{k + 1});
    end
end
