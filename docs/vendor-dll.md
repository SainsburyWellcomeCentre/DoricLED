# Vendor DLL notes (`DoricSystemDLL`)

Discovery notes from inspecting `DoricSystemDLL/` (read-only vendor folder) and the host PC, plus
what the bridge confirmed by compiling against the vendor headers (§8). Anything still marked
**verify** needs the real library with the device attached (an operator-approved run; see
`rig-checks.md`) and this file updated with the result.

## 1. What ships

| Path | Content |
|---|---|
| `API/include/doric_system_wrapper.h` | Function declarations (all four device families) |
| `API/include/doricsystemheaders.h` | `Doric::System` enums (`TriggerType`, `TriggerMode`, `Channel`), `TimeSeriesProperties` |
| `API/include/doriclightsourceheaders.h` | `Doric::LightSource` enums (`Mode`, `CurrentMode`) and structs (`TTLModulation`, `ComplexModulation`, `Settings`) |
| `API/include/doric_system_wrapper_global.h` | `__declspec(dllexport/dllimport)` macro |
| `API/lib/x64/release/DoricSystem.{dll,lib}` | Release build, MSVC 2019, x64 (Dec 2024) |
| `API/lib/x64/release/Qt/` | 79 runtime files: an **identical** copy of `DoricSystem.dll` (same md5) plus every dependency (Qt6, OpenCV 4.5.4, Andor `at*`, Zaber, IC4, HDF5, FFmpeg, MSVC runtime, Qt plugins) |
| `API/lib/x64/debug/` | Debug build, same layout |
| `Docs/UserManual.pdf` | DoricSystemDLL User Manual v1.1.0. The "Matlab/Octave" install section says only *"In progress"* |
| `Examples/CPP/LightSource/simple_lightsource.cpp` | Minimal C++ light-source example |
| `Examples/Python/LightSource/*.py` | `ctypes` definitions and example classes for every mode |

**Load from `API/lib/x64/release/Qt/`**: that folder is self-contained, which is what the manual
tells Python users to do.

## 2. Exported functions

`objdump -p` shows 30 **undecorated** exports (the declarations sit inside `extern "C"`), so they
can be resolved by plain name (`GetProcAddress`, `ctypes`, `loadlibrary`). Every function returns
`void`. The light-source relevant subset:

| Export | Signature (C view) | Notes from the manual |
|---|---|---|
| `init` | `void init(bool debuggerActive)` | Must be called first; starts device detection. Examples wait 5–10 s afterwards |
| `quit` | `void quit(void)` | Must be called last |
| `wait` | `void wait(int delayMs)` | Max 65535. "Lets the library execute its functionalities", i.e. it pumps the library's internal (Qt) event loop. **Examples call it after every command** ("wait for the settings to be sent") |
| `available_devices` | `void available_devices(void)` | Only **prints a debug message** with device names |
| `available_devices_with_ports` | `void available_devices_with_ports(void)` | Only **prints** names and port numbers (format string in the DLL: `%1 (Port #%2)`) |
| `open_device` | `void open_device(int portNumber)` | "USB-port number of the device". Examples wait 5 s afterwards |
| `close_device` | `void close_device(int portNumber)` | Examples wait 1 s afterwards |
| `ls_start_all` / `ls_stop_all` | `void (int portNumber)` | Start/stop every configured channel |
| `ls_start_channel` / `ls_stop_channel` | `void (int portNumber, int channelIndex)` | Channel index is **0-based** (`enum class Channel : int`) |
| `ls_send_settings` | `void (int portNumber, Settings *settings)` | Configures one channel (`settings->channelIdx`) |
| `ls_send_current` | `void (int portNumber, int channelIndex, uint16_t currentmA)` | "Can be called at every moment, even when the sequence is started" |

The other exports (`otpg_*`, `rotary_joint_*`) are out of scope.

### Consequences

- **The API is write-only.** There is no query for mode, current, running state, errors or
  device identity. The package can only track what it *commanded*.
