/* doric_flat.h - flat C view of DoricSystem.dll for MATLAB's loadlibrary.
 *
 * The vendor headers are C++ (namespaces, enum class, default member initialisers), which
 * loadlibrary cannot parse, so the light-source subset is repeated here in plain C. Layout
 * follows docs/vendor-dll.md section 5; the sizes are checked by the bridge's SIZES command
 * (Settings 2088, TTLModulation 40, ComplexModulation 40 bytes, x64).
 *
 * Only doric.transport.LibraryTransport (the fallback transport) uses this file.
 */

typedef struct {
    unsigned short current;
    unsigned int startingDelayMs;
    unsigned int delayBetweenSeqMs;
    double periodMs;
    double timeOnMs;
    unsigned short risingTimeMs;
    unsigned short fallingTimeMs;
    unsigned short nbOfSeq;
    unsigned short nbOfPulsesPerSeq;
} DoricTTLModulation;

typedef struct {
    int mode;
    unsigned short current;
    unsigned int delayBetweenSeqMs;
    double periodMs;
    double timeOnMs;
    unsigned short nbOfSeq;
    unsigned short nbOfPulsesPerSeq;
    unsigned int startingDelayMs;
} DoricComplexModulation;

typedef struct {
    int channelIdx;
    int mode;
    unsigned char isTTLOutput;
    int triggerType;
    int triggerMode;
    unsigned char isRepeatableSequence;
    int currentMode;
    unsigned short customDataPoint[1000];
    DoricTTLModulation ttlModulation;
    unsigned char nbComplexModulations;
    DoricComplexModulation *complexModulations;
} DoricLightSourceSettings;

void init(unsigned char debuggerActive);
void quit(void);
void wait(int delayInMSec);
void available_devices(void);
void available_devices_with_ports(void);
void open_device(int portNumber);
void close_device(int portNumber);
void ls_start_all(int portNumber);
void ls_stop_all(int portNumber);
void ls_start_channel(int portNumber, int channelIndex);
void ls_stop_channel(int portNumber, int channelIndex);
void ls_send_settings(int portNumber, DoricLightSourceSettings *settings);
void ls_send_current(int portNumber, int channelIndex, unsigned short current);
