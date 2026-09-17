#ifndef DORICLIGHTSOURCEHEADERS_H
#define DORICLIGHTSOURCEHEADERS_H


#include "doricsystemheaders.h"

#ifdef __cplusplus
extern "C" {
#endif

    namespace Doric {
        namespace LightSource {
            typedef enum class Mode{
               Off,
               CW,
               ExtTTL,
               ExtAnalog,
               Square,
               Complex,
               Custom
            }Mode;

            typedef enum class CurrentMode{
               Normal,
               LowPower,
               Overdrive
            }CurrentMode;

            struct TTLModulation{
                uint16_t current = 0;
                uint32_t startingDelayMs = 0;
                uint32_t delayBetweenSeqMs = 0;
                double periodMs = 100;
                double timeOnMs = 50;
                uint16_t risingTimeMs = 0;
                uint16_t fallingTimeMs = 0;
                uint16_t nbOfSeq = 1;
                uint16_t nbOfPulsesPerSeq = 0;
            };

            struct ComplexModulation{
                Mode mode = Mode::CW;
                uint16_t current = 0;
                uint32_t delayBetweenSeqMs = 0;
                double periodMs = 100;
                double timeOnMs = 50;
                uint16_t nbOfSeq = 1;
                uint16_t nbOfPulsesPerSeq = 0;
                uint32_t startingDelayMs = 0;
            };

            struct Settings{
                Doric::System::Channel channelIdx = Doric::System::Channel::Channel_1;
                Mode mode = Mode::Off;
                bool isTTLOutput = false;
                Doric::System::TriggerType triggerType = Doric::System::TriggerType::Manual;
                Doric::System::TriggerMode triggerMode = Doric::System::TriggerMode::Uninterrupted;
                bool isRepeatableSequence = false;
                CurrentMode currentMode = CurrentMode::Normal;
                uint16_t customDataPoint[1000] = {0};
                TTLModulation ttlModulation;

                uint8_t nbComplexModulations = 0;
                ComplexModulation *complexModulations = new ComplexModulation();
            };
        }

    }

#ifdef __cplusplus
}
#endif

#endif // DORICLIGHTSOURCEHEADERS_H
