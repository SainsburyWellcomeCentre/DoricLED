classdef ComplexMode < int32
%COMPLEXMODE Waveform of one Complex-mode segment (vendor LightSourceComplexMode).
%
%   The C++ header types ComplexModulation.mode as Doric::LightSource::Mode, but the vendor
%   Python definitions (lightsource_defs.py) use this separate enumeration, and the vendor
%   Complex example relies on its Delay and Triangle members. These values are used until the
%   rig check (M0) settles the question (docs/vendor-dll.md §4).
%
%   See also doric.ComplexSegment, doric.Mode

    enumeration
        Off      (0)
        CW       (1)
        Square   (2)
        Input    (3)
        Triangle (4)
        RampUp   (5)
        RampDown (6)
        Sine     (7)
        Stairs   (8)
        Custom   (9)
        Delay    (10)
        LockIn   (11)
    end
end
