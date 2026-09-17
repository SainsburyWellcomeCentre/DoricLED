function exePath = build_bridge(varargin)
%BUILD_BRIDGE Build doric_bridge.exe from doric_bridge.cpp with MinGW-w64.
%
%   exePath = build_bridge() compiles native/doric_bridge/doric_bridge.cpp against the vendor
%   headers in DoricSystemDLL/API/include into bin/doric_bridge.exe and returns its full path.
%   The executable is statically linked (no MinGW runtime DLLs needed) and does not link against
%   DoricSystem.dll; it loads the DLL at run time.
%
%   exePath = build_bridge('Compiler', gppPath, 'OutDir', folder, 'Verbose', tf)
%       Compiler  full path of g++.exe. Default: the MinGW-w64 MATLAB support package, found
%                 through mex.getCompilerConfigurations or the MW_MINGW64_LOC variable.
%       OutDir    output folder. Default: <package root>/bin.
%       Verbose   print the compiler command and its output. Default false.
%
%   Equivalent command (from the package root, with MinGW's bin folder on PATH):
%       g++ -std=c++17 -O2 -Wall -municode -static -static-libgcc -static-libstdc++
%           -I DoricSystemDLL/API/include native/doric_bridge/doric_bridge.cpp
%           -o bin/doric_bridge.exe
%
%   Errors
%       doric:build:notWindows       not on Windows
%       doric:build:compilerNotFound g++.exe could not be located
%       doric:build:compileFailed    the compiler returned an error (message has its output)
%
%   See also doric.build, doric.config

    parser = inputParser;
    parser.addParameter('Compiler', '', @(x) ischar(x) || isstring(x));
    parser.addParameter('OutDir', '', @(x) ischar(x) || isstring(x));
    parser.addParameter('Verbose', false, @(x) islogical(x) || isnumeric(x));
    parser.parse(varargin{:});
    opts = parser.Results;

    if ~ispc
        error('doric:build:notWindows', 'doric_bridge.exe can only be built on Windows.');
    end

    sourceDir = fileparts(mfilename('fullpath'));
    rootDir = fileparts(fileparts(sourceDir));
    includeDir = fullfile(rootDir, 'DoricSystemDLL', 'API', 'include');
    source = fullfile(sourceDir, 'doric_bridge.cpp');
    outDir = char(opts.OutDir);
    if isempty(outDir)
        outDir = fullfile(rootDir, 'bin');
    end
    if ~isfolder(outDir)
        mkdir(outDir);
    end
    exePath = fullfile(outDir, 'doric_bridge.exe');

    gpp = char(opts.Compiler);
    if isempty(gpp)
        gpp = findCompiler();
    end
    if ~isfile(gpp)
        error('doric:build:compilerNotFound', ['g++.exe not found. Install the MATLAB Add-On ' ...
            '"MATLAB Support for MinGW-w64 C/C++ Compiler" or pass ''Compiler'', path.']);
    end

    % g++ launches cc1plus/as/ld from its own folder, so that folder must lead PATH.
    oldPath = getenv('PATH');
    restorePath = onCleanup(@() setenv('PATH', oldPath));
    setenv('PATH', [fileparts(gpp) ';' oldPath]);

    command = sprintf(['"%s" -std=c++17 -O2 -Wall -municode -static -static-libgcc ' ...
        '-static-libstdc++ -I "%s" "%s" -o "%s"'], gpp, includeDir, source, exePath);
    if opts.Verbose
        fprintf('%s\n', command);
    end
    [status, output] = system(command);
    if opts.Verbose && ~isempty(output)
        fprintf('%s\n', output);
    end
    if status ~= 0
        error('doric:build:compileFailed', 'Building doric_bridge.exe failed:\n%s', output);
    end
    clear restorePath
end

function gpp = findCompiler()
% Locate g++.exe of the MinGW-w64 support package.
    gpp = '';
    candidates = {};
    location = getenv('MW_MINGW64_LOC');
    if ~isempty(location)
        candidates{end + 1} = fullfile(location, 'bin', 'g++.exe');
    end
    try
        configs = mex.getCompilerConfigurations('C++', 'Installed');
        for k = 1:numel(configs)
            if contains(configs(k).Name, 'MinGW', 'IgnoreCase', true)
                candidates{end + 1} = fullfile(configs(k).Location, 'bin', 'g++.exe'); %#ok<AGROW>
            end
        end
    catch
        % mex configuration lookup is optional; fall through to the default location.
    end
    release = ['R' version('-release')];
    candidates{end + 1} = fullfile(getenv('ProgramData'), 'MATLAB', 'SupportPackages', ...
        release, '3P.instrset', 'mingw_w64.instrset', 'bin', 'g++.exe');
    for k = 1:numel(candidates)
        if isfile(candidates{k})
            gpp = candidates{k};
            return
        end
    end
end
