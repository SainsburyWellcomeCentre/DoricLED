classdef MessageClassifier
%MESSAGECLASSIFIER Severity of vendor library text, by pattern.
%
%   severity = doric.transport.MessageClassifier.classify(text)
%       Returns 'error', 'warning' or 'info'. Matching is case-insensitive substring search;
%       error patterns win over warning patterns; unknown text is 'info' (never dropped).
%   tf = doric.transport.MessageClassifier.isDeviceNotFound(text)
%       True for the library's "Device not found" family of messages.
%
%   The pattern tables mirror severityOf() in native/doric_bridge/doric_bridge.cpp; keep them in
%   step. Strings come from DoricSystem.dll (docs/vendor-dll.md §2).
%
%   See also doric.transport.ProtocolCodec, doric.LightSource

    properties (Constant)
        ErrorPatterns = {'unable to', 'could not', 'couldn''t', 'not initialized', ...
            'device not found', 'not a lightsource driver', 'wrong controller', 'error', ...
            'failed', 'invalid'}
        WarningPatterns = {'no available device', 'already initialized', 'warning', ...
            'timeout', 'timed out'}
    end

    methods (Static)
        function severity = classify(text)
            lower_ = lower(char(text));
            patterns = doric.transport.MessageClassifier.ErrorPatterns;
            for k = 1:numel(patterns)
                if contains(lower_, patterns{k})
                    severity = 'error';
                    return
                end
            end
            patterns = doric.transport.MessageClassifier.WarningPatterns;
            for k = 1:numel(patterns)
                if contains(lower_, patterns{k})
                    severity = 'warning';
                    return
                end
            end
            severity = 'info';
        end

        function tf = isDeviceNotFound(text)
            lower_ = lower(char(text));
            tf = contains(lower_, 'device not found') || ...
                contains(lower_, 'port number not used by a doric device');
        end
    end
end
