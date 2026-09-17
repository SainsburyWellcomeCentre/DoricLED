classdef ChannelSettings
%CHANNELSETTINGS Every vendor setting of one light-source channel (value object).
%
%   s = doric.ChannelSettings() holds the vendor header defaults (Off, 0 mA, period 100 ms,
%   on 50 ms, 1 sequence, Manual trigger, Normal current mode).
%   s = doric.ChannelSettings('Name', value, ...) sets any property.
%
%   Nothing is sent to the device until the settings are applied with doric.Channel/apply.
%   Every property validates on assignment and errors with doric:ChannelSettings:invalidSettings,
%   so an invalid object cannot exist. Values are never clamped or rounded.
%
%   Properties (vendor field in Settings, range)
%       Mode                  mode                            doric.Mode
%       IsTTLOutput           isTTLOutput                     logical (true TTL, false ADC out)
%       TriggerType           triggerType                     doric.TriggerType
%       TriggerMode           triggerMode                     doric.TriggerMode
%       IsRepeatableSequence  isRepeatableSequence            logical
%       CurrentMode           currentMode                     doric.CurrentMode
%       CurrentmA             ttlModulation.current           integer 0-65535
%       StartingDelayMs       ttlModulation.startingDelayMs   integer 0-4294967295
%       DelayBetweenSeqMs     ttlModulation.delayBetweenSeqMs integer 0-4294967295
%       PeriodMs              ttlModulation.periodMs          real >= 0
%       TimeOnMs              ttlModulation.timeOnMs          real >= 0
%       RisingTimeMs          ttlModulation.risingTimeMs      integer 0-65535
%       FallingTimeMs         ttlModulation.fallingTimeMs     integer 0-65535
%       NbOfSeq               ttlModulation.nbOfSeq           integer 0-65535 (0 = infinite)
%       NbOfPulsesPerSeq      ttlModulation.nbOfPulsesPerSeq  integer 0-65535 (0 = infinite)
%       ComplexSegments       complexModulations (+count)     doric.ComplexSegment, 0-32
%       CustomDataPoints      customDataPoint                 integers 0-65535, <= 1000 points
%                                                             (sent padded with zeros)
%
%   Factories (the vendor examples' values; trailing name-value pairs override any property)
%       cw(mA)  extTTL(mA)  extAnalog(mA)  square(mA, periodMs, timeOnMs)  triggered(mA)
%       gated(mA)  complex(segments)  custom(pointsmA, periodMs)  off()
%
%   Methods
%       with(name, value, ...)  copy with properties changed
%       peakCurrentmA()         largest current any field would send
%       check()                 cellstr of warnings (e.g. TimeOnMs > PeriodMs); never errors
%       describe()              one-line summary
%       toStruct / fromStruct, toJSON / fromJSON
%
%   Example
%       s = doric.ChannelSettings.square(80, 1000, 500, 'TriggerType', 'Gated');
%       s.NbOfSeq = 0;
%
%   See also doric.Channel, doric.ComplexSegment, doric.Mode

    properties
        Mode = doric.Mode.Off
        IsTTLOutput = false
        TriggerType = doric.TriggerType.Manual
        TriggerMode = doric.TriggerMode.Uninterrupted
        IsRepeatableSequence = false
        CurrentMode = doric.CurrentMode.Normal
        CurrentmA = 0
        StartingDelayMs = 0
        DelayBetweenSeqMs = 0
        PeriodMs = 100
        TimeOnMs = 50
        RisingTimeMs = 0
        FallingTimeMs = 0
        NbOfSeq = 1
        NbOfPulsesPerSeq = 0
        ComplexSegments = doric.ComplexSegment.empty(1, 0)
        CustomDataPoints = zeros(1, 0)
    end

    properties (Constant)
        MaxComplexSegments = 32
        MaxCustomDataPoints = 1000
    end

    properties (Constant, Hidden)
        ErrorId = 'doric:ChannelSettings:invalidSettings'
    end

    methods
        function obj = ChannelSettings(varargin)
            obj = obj.with(varargin{:});
        end

        function obj = with(obj, varargin)
        %WITH Return a copy with the given name-value pairs applied (names case-insensitive).
            if mod(numel(varargin), 2) ~= 0
                error(doric.ChannelSettings.ErrorId, 'Settings take name-value pairs.');
            end
            for k = 1:2:numel(varargin)
                obj.(doric.ChannelSettings.propertyName(varargin{k})) = varargin{k + 1};
            end
        end

        % ---- validation --------------------------------------------------------------------

        function obj = set.Mode(obj, value)
            obj.Mode = toEnum('doric.Mode', value, 'Mode', obj.ErrorId);
        end

        function obj = set.IsTTLOutput(obj, value)
            obj.IsTTLOutput = checkLogical(value, 'IsTTLOutput', obj.ErrorId);
        end

        function obj = set.TriggerType(obj, value)
            obj.TriggerType = toEnum('doric.TriggerType', value, 'TriggerType', obj.ErrorId);
        end

        function obj = set.TriggerMode(obj, value)
            obj.TriggerMode = toEnum('doric.TriggerMode', value, 'TriggerMode', obj.ErrorId);
        end

        function obj = set.IsRepeatableSequence(obj, value)
            obj.IsRepeatableSequence = checkLogical(value, 'IsRepeatableSequence', obj.ErrorId);
        end

        function obj = set.CurrentMode(obj, value)
            obj.CurrentMode = toEnum('doric.CurrentMode', value, 'CurrentMode', obj.ErrorId);
        end

        function obj = set.CurrentmA(obj, value)
            obj.CurrentmA = checkInteger(value, 0, 65535, 'CurrentmA', obj.ErrorId);
        end

        function obj = set.StartingDelayMs(obj, value)
            obj.StartingDelayMs = checkInteger(value, 0, 4294967295, 'StartingDelayMs', ...
                obj.ErrorId);
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

        function obj = set.RisingTimeMs(obj, value)
            obj.RisingTimeMs = checkInteger(value, 0, 65535, 'RisingTimeMs', obj.ErrorId);
        end

        function obj = set.FallingTimeMs(obj, value)
            obj.FallingTimeMs = checkInteger(value, 0, 65535, 'FallingTimeMs', obj.ErrorId);
        end

        function obj = set.NbOfSeq(obj, value)
            obj.NbOfSeq = checkInteger(value, 0, 65535, 'NbOfSeq', obj.ErrorId);
        end

        function obj = set.NbOfPulsesPerSeq(obj, value)
            obj.NbOfPulsesPerSeq = checkInteger(value, 0, 65535, 'NbOfPulsesPerSeq', obj.ErrorId);
        end

        function obj = set.ComplexSegments(obj, value)
            if isempty(value)
                value = doric.ComplexSegment.empty(1, 0);
            elseif isstruct(value) || iscell(value)
                value = doric.ComplexSegment.fromStruct(value);
            end
            if ~isa(value, 'doric.ComplexSegment') || ~isvector(value)
                error(obj.ErrorId, 'ComplexSegments must be a vector of doric.ComplexSegment.');
            end
            if numel(value) > doric.ChannelSettings.MaxComplexSegments
                error(obj.ErrorId, 'ComplexSegments holds at most %d segments; got %d.', ...
                    doric.ChannelSettings.MaxComplexSegments, numel(value));
            end
            obj.ComplexSegments = reshape(value, 1, []);
        end

        function obj = set.CustomDataPoints(obj, value)
            if isempty(value)
                obj.CustomDataPoints = zeros(1, 0);
                return
            end
            if ~(isnumeric(value) || islogical(value)) || ~isvector(value) || ~isreal(value)
                error(obj.ErrorId, 'CustomDataPoints must be a numeric vector of mA values.');
            end
            value = double(reshape(value, 1, []));
            if numel(value) > doric.ChannelSettings.MaxCustomDataPoints
                error(obj.ErrorId, 'CustomDataPoints holds at most %d points; got %d.', ...
                    doric.ChannelSettings.MaxCustomDataPoints, numel(value));
            end
            if any(~isfinite(value) | value ~= fix(value) | value < 0 | value > 65535)
                error(obj.ErrorId, 'CustomDataPoints must be integers in [0, 65535] (mA).');
            end
            obj.CustomDataPoints = value;
        end

        % ---- queries -----------------------------------------------------------------------

        function mA = peakCurrentmA(obj)
        %PEAKCURRENTMA Largest current in any field that is sent (current, segments, custom).
            mA = obj.CurrentmA;
            if ~isempty(obj.ComplexSegments)
                mA = max([mA, obj.ComplexSegments.CurrentmA]);
            end
            if ~isempty(obj.CustomDataPoints)
                mA = max(mA, max(obj.CustomDataPoints));
            end
        end

        function warnings = check(obj)
        %CHECK Plausibility warnings (cellstr). Nothing here is enforced; the user decides.
            warnings = {};
            if obj.TimeOnMs > obj.PeriodMs
                warnings{end + 1} = sprintf('TimeOnMs (%g) is longer than PeriodMs (%g).', ...
                    obj.TimeOnMs, obj.PeriodMs);
            end
            if obj.Mode == doric.Mode.Complex && isempty(obj.ComplexSegments)
                warnings{end + 1} = 'Mode is Complex but ComplexSegments is empty.';
            end
            if obj.Mode == doric.Mode.Custom && isempty(obj.CustomDataPoints)
                warnings{end + 1} = 'Mode is Custom but CustomDataPoints is empty.';
            end
            for k = 1:numel(obj.ComplexSegments)
                seg = obj.ComplexSegments(k);
                if seg.TimeOnMs > seg.PeriodMs
                    warnings{end + 1} = sprintf(['ComplexSegments(%d): TimeOnMs (%g) is ' ...
                        'longer than PeriodMs (%g).'], k, seg.TimeOnMs, seg.PeriodMs); %#ok<AGROW>
                end
            end
        end

        function text = describe(obj)
        %DESCRIBE One-line human-readable summary.
            parts = {char(obj.Mode), sprintf('%d mA', obj.CurrentmA)};
            switch obj.Mode
                case {doric.Mode.Square, doric.Mode.Custom}
                    parts{end + 1} = sprintf('period %g ms', obj.PeriodMs);
                    if obj.Mode == doric.Mode.Square
                        parts{end + 1} = sprintf('on %g ms', obj.TimeOnMs);
                    else
                        parts{end + 1} = sprintf('%d points', numel(obj.CustomDataPoints));
                    end
                    parts{end + 1} = sprintf('%d seq x %d pulses', obj.NbOfSeq, ...
                        obj.NbOfPulsesPerSeq);
                case doric.Mode.Complex
                    parts{end + 1} = sprintf('%d segments', numel(obj.ComplexSegments));
            end
            if obj.TriggerType ~= doric.TriggerType.Manual
                parts{end + 1} = sprintf('%s/%s', char(obj.TriggerType), char(obj.TriggerMode));
            end
            if obj.CurrentMode ~= doric.CurrentMode.Normal
                parts{end + 1} = char(obj.CurrentMode);
            end
            text = strjoin(parts, ', ');
        end

        % ---- conversions -------------------------------------------------------------------

        function s = toStruct(obj)
        %TOSTRUCT Plain struct (enums as names, numbers as double) for JSON and data files.
            s = struct();
            s.Mode = char(obj.Mode);
            s.IsTTLOutput = obj.IsTTLOutput;
            s.TriggerType = char(obj.TriggerType);
            s.TriggerMode = char(obj.TriggerMode);
            s.IsRepeatableSequence = obj.IsRepeatableSequence;
            s.CurrentMode = char(obj.CurrentMode);
            s.CurrentmA = obj.CurrentmA;
            s.StartingDelayMs = obj.StartingDelayMs;
            s.DelayBetweenSeqMs = obj.DelayBetweenSeqMs;
            s.PeriodMs = obj.PeriodMs;
            s.TimeOnMs = obj.TimeOnMs;
            s.RisingTimeMs = obj.RisingTimeMs;
            s.FallingTimeMs = obj.FallingTimeMs;
            s.NbOfSeq = obj.NbOfSeq;
            s.NbOfPulsesPerSeq = obj.NbOfPulsesPerSeq;
            s.ComplexSegments = toStruct(obj.ComplexSegments);
            s.CustomDataPoints = obj.CustomDataPoints;
        end

        function text = toJSON(obj)
        %TOJSON JSON text of toStruct.
            s = obj.toStruct();
            % Keep arrays as arrays in JSON even with 0 or 1 elements.
            s.ComplexSegments = num2cell(s.ComplexSegments);
            s.CustomDataPoints = num2cell(s.CustomDataPoints);
            text = jsonencode(s, 'PrettyPrint', true);
        end
    end

    methods (Static)
        function obj = fromStruct(s)
        %FROMSTRUCT Build settings from a struct (e.g. toStruct or jsondecode output).
        %   Missing fields keep the header defaults; unknown fields error.
            if isa(s, 'doric.ChannelSettings')
                obj = s;
                return
            end
            if ~isstruct(s) || ~isscalar(s)
                error(doric.ChannelSettings.ErrorId, 'fromStruct needs a scalar struct.');
            end
            obj = doric.ChannelSettings();
            names = fieldnames(s);
            for k = 1:numel(names)
                obj.(doric.ChannelSettings.propertyName(names{k})) = s.(names{k});
            end
        end

        function obj = fromJSON(text)
        %FROMJSON Build settings from JSON text produced by toJSON.
            obj = doric.ChannelSettings.fromStruct(jsondecode(char(text)));
        end

        % ---- factories (vendor example values, docs/vendor-dll.md §6) ------------------------

        function obj = off(varargin)
        %OFF Mode Off with header defaults.
            obj = doric.ChannelSettings('Mode', doric.Mode.Off, varargin{:});
        end

        function obj = cw(mA, varargin)
        %CW Continuous wave at mA (vendor example: 100 mA).
            if nargin < 1 || isempty(mA), mA = 100; end
            obj = doric.ChannelSettings('Mode', doric.Mode.CW, 'CurrentmA', mA, varargin{:});
        end

        function obj = extTTL(mA, varargin)
        %EXTTTL Current mA while the TTL input is high (vendor example: 100 mA).
            if nargin < 1 || isempty(mA), mA = 100; end
            obj = doric.ChannelSettings('Mode', doric.Mode.ExtTTL, 'CurrentmA', mA, varargin{:});
        end

        function obj = extAnalog(mA, varargin)
        %EXTANALOG Analog input scaled to mA (vendor example: 1000 mA).
            if nargin < 1 || isempty(mA), mA = 1000; end
            obj = doric.ChannelSettings('Mode', doric.Mode.ExtAnalog, 'CurrentmA', mA, ...
                varargin{:});
        end

        function obj = square(mA, periodMs, timeOnMs, varargin)
        %SQUARE Free-running square wave (vendor example: 50 mA, 1000 ms, 500 ms on, TTL out,
        %   infinite sequences and pulses).
            if nargin < 1 || isempty(mA), mA = 50; end
            if nargin < 2 || isempty(periodMs), periodMs = 1000; end
            if nargin < 3 || isempty(timeOnMs), timeOnMs = 500; end
            obj = doric.ChannelSettings('Mode', doric.Mode.Square, 'IsTTLOutput', true, ...
                'CurrentmA', mA, 'PeriodMs', periodMs, 'TimeOnMs', timeOnMs, 'NbOfSeq', 0, ...
                'NbOfPulsesPerSeq', 0, 'StartingDelayMs', 0, 'DelayBetweenSeqMs', 0, varargin{:});
        end

        function obj = triggered(mA, varargin)
        %TRIGGERED Square pulses started by a TTL edge (vendor example: 50 mA, 5 sequences of
        %   5 pulses, 100 ms period, 50 ms on, 2000 ms between sequences, Triggered/Pause).
            if nargin < 1 || isempty(mA), mA = 50; end
            obj = doric.ChannelSettings('Mode', doric.Mode.Square, 'IsTTLOutput', true, ...
                'CurrentmA', mA, 'PeriodMs', 100, 'TimeOnMs', 50, 'NbOfSeq', 5, ...
                'NbOfPulsesPerSeq', 5, 'DelayBetweenSeqMs', 2000, ...
                'TriggerType', doric.TriggerType.Triggered, ...
                'TriggerMode', doric.TriggerMode.Pause, varargin{:});
        end

        function obj = gated(mA, varargin)
        %GATED Square pulses while the TTL input is high (vendor example: 250 mA, 100 ms
        %   period, 50 ms on, infinite, Gated/Restart).
            if nargin < 1 || isempty(mA), mA = 250; end
            obj = doric.ChannelSettings('Mode', doric.Mode.Square, 'CurrentmA', mA, ...
                'PeriodMs', 100, 'TimeOnMs', 50, 'NbOfSeq', 0, 'NbOfPulsesPerSeq', 0, ...
                'DelayBetweenSeqMs', 0, 'TriggerType', doric.TriggerType.Gated, ...
                'TriggerMode', doric.TriggerMode.Restart, varargin{:});
        end

        function obj = complex(segments, varargin)
        %COMPLEX Complex mode with the given segments (default: the vendor example's Square,
        %   Delay and Triangle segments).
            if nargin < 1
                segments = [ ...
                    doric.ComplexSegment('Mode', 'Square', 'CurrentmA', 50, 'NbOfSeq', 5, ...
                        'NbOfPulsesPerSeq', 1, 'PeriodMs', 1000, 'TimeOnMs', 500), ...
                    doric.ComplexSegment('Mode', 'Delay', 'NbOfSeq', 1, ...
                        'NbOfPulsesPerSeq', 1, 'PeriodMs', 2000, 'StartingDelayMs', 500), ...
                    doric.ComplexSegment('Mode', 'Triangle', 'CurrentmA', 100, 'NbOfSeq', 3, ...
                        'NbOfPulsesPerSeq', 2, 'DelayBetweenSeqMs', 1000, 'PeriodMs', 1500, ...
                        'TimeOnMs', 1500, 'StartingDelayMs', 7000)];
            end
            obj = doric.ChannelSettings('Mode', doric.Mode.Complex, ...
                'ComplexSegments', segments, varargin{:});
        end

        function obj = custom(pointsmA, periodMs, varargin)
        %CUSTOM Custom waveform (vendor example: points 0..999 mA, period 2500 ms, starting
        %   delay 2000 ms, 500 ms between sequences, 6 sequences).
            if nargin < 1 || isempty(pointsmA), pointsmA = 0:999; end
            if nargin < 2 || isempty(periodMs), periodMs = 2500; end
            obj = doric.ChannelSettings('Mode', doric.Mode.Custom, ...
                'CustomDataPoints', pointsmA, 'PeriodMs', periodMs, 'StartingDelayMs', 2000, ...
                'DelayBetweenSeqMs', 500, 'NbOfSeq', 6, varargin{:});
        end
    end

    methods (Static, Access = private)
        function name = propertyName(name)
            if ~(ischar(name) || (isstring(name) && isscalar(name)))
                error(doric.ChannelSettings.ErrorId, 'Property names must be text.');
            end
            valid = setdiff(properties('doric.ChannelSettings'), ...
                {'MaxComplexSegments', 'MaxCustomDataPoints'}, 'stable');
            match = strcmpi(valid, char(name));
            if ~any(match)
                error(doric.ChannelSettings.ErrorId, 'Unknown ChannelSettings property "%s".', ...
                    char(name));
            end
            name = valid{match};
        end
    end
end
