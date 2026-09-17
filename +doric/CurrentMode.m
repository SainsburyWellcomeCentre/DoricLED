classdef CurrentMode < int32
%CURRENTMODE Current range of a channel (vendor Doric::LightSource::CurrentMode).
%
%   Values match doriclightsourceheaders.h (docs/vendor-dll.md §4).
%
%   See also doric.ChannelSettings

    enumeration
        Normal    (0)
        LowPower  (1)
        Overdrive (2)
    end
end
