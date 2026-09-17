classdef TriggerType < int32
%TRIGGERTYPE How a sequence reacts to the TTL input (vendor Doric::System::TriggerType).
%
%   Triggered  an input edge starts the sequence
%   Gated      the sequence runs while the input is high
%   Manual     start/stop from software only (header default)
%
%   Values match doricsystemheaders.h (docs/vendor-dll.md §4).
%
%   See also doric.TriggerMode, doric.ChannelSettings

    enumeration
        Triggered (0)
        Gated     (1)
        Manual    (255)
    end
end
