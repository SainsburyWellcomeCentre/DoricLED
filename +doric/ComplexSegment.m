classdef ComplexSegment
%COMPLEXSEGMENT One element of a Complex-mode sequence (vendor ComplexModulation).
%
%   seg = doric.ComplexSegment() uses the header defaults (CW, 0 mA, period 100 ms, on 50 ms,
%   1 sequence, 0 pulses per sequence, no delays).
%   seg = doric.ComplexSegment('Name', value, ...) sets any property.
%
%   Properties (vendor field, range)
%       Mode               mode               doric.ComplexMode (member, name or value)
%       CurrentmA          current            integer 0-65535
%       DelayBetweenSeqMs  delayBetweenSeqMs  integer 0-4294967295
%       PeriodMs           periodMs           real >= 0
%       TimeOnMs           timeOnMs           real >= 0
%       NbOfSeq            nbOfSeq            integer 0-65535
%       NbOfPulsesPerSeq   nbOfPulsesPerSeq   integer 0-65535
%       StartingDelayMs    startingDelayMs    integer 0-4294967295
%
%   Setting an invalid value errors with doric:ComplexSegment:invalidSettings, so an invalid
%   segment cannot exist. Values are never clamped.
%
%   Example
%       segs = [doric.ComplexSegment('Mode', 'Square', 'CurrentmA', 50, 'PeriodMs', 1000, ...
%                                    'TimeOnMs', 500, 'NbOfSeq', 5, 'NbOfPulsesPerSeq', 1), ...
%               doric.ComplexSegment('Mode', 'Delay', 'PeriodMs', 2000)];
%       s = doric.ChannelSettings.complex(segs);
%
%   See also doric.ChannelSettings, doric.ComplexMode

    properties
        Mode = doric.ComplexMode.CW
        CurrentmA = 0
        DelayBetweenSeqMs = 0
        PeriodMs = 100
        TimeOnMs = 50
        NbOfSeq = 1
        NbOfPulsesPerSeq = 0
        StartingDelayMs = 0
    end

    properties (Constant, Hidden)
        ErrorId = 'doric:ComplexSegment:invalidSettings'
    end

    methods
        function obj = ComplexSegment(varargin)
            if mod(numel(varargin), 2) ~= 0
                error(doric.ComplexSegment.ErrorId, ...
                    'ComplexSegment takes name-value pairs.');
            end
            for k = 1:2:numel(varargin)
                obj.(doric.ComplexSegment.propertyName(varargin{k})) = varargin{k + 1};
            end
        end

        function obj = set.Mode(obj, value)
            obj.Mode = toEnum('doric.ComplexMode', value, 'Mode', obj.ErrorId);
        end

        function obj = set.CurrentmA(obj, value)
            obj.CurrentmA = checkInteger(value, 0, 65535, 'CurrentmA', obj.ErrorId);
        end

        function obj = set.DelayBetweenSeqMs(obj, value)
            obj.DelayBetweenSeqMs = checkInteger(value, 0, 4294967295, 'DelayBetweenSeqMs', ...
                obj.ErrorId);
        end

        function obj = set.PeriodMs(obj, value)
            obj.PeriodMs = checkNonNegative(value, 'PeriodMs', obj.ErrorId);
        end

        function obj = set.TimeOnMs(obj, value)
            obj.TimeOnMs = checkNonNegative(value, 'TimeOnMs', obj.ErrorId);
        end

        function obj = set.NbOfSeq(obj, value)
            obj.NbOfSeq = checkInteger(value, 0, 65535, 'NbOfSeq', obj.ErrorId);
        end

        function obj = set.NbOfPulsesPerSeq(obj, value)
            obj.NbOfPulsesPerSeq = checkInteger(value, 0, 65535, 'NbOfPulsesPerSeq', obj.ErrorId);
        end

        function obj = set.StartingDelayMs(obj, value)
            obj.StartingDelayMs = checkInteger(value, 0, 4294967295, 'StartingDelayMs', ...
                obj.ErrorId);
        end

        function s = toStruct(obj)
        %TOSTRUCT Plain struct array (enum as name) for JSON or data files.
            s = struct('Mode', {}, 'CurrentmA', {}, 'DelayBetweenSeqMs', {}, 'PeriodMs', {}, ...
                'TimeOnMs', {}, 'NbOfSeq', {}, 'NbOfPulsesPerSeq', {}, 'StartingDelayMs', {});
            for k = 1:numel(obj)
                s(k).Mode = char(obj(k).Mode);
                s(k).CurrentmA = obj(k).CurrentmA;
                s(k).DelayBetweenSeqMs = obj(k).DelayBetweenSeqMs;
                s(k).PeriodMs = obj(k).PeriodMs;
                s(k).TimeOnMs = obj(k).TimeOnMs;
                s(k).NbOfSeq = obj(k).NbOfSeq;
                s(k).NbOfPulsesPerSeq = obj(k).NbOfPulsesPerSeq;
                s(k).StartingDelayMs = obj(k).StartingDelayMs;
            end
            s = reshape(s, 1, []);
        end
    end

    methods (Static)
        function obj = fromStruct(s)
        %FROMSTRUCT Build a 1-by-n segment array from a struct array or cell of structs.
        %   Missing fields keep the header defaults; enum fields accept names or values.
            if iscell(s)
                s = [s{:}];
            end
            obj = doric.ComplexSegment.empty(1, 0);
            if isempty(s)
                return
            end
            if ~isstruct(s)
                error(doric.ComplexSegment.ErrorId, 'ComplexSegments must be a struct array.');
            end
            for k = 1:numel(s)
                seg = doric.ComplexSegment();
                names = fieldnames(s(k));
                for f = 1:numel(names)
                    seg.(doric.ComplexSegment.propertyName(names{f})) = s(k).(names{f});
                end
                obj(k) = seg;
            end
        end
    end

    methods (Static, Access = private)
        function name = propertyName(name)
            if ~(ischar(name) || (isstring(name) && isscalar(name)))
                error(doric.ComplexSegment.ErrorId, 'Property names must be text.');
            end
            valid = properties('doric.ComplexSegment');
            match = strcmpi(valid, char(name));
            if ~any(match)
                error(doric.ComplexSegment.ErrorId, 'Unknown ComplexSegment property "%s".', ...
                    char(name));
            end
            name = valid{match};
        end
    end
end
