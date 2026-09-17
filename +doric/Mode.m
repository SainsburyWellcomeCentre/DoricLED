classdef Mode < int32
%MODE Operating mode of one light-source channel (vendor Doric::LightSource::Mode).
%
%   Values match DoricSystemDLL/API/include/doriclightsourceheaders.h (docs/vendor-dll.md §4).
%   The vendor Python definitions also list MicroscopeFollower (10); it is left out until the
%   rig check (M0) confirms it on the LEDFLS_465_465.
%
%   Off        channel off
%   CW         continuous wave at CurrentmA
%   ExtTTL     CurrentmA while the external TTL input is high
%   ExtAnalog  external analog input scaled by CurrentmA
%   Square     internally generated pulse trains (timing fields)
%   Complex    sequence of ComplexSegments
%   Custom     1000-point waveform from CustomDataPoints
%
%   See also doric.ChannelSettings, doric.ComplexMode

    enumeration
        Off       (0)
        CW        (1)
        ExtTTL    (2)
        ExtAnalog (3)
        Square    (4)
        Complex   (5)
        Custom    (6)
    end
end
