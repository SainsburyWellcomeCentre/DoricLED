#ifndef DORICOTPGHEADERS_H
#define DORICOTPGHEADERS_H

#include "doricsystemheaders.h"

#ifdef __cplusplus
extern "C" {
#endif

namespace Doric {
    namespace OTPG {
        typedef enum class Mode{
           Off,
           CW,
           Square,
           Input
        }Mode;

        typedef enum class SamplingFrequency{
           Freq_10Hz,
           Freq_100Hz,
           Freq_500Hz,
           Freq_1kHz,
           Freq_5kHz,
           Freq_10kHz
        }SamplingFrequency;

        struct Settings{
            Doric::System::Channel channelIdx = Doric::System::Channel::Channel_1;
            Mode mode = Mode::Off;
            Doric::System::Channel triggerSource = Doric::System::Channel::Undefined;
            Doric::System::TriggerType triggerType = Doric::System::TriggerType::Manual;
            Doric::System::TriggerMode triggerMode = Doric::System::TriggerMode::Uninterrupted;
            uint32_t startingDelayMs = 0;
            uint32_t delayBetweenSeqMs = 0;
            double periodMs = 100;
            double timeOnMs = 50;
            uint16_t nbOfSeq = 1;
            uint16_t nbOfPulsesPerSeq = 0;
            bool isRepeatableSequence = false;
            bool isInverted = false;
        };

        struct SamplingParameters{
            Doric::System::Channel triggerSource = Doric::System::Channel::Undefined;
            SamplingFrequency samplingFrequency = SamplingFrequency::Freq_1kHz;
        };
    }
}

#ifdef __cplusplus
}
#endif

#endif // DORICOTPGHEADERS_H
