# Vendor DLL notes (`DoricSystemDLL`)

Discovery notes from inspecting `DoricSystemDLL/` (read-only vendor folder) and the host PC, plus
what the bridge confirmed by compiling against the vendor headers (§8) and what the rig runs of
2026-09-17 confirmed against the real device (§9, log in `rig-checks.md`). Anything still marked
**verify** needs another operator-approved run (see `rig-checks.md`) and this file updated with
the result.

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
  way to detect failure (this is decision D1 in `architecture.md`). **Confirmed 2026-09-17**: the
  text goes to the process's **stdout/stderr**, never to `OutputDebugString` — every captured line
  in every rig run was tagged `src=stdio`, although the bridge's `OutputDebugString` listener was
  active (`ods=1`). `init(true)` makes the library echo each `ls_send_settings` field by field
  (`[Doric LightSource] : mode = 4`, …), which is how the wire encoding was verified end to end.
- Commands are queued to the library's own thread and executed while `wait()` pumps.
  **Confirmed 2026-09-17**: with the bridge pumping `wait()` continuously, no trailing `wait()` is
  needed — every command took effect and was acknowledged with `settle = 0`. Round trip measured
  through `LightSource`: `CURRENT`, `START`, `STOP` **5–9 ms**, `SETTINGS` ~12 ms at `SettleMs` 0;
  ~110–130 ms at `SettleMs` 100 (the settle window dominates). `INIT` ~10–13 s, `OPEN` ~5.1 s,
  `LIST` ~0.6–2.2 s, all dominated by their `waitms`.

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

Differences in the vendor Python definitions (`lightsource_defs.py`):

- `LightSourceMode` also has `MicroscopeFollower = 10`. Still **unverified**: it needs a Doric
  microscope to follow, which this rig does not have, so `doric.Mode` leaves it out.
