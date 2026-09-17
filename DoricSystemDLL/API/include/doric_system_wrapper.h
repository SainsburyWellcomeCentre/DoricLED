#ifndef DORIC_SYSTEM_WRAPPER_H
#define DORIC_SYSTEM_WRAPPER_H

#include "doricotpgheaders.h"
#include "doriclightsourceheaders.h"
#include "doricrotaryjointheaders.h"
#include "doric_system_wrapper_global.h"

#ifdef __cplusplus
extern "C" {
#endif

    namespace Doric {
        namespace System {
            /* USER SYSTEM FUNCTION */
            void DORIC_SYSTEM_WRAPPER_EXPORT init(bool debuggerActive);
            void DORIC_SYSTEM_WRAPPER_EXPORT quit();
            void DORIC_SYSTEM_WRAPPER_EXPORT wait(int delayInMSec);
            void DORIC_SYSTEM_WRAPPER_EXPORT available_devices();
            void DORIC_SYSTEM_WRAPPER_EXPORT available_devices_with_ports();
            void DORIC_SYSTEM_WRAPPER_EXPORT open_device(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT close_device(int portNumber);
        }

        namespace LightSource {
            /* USER LIGHTSOURCE FUNCTION */
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_start_all(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_stop_all(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_start_channel(int portNumber, Doric::System::Channel channelIndex);
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_stop_channel(int portNumber, Doric::System::Channel channelIndex);
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_send_settings(int portNumber, Doric::LightSource::Settings *settings);
            void DORIC_SYSTEM_WRAPPER_EXPORT ls_send_current(int portNumber, Doric::System::Channel channelIndex, uint16_t current);
        }

        namespace OTPG {
            /* USER OTPG FUNCTION */
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_start_all(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_stop_all(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_send_settings(int portNumber, Doric::OTPG::Settings *settings);
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_send_delete_settings(int portNumber, Doric::System::Channel channelIndex);
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_send_sampling_parameters(int portNumber, Doric::OTPG::SamplingParameters *samplingParameters);
            void DORIC_SYSTEM_WRAPPER_EXPORT otpg_send_timeseries_properties(int portNumber, Doric::System::TimeSeriesProperties *timeseriesProperties);
        }

        namespace RotaryJoint {
            /* USER ROTARY JOINT FUNCTION */
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_motor_power_on(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_motor_power_off(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_settings(int portNumber, Doric::RotaryJoint::Settings *settings);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_activated(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_deactivated(int portNumber);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_duty_cycle(int portNumber, double dutyCycle);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_direction(int portNumber, Doric::RotaryJoint::MotorDirection direction);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_turn_per_side(int portNumber, uint8_t nbTurns);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_send_manual_control_mode(int portNumber, Doric::RotaryJoint::MotorMode mode);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_get_current_detectors_state(int portNumber, uint32_t &detectorsState);
            void DORIC_SYSTEM_WRAPPER_EXPORT rotary_joint_get_current_motor_angle(int portNumber, uint16_t &motorAngle);
        }
    }

#ifdef __cplusplus
}
#endif



#endif // DORIC_SYSTEM_WRAPPER_H
