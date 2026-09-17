# Rig checks

Every run against the real LED driver is recorded here: date, who approved it, what was run, what
was seen. Runs need the operator's explicit permission **for that run** (see `CLAUDE.md`).

Nothing in the package has touched the device yet. Building the bridge, running it with
`--simulate` and the whole test suite need no permission and are not recorded here.

## Pending

### 1. M0 spike: needs operator approval, no animal connected, fibers safely terminated

Preconditions: Doric Neuroscience Studio closed, no other MATLAB session holding the device.
Every step below ends with `led.disconnect()` (stop all → close → quit).

1. Bridge loads `DoricSystem.dll` from `DoricSystemDLL/API/lib/x64/release/Qt`:
   ```matlab
   t = doric.transport.BridgeTransport();   % real DLL, no device call yet
   t.open();                                 % HELLO: bridge version, dll path, pid, ods flag
   ```
   Record `t.DllPath`, `t.BridgeVersion` and whether `HELLO` reports `ods=1`. A missing dependency
   shows up as `doric:BridgeTransport:vendorDllNotFound` (exit code 3).
2. `INIT` + `LIST`: capture the exact text and **which stream it arrives on** (`src=stdio` vs
   `src=ods` in the log) — this answers the open question in `vendor-dll.md` §8.1.
   ```matlab
   devices = doric.listDevices()             % init -> list -> quit, opens nothing
   ```
   Record the LEDFLS port number. Repeat after unplug/replug and after a reboot to see whether it
   is stable.
3. `SIZES` against the loaded DLL, compared with `vendor-dll.md` §5 (the values are already pinned
   by a test; this run confirms the MSVC build agrees at run time).
4. `OPEN` on the real port, and on an invalid port, capturing the error text:
   `led = doric.LightSource('Port', p); led.connect()`.
5. Channel 1 `CW` at a low current (operator chooses, e.g. 20 mA): operator confirms light, then
   `stop`. Repeat on channel 2.
6. `setCurrent` while running: operator confirms the brightness change.
7. Latency: `led.stats()` with `SettleMs` 0 and 100; time to a visible or photodiode-measured
   change. Whether commands take effect without a trailing `wait()`.
8. Kill the MATLAB-side pipe (`delete(led)`, then also `taskkill` on MATLAB itself): the light must
   go off, because the bridge stops every opened port on stdin EOF.
9. Complex mode with a `Delay` segment (value 10, the vendor Python enumeration) to resolve the
   enum question in `vendor-dll.md` §4/§8.4:
   `led.Channels(1).apply(doric.ChannelSettings.complex())`.
10. Whether `ls_send_settings` stops a running channel (`vendor-dll.md` §8.7).
11. The device's real maximum current, to confirm the default `MaxCurrentmA` of 2000
    (`vendor-dll.md` §8.6).
12. Optional: `MicroscopeFollower` (mode 10) — the bridge accepts it, `doric.Mode` does not list it
    yet.

### 2. M4 GUI walk-through (operator, at the rig)

`doric.app()` on the real device: scan, connect, mode and intensity per channel, Apply/Start/Stop
on one and both channels, live intensity while running, STOP ALL and Esc, advanced settings
(timing, trigger, complex table, custom waveform import), limits refusal, save/load config, then
closing the window and confirming the light is off and the device released.

### 3. M6 rig verification

Every mode on both channels (Off, CW, ExtTTL, ExtAnalog, Square, Complex, Custom; Triggered and
Gated with the rig's TTL source), the limit refusals, stop-on-window-close, stop-on-MATLAB-kill,
and a latency table (`led.stats()` per command, with `SettleMs` 0 and 100).

### 4. `loadlibrary` fallback (`doric.transport.LibraryTransport`)

Never run. Do it in a **throwaway MATLAB process** (it pulls Qt6, OpenCV, HDF5 and FFmpeg into
MATLAB and can take the process down): `loadlibrary` with
`+doric/+transport/private/doric_flat.h`, then `init`/`LIST`/`open_device`/`ls_send_current` on a
low current. Note crashes, DLL conflicts and whether any library text reaches the Command Window.
Complex-mode settings are refused by design (`doric:LibraryTransport:unsupported`).

## Log

_No hardware runs yet._