- `ComplexModulation.mode` uses a *different* enum, `LightSourceComplexMode`:
  `Off=0, CW=1, Square=2, Input=3, Triangle=4, RampUp=5, RampDown=6, Sine=7, Stairs=8, Custom=9,
  Delay=10, LockIn=11`. The C++ header types the field as `LightSource::Mode`. **Settled
  2026-09-17**: the Python enum is the right one. A Complex sequence of CW(1) + Delay(10) +
  Triangle(4) was accepted and started with no error text, and the library echoed the segment
  modes back unchanged — including `mode = 10`, which is outside the 0–6 range of
  `LightSource::Mode`. (The emitted waveform itself still wants a photodiode; see
  `rig-checks.md`.)
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
| 0 | `current` | uint16 | 0 | mA, 0 – "depends on light source, usually 2000" (this light source's LEDs are rated 1000 mA; see §10) |
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
  **Confirmed 2026-09-17**: this rig's LEDFLS answers on **port 4**, listed as
  `"[Doric System] : LED Driver (Port #4)"` — the library quotes the line and prefixes its own
  tag, and the device name it reports is `LED Driver`, not `LEDFLS_465_465`
  (`doric.LightSource.parseDevices` strips the quoting and the tag). The number was identical
  across nine separate `init`/`list` runs in one session; stability across replugging and a
  reboot is still **unverified** (`rig-checks.md`).
- `DoricSystem.dll` imports `Qt6Core/Gui/Network/SerialPort/Multimedia`, `opencv_world454`,
  `atcore`, `atutility`, `zaber-motion`, `SVGenSDK64`, `ic4core`, `quazip` and the MSVC 14 runtime
  (VC++ redistributable 14.50 is installed system-wide).
- MATLAB R2025b ships Qt 5 renamed as `Qt5*MW.dll`, so Qt6 does not collide by name. Generic
  DLLs (hdf5, zlib, png, tiff, ffmpeg) could still collide inside the MATLAB process.
- MATLAB R2025b is the only usable install. **MinGW-w64** is installed as a MATLAB support
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

Every one of those questions was answered by the rig runs of 2026-09-17; see §9.

## 9. Confirmed with the device (rig runs, 2026-09-17)

Full log in `rig-checks.md`. The device was a `LEDFLS_465_465` on this host, no animal connected,
fibers terminated; currents stayed between 20 and 100 mA.

| Question (§8 list) | Answer |
|---|---|
| Library version | `DoricSystem.dll [1.3.0]`, loaded from `DoricSystemDLL/API/lib/x64/release/Qt` |
| 1. Where the debug text goes | **stdout/stderr only** (`src=stdio` on every line, in every run), never `OutputDebugString`, although the listener was active (`ods=1`). The bridge's capture is therefore the whole error channel |
| 2. LEDFLS port number | **4**, name `LED Driver`, line format `"[Doric System] : LED Driver (Port #4)"`. Identical across nine `init`/`list` runs; replug and reboot still pending |
| 3. Trailing `wait()` and latency | No trailing `wait()` needed while the bridge pumps. `CURRENT`/`START`/`STOP` 5–9 ms, `SETTINGS` ~12 ms at `SettleMs` 0; ~110–130 ms at `SettleMs` 100. `INIT` 10–13 s, `OPEN` 5.1 s |
| 4. `ComplexModulation.mode` enum | `LightSourceComplexMode` (the vendor Python values). CW(1) + Delay(10) + Triangle(4) accepted, started, and echoed back unchanged |
| 5. `MicroscopeFollower` (10) | **Still unverified** — needs a Doric microscope, which this rig does not have. `doric.Mode` still omits it |
| 6. Real maximum current | **Answered from the vendor's own manual** (see §10), not by driving current: a 465 nm head is rated **1000 mA**, with **700 mA** recommended. The package now enforces 1000 mA as a hard ceiling and defaults `MaxCurrentmA` to 700 |
| 7. Does `ls_send_settings` stop a running channel? | Sending new settings to a running channel returns no error and the library prints nothing about stopping. Whether the *emitted light* pauses needs a photodiode; the package still leaves `IsRunning` unchanged and an explicit `START` afterwards also succeeded |
| 8. `loadlibrary` smoke test | Works for the flat commands — `init`, `open_device`, `ls_send_settings`, `ls_send_current`, `ls_start_channel`, `ls_stop_all`, `close_device`, `quit` all succeeded from inside MATLAB, and light was driven that way. **But the MATLAB process always dies with an access violation (0xc0000005)**: at `unloadlibrary` if it is called, otherwise at MATLAB exit. Complex settings are refused by design. `LibraryTransport.UnloadOnClose` is off by default so user code can finish first, and such a process must be treated as throwaway. This is the strongest argument for D1 |

Other things the runs showed:

- `init` transiently opens and closes the device itself (`Device connected -> LED Driver`,
  `Device closed -> LED Driver`) before any `open_device`.
- With `init(true)`, `ls_send_settings` echoes every field of `Settings`, the `TTLModulation`
  block and each `ComplexModulation` — a free confirmation of the wire encoding.
- `SIZES` against the real MSVC-built DLL matches §5 exactly (settings 2088, ttl 40, complex 40).
- Qt prints `WARNING: QApplication was not created in the main() thread.` on every `init`; it is
  harmless and classified `warning`, not an error.
- A hard kill of MATLAB with a channel running makes the bridge exit on stdin EOF, as designed.

## 10. Current ratings of the light source (vendor manuals)

Sources: Doric **LED Light Source user manual V2.1.1**
(`https://www.doriclenses.com/downloads/UserManual/UserManual_LED_Light_Source_V2.1.1.pdf`),
whose specification chapter covers the LEDFLS, and the product pages on
`neuro.doriclenses.com`. Nothing here was established by driving current into the device.

| Figure | Value | Source |
|---|---|---|
| **Maximum current, 465 nm LED** | **1000 mA** | Table 5.8, *Typical Connectorized LED, LEDFRJ1 and LEDFLS Output Power vs Optical Fiber Core Diameter*: the row `465 / ~25 nm FWHM / 1000 mA`. The neighbouring 450 nm row is also 1000 mA |
| **Recommended operating current** | **700 mA** | Table 5.2, *General Specifications for Connectorized LEDs*: "700 mA recommended for 1000 mA max current LEDs" |
| Driver output range, normal mode | 40–2000 mA | Specification table: "Output Current … 40 - 2000 mA Normal Mode" |
| Driver output range, low-power mode | 4–200 mA | Same table, "4 - 200 mA Low Current Mode"; the manual's operation guide says low power mode's maximal current is 200 mA, minimum 2.5 mA |
| Overdrive | 2000 mA **pulsed only** | Table 5.8's "Overdrive @2000 mA (pulsed)" column, giving ×1.7 the power at 465 nm. The manual's operation guide is explicit, in capitals: overdrive "allows the system to exceed the normal safe current limit of the light source. **THIS SHOULD ONLY BE USED WITH PULSED SIGNALS, AS IT CAN OTHERWISE DAMAGE THE LIGHT SOURCE.**" |
| Analog input scaling | 400 mA/V (40 mA/V in low power) | Specification table. A 5 V input therefore asks for 2000 mA, above what a 465 nm LED can take, so the manual tells users to scale the input voltage down to the LED's maximum |

Consequences for the package, all in `doric.Channel`:

- `DeviceMaxCurrentmA = 1000` is a constant hard ceiling. `MaxCurrentmA` cannot be raised above
  it (`doric:Channel:aboveDeviceLimit`), and every current that gets sent is checked against
  `MaxCurrentmA`, so no mode — CW, Square, Complex segments, Custom points or `setCurrent` —
  can exceed the LED's rating.
- `RecommendedMaxCurrentmA = 700` is the default limit, so the safe value is what you get
  without doing anything.
- Operating outside the manual's stated conditions also voids the 12-month warranty (§6.2).
- The front-panel control knob sets the driver's own maximum current to the LED, independently of
  anything sent over USB. Software cannot see or constrain it.
- The pulsed 2000 mA overdrive is **not** reachable through this package. Using it safely needs
  the vendor's duty-cycle limits (the firmware has `driver.current.overdrive.duration` and
  `driver.current.overdrive.max` parameters that the DLL's light-source API does not expose),
  and a 465 nm LED held there continuously is destroyed. Selecting `CurrentMode.Overdrive` is
  still allowed; the 1000 mA ceiling applies regardless.
- **In external-analog mode the ceiling cannot be enforced**: the manual says "in External Analog
  mode, the current is set at the maximum current and can't be changed" — it follows the BNC
  voltage at 400 mA/V, so 2.5 V already means 1000 mA and 5 V means 2000 mA. Keep the analog
  source at or below 2.5 V (0.5 V in low-power mode). No software in MATLAB can prevent this.