- **The only feedback is debug text** the DLL prints. The binary contains, among others:
  `No available device(s)`, `Could not list available device(s). System not initialized yet`,
  `Unable to connect device... Device not found`, `Unable to send settings... Device not found`,
  `Unable to send current... Device not found`, `Unable to start channel... Device not found`,
  `Couldn't get device, port number not used by a Doric device`. Capturing that text is the only
  way to detect failure (this is decision D1 in `architecture.md`). **Verify** which stream it goes
  to (stdout, stderr, or `OutputDebugString`) and whether `init(true)` changes that.
- Commands are probably queued to the library's own thread and executed while `wait()` pumps.
  **Verify** whether a command reaches the device without a following `wait()`, and measure the
  latency of `ls_send_current`, `ls_start_channel` and `ls_stop_channel`.

## 3. Headers are C++, not C

The headers use `namespace`, `enum class`, default member initializers and
`ComplexModulation *complexModulations = new ComplexModulation();` inside `extern "C"`. MATLAB's
`loadlibrary` cannot parse them. Options: compile against them as C++ (the bridge, D1), or write
a separate flat C header for `loadlibrary` (fallback transport). `uint16_t` etc. are used without
`#include <cstdint>`, so include it before the vendor headers.

## 4. Enumerations (header values)

```
Channel:      Channel_1=0 … Channel_8=7, Undefined=255
TriggerType:  Triggered=0, Gated=1, Manual=255
TriggerMode:  Uninterrupted=0, Pause=1, Continue=2, Restart=3
Mode:         Off=0, CW=1, ExtTTL=2, ExtAnalog=3, Square=4, Complex=5, Custom=6
CurrentMode:  Normal=0, LowPower=1, Overdrive=2
```

Differences in the vendor Python definitions (`lightsource_defs.py`), to **verify**:

- `LightSourceMode` also has `MicroscopeFollower = 10`.
- `ComplexModulation.mode` uses a *different* enum, `LightSourceComplexMode`:
  `Off=0, CW=1, Square=2, Input=3, Triangle=4, RampUp=5, RampDown=6, Sine=7, Stairs=8, Custom=9,
  Delay=10, LockIn=11`. The C++ header types the field as `LightSource::Mode`. The Python enum
  (with `Delay`, `Triangle`, …, used by the Complex example) is most likely what the firmware
  expects.
- The Python field `isTriggerRepeatable` is the header's `isRepeatableSequence` (same slot).
- Python pre-allocates **32** `ComplexModulation` elements (`LIGHTSOURCE_MAX_COMPLEX_SEQ`); the
  manual gives `nbComplexModulations` a maximum of 32.
- Vendor bug: `Example_Light_Complex` and `Example_Light_Custom` call
  `DoricLightSourceDriver_send_settings`, which is **not exported**. Use `ls_send_settings`.

## 5. Structures (layout confirmed by compilation, 2026-09-17)

`doric_bridge.exe --simulate` answers `SIZES` with `sizeof`/`offsetof` taken from the vendor
headers as compiled by MinGW-w64 g++ 8.1 for x64. Every value matches the layout expected for
MSVC x64 below, so the hand-written table was correct and
`+doric/+transport/private/doric_flat.h` (the `loadlibrary` fallback) agrees with it:

```
sizeof: Settings 2088, TTLModulation 40, ComplexModulation 40; alignof(Settings) 8
Settings offsets:   channelIdx 0, mode 4, isTTLOutput 8, triggerType 12, triggerMode 16,
                    isRepeatableSequence 20, currentMode 24, customDataPoint 28,
                    ttlModulation 2032, nbComplexModulations 2072, complexModulations 2080
TTLModulation:      current 0, startingDelayMs 4, delayBetweenSeqMs 8, periodMs 16, timeOnMs 24,
                    risingTimeMs 32, fallingTimeMs 34, nbOfSeq 36, nbOfPulsesPerSeq 38
ComplexModulation:  mode 0, current 4, delayBetweenSeqMs 8, periodMs 16, timeOnMs 24,
                    nbOfSeq 32, nbOfPulsesPerSeq 34, startingDelayMs 36
```

`tests/BridgeProtocolTest.m/structSizesMatchTheDocumentedLayout` pins these numbers. What compiling
cannot prove is that the DLL (MSVC 2019) uses the same layout at run time; a wrong current or
period on the device during the rig check would be the symptom.

