classdef TriggerMode < int32
%TRIGGERMODE What a trigger does to a running sequence (vendor Doric::System::TriggerMode).
%
%   Values match doricsystemheaders.h (docs/vendor-dll.md §4).
%
%   See also doric.TriggerType, doric.ChannelSettings

    enumeration
        Uninterrupted (0)
        Pause         (1)
        Continue      (2)
        Restart       (3)
    end
end
