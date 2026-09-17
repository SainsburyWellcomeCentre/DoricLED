#ifndef DORICSYSTEMHEADERS_H
#define DORICSYSTEMHEADERS_H

#ifdef __cplusplus
extern "C" {
#endif

    namespace Doric {
        namespace System {

            typedef enum class TriggerType{
               Triggered,
               Gated,
               Manual = 255
            }TriggerType;

            typedef enum class TriggerMode{
               Uninterrupted,
               Pause,
               Continue,
               Restart
            }TriggerMode;

            typedef enum class Channel{
               Channel_1,
               Channel_2,
               Channel_3,
               Channel_4,
               Channel_5,
               Channel_6,
               Channel_7,
               Channel_8,
               Undefined = 255
            }Channel;

            struct TimeSeriesProperties{
                uint32_t activeTimeMs;
                uint16_t numberOfSeries;
                uint32_t delayBetweenSeriesMs;
                bool isUsingTimeSeries;
            };
        }
    }

#ifdef __cplusplus
}
#endif

#endif // DORICSYSTEMHEADERS_H