Only the `loadlibrary` fallback needs the layout by hand; the bridge compiles against the headers.

`TTLModulation`: 40 bytes, align 8

| Off | Field | Type | Default | Manual range |
|---|---|---|---|---|
| 0 | `current` | uint16 | 0 | mA, 0 – "depends on light source, usually 2000" |
| 4 | `startingDelayMs` | uint32 | 0 | |
| 8 | `delayBetweenSeqMs` | uint32 | 0 | |
| 16 | `periodMs` | double | 100 | |
| 24 | `timeOnMs` | double | 50 | |
| 32 | `risingTimeMs` | uint16 | 0 | |
| 34 | `fallingTimeMs` | uint16 | 0 | |
| 36 | `nbOfSeq` | uint16 | 1 | 0 = infinite in the vendor Square example |
| 38 | `nbOfPulsesPerSeq` | uint16 | 0 | 0 = infinite in the vendor Square example |

`ComplexModulation`: 40 bytes, align 8

| Off | Field | Type | Default |
|---|---|---|---|
| 0 | `mode` | int32 (enum, see §4) | CW |
| 4 | `current` | uint16 | 0 |
| 8 | `delayBetweenSeqMs` | uint32 | 0 |
| 16 | `periodMs` | double | 100 |
| 24 | `timeOnMs` | double | 50 |
| 32 | `nbOfSeq` | uint16 | 1 |
| 34 | `nbOfPulsesPerSeq` | uint16 | 0 |
| 36 | `startingDelayMs` | uint32 | 0 |

`Settings`: 2088 bytes, align 8

| Off | Field | Type | Default |
|---|---|---|---|
| 0 | `channelIdx` | int32 | Channel_1 |
| 4 | `mode` | int32 | Off |
| 8 | `isTTLOutput` | bool | false (true = TTL output, false = "ADC" output) |
| 12 | `triggerType` | int32 | Manual |
| 16 | `triggerMode` | int32 | Uninterrupted |
| 20 | `isRepeatableSequence` | bool | false |
| 24 | `currentMode` | int32 | Normal |
| 28 | `customDataPoint` | uint16[1000] | 0 (mA values for Custom mode) |
| 2032 | `ttlModulation` | TTLModulation | defaults above |
| 2072 | `nbComplexModulations` | uint8 | 0 (max 32) |
| 2080 | `complexModulations` | ComplexModulation* | must point at ≥ `nbComplexModulations` elements; allocate 32 |

## 6. How each vendor example sets up a mode (Python, per channel)

| Example | mode | Other fields |
|---|---|---|
| CW | CW | `current=100` |
| Square | Square | `isTTLOutput=true, current=50, periodMs=1000, timeOnMs=500, nbOfSeq=0, nbOfPulsesPerSeq=0` (free-running) |
| ExtTTL | ExtTTL | `current=100` (current applied while the TTL input is high) |
| ExtAnalog | ExtAnalog | `current=1000` (scale for the analog input) |
| Triggered | Square | `triggerType=Triggered, triggerMode=Pause, nbOfSeq=5, nbOfPulsesPerSeq=5, delayBetweenSeqMs=2000, periodMs=100, timeOnMs=50` |
| Gated | Square | `triggerType=Gated, triggerMode=Restart, current=250, periodMs=100, timeOnMs=50, nbOfSeq=0, nbOfPulsesPerSeq=0` |
| Complex | Complex | list of `ComplexModulation` segments (Square, then Delay, then Triangle) |
| Custom | Custom | `customDataPoint[0..999]` in mA, `periodMs=2500, startingDelayMs=2000, delayBetweenSeqMs=500, nbOfSeq=6` |

The `Settings` initialiser in the header allocates one `ComplexModulation` per instance
(`new ComplexModulation()`); the bridge deletes it and points the field at its own 32-element
array, which it keeps alive per channel in case the library reads the struct after the call
returns.

Standard sequence: `init(true)`, `wait(5000..10000)`, `available_devices_with_ports()`,
`open_device(p)`, `wait(5000)`, `ls_send_settings(p,&s)`, `wait(1000)`, `ls_start_channel` or
`ls_start_all`, …, `ls_stop_all(p)`, `close_device(p)`, `wait(1000)`, `quit()`.

