#ifndef DORICROTARYJOINTHEADERS_H
#define DORICROTARYJOINTHEADERS_H

#include "doricsystemheaders.h"

#ifdef __cplusplus
extern "C" {
#endif

namespace Doric {
    namespace RotaryJoint {
        typedef enum class SamplingRate{
            kFreq_10Hz,
            kFreq_30Hz,
            kFreq_60Hz,
            kFreq_120Hz,
            kFreq_300Hz,
            kFreq_600Hz,
            kFreq_1200Hz,
        }SamplingRate;

        typedef enum class MotorSpeedFactor{
            kSPEED_FACTOR_FULL = 1,
            kSPEED_FACTOR_NORMAL = 2,
            kSPEED_FACTOR_HALF = 4,
        }MotorSpeedFactor;

        typedef enum class MotorDirection{
            kDirection_NoDirection,
            kDirection_Clockwise ,
            kDirection_CounterClockwise ,
        }MotorDirection;

        typedef enum class MotorMode{
            kMode_Manual,
            kMode_Continuous,
            kMode_TurnPerSide,
            kMode_Random
        }MotorMode;

        struct Settings{
            SamplingRate samplingRate = SamplingRate::kFreq_1200Hz;
            MotorSpeedFactor motorSpeed = MotorSpeedFactor::kSPEED_FACTOR_NORMAL;
        };
    }
}

#ifdef __cplusplus
}
#endif

#endif // DORICROTARYJOINTHEADERS_H