## 7. Host PC findings (2026-09-17)

- Windows lists the driver as **"LightSource Driver"**, `USB\VID_04D8&PID_F57E\4.0.2`, class
  `USBDevice`. **It is not a COM port.** COM1/3/4/5/8/9 belong to other devices. The DLL's
  `portNumber` is Doric's own index, obtainable only from `available_devices_with_ports()` output.
  **Verify** the number and whether it is stable across replugging and reboots.
- `DoricSystem.dll` imports `Qt6Core/Gui/Network/SerialPort/Multimedia`, `opencv_world454`,
  `atcore`, `atutility`, `zaber-motion`, `SVGenSDK64`, `ic4core`, `quazip` and the MSVC 14 runtime
  (VC++ redistributable 14.50 is installed system-wide).
- MATLAB R2025b ships Qt 5 renamed as `Qt5*MW.dll`, so Qt6 does not collide by name. Generic
  DLLs (hdf5, zlib, png, tiff, ffmpeg) could still collide inside the MATLAB process.
- MATLAB R2025b (primary) and R2024b are installed. **MinGW-w64** is installed as a MATLAB support
  package (`C:\ProgramData\MATLAB\SupportPackages\R2025b\3P.instrset\mingw_w64.instrset`) and
  configured for `mex` C and C++. No Visual Studio. No real Python (only the Store alias).

## 8. Confirmed without hardware (M0 build steps, 2026-09-17)

| Question | Answer |
|---|---|
| Does the bridge build against the vendor headers with MinGW-w64? | Yes. g++ 8.1 (MATLAB support package), C++17, `-municode -static`, `<cstdint>` included before the vendor headers, no warnings. `native/doric_bridge/build_bridge.m` |
| Struct sizes and offsets | As in §5; identical to the table derived by hand |
| Error-string inventory | `strings` on `DoricSystem.dll` gives the full family: `Unable to <verb>... Device not found`, `Could not <verb>. System not initialized yet`, `System already initialized`, `No available device(s)`, `Unable to <verb>... Wrong controller for LightSource driver`, `Unable to <verb>... Device is not a LightSource driver`, `Couldn't get device, port number not used by a Doric device`. The classifier patterns in `bridge-protocol.md` cover all of them |
| Device-listing format | The DLL's format string is `%1 (Port #%2)`, so `doric.LightSource.parseDevices` matches `<name> (Port #<n>)` |
| Protocol, settings encoding, fault handling | Exercised end to end against the real executable in `--simulate` mode (13 tests) |

Still open, all needing the device (`rig-checks.md`):

1. **Where the debug text goes.** The bridge covers both possibilities: it redirects its own
   stdout/stderr (Win32 handles and C-runtime descriptors) into a capture pipe *and* listens for
   `OutputDebugString`; `QT_FORCE_STDERR_LOGGING=1` is set before the DLL loads. `HELLO` reports
   whether the `OutputDebugString` listener is active (`ods=1`), and each captured line says
   `src=stdio` or `src=ods`, so one run answers the question.
2. **The LEDFLS port number** and whether it survives replugging and reboots.
3. **Whether a command needs a trailing `wait()`** and the real command latency (with `settle` 0
   vs 100 ms). The bridge pumps `wait()` continuously, so a missing trailing wait should not
   matter; the rig check has to confirm it.
4. **The `ComplexModulation.mode` enumeration** (the C++ header says `LightSource::Mode`, the
   vendor Python code and example say `LightSourceComplexMode`; the package uses the Python
   values). A Complex sequence with a `Delay` segment (10) settles it.
5. **`MicroscopeFollower` (10)**: accepted by the bridge, absent from `doric.Mode` until a run
   shows the device honours it.
6. **The device's real maximum current** (the manual says "usually 2000 mA"), which is what the
   default `MaxCurrentmA` is based on.
7. **Whether `ls_send_settings` stops a running channel** (the package leaves `IsRunning`
   unchanged when settings are applied).
8. **`loadlibrary` smoke test** for `doric.transport.LibraryTransport`, in a throwaway MATLAB
   process (it loads Qt6, OpenCV, HDF5 and FFmpeg into MATLAB).
