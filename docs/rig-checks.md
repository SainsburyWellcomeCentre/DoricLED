# Rig checks

Every run against the real LED driver is recorded here: date, who approved it, what was run, what
was seen. Runs need the operator's explicit permission **for that run** (see `CLAUDE.md`).

Building the bridge, running it with `--simulate` and the whole test suite need no permission and
are not recorded here.

## Pending

Everything below needs someone at the rig: an eye on the fiber tip, a power meter, or a hand on
the USB cable. The software side of M0, M4 and M6 is done (see *Log*).

### 1. Physical confirmation of what the software already commands

The runs of 2026-09-17 drove light on both channels and every command was acknowledged, but no
one watched the fiber. Worth confirming once, with a power meter or photodiode on the fiber:

1. Light appears on channel 1 and channel 2 in `CW`, and the two are independent.
2. `setCurrent` while running changes brightness (20 → 50 → 100 mA was commanded and accepted).
3. `Square` really pulses at the commanded period, and the emitted waveform matches `Complex`
   (CW → 1 s `Delay` → `Triangle`) and `Custom` (1000-point sine).
4. **Whether new settings stop a running channel** (`vendor-dll.md` §9.7): with channel 1 running
   `CW`, send `Square` settings and watch whether the light pauses before the pulses start.
5. Light goes **off** when MATLAB is killed with a channel running. The bridge exits on stdin EOF
   as designed (verified 2026-09-17: bridge pid gone, no MATLAB-side stop ran), but no one saw the
   fiber go dark.
6. `ExtTTL`, `ExtAnalog`, `Triggered` and `Gated` with the rig's real TTL/analog source. The
   settings are accepted on both channels; the response to an actual input is untested.
   **Before driving the analog input**: it scales at 400 mA/V, so 2.5 V is already the LED's
   1000 mA rating and 5 V would be 2000 mA. Keep the source at or below 2.5 V (0.5 V in low-power
   mode). `MaxCurrentmA` does not apply in that mode — the voltage does.

### 2. Port stability

Port 4 was identical across nine `init`/`list` runs in one session. Still to check: the number
after unplugging and replugging the USB cable, and after a host reboot.

### 2b. Auto port with the rotary joint attached (added 2026-09-21)

With the Assisted Rotary Joint plugged in, the operator saw the listing
`Assisted Rotary Joint (ARJ_24_Gen2) on port 3, LED Driver on port 4` and Auto refused to pick.
Auto now opens the one listed name matching `DeviceNamePattern` (default `'LED'`); tested on
`SimulatedTransport` with those exact names. Still to confirm at the rig: `doric.app()` →
*Connect* with Port on *Auto* and the rotary joint attached reaches *Ready - LED Driver on port 4*,
and the rotary joint is untouched.

### 3. The device's real maximum current — **resolved from the vendor manual (2026-09-17)**

A 465 nm head is rated **1000 mA**, with **700 mA** recommended (Doric *LED Light Source* user
manual V2.1.1, tables 5.8 and 5.2; `vendor-dll.md` §10). The package now treats 1000 mA as a hard
ceiling and defaults `MaxCurrentmA` to 700. Nothing above 100 mA has been driven at this rig and
nothing needs to be: the figure came from the manual, not from a measurement.

What is left here is optional and needs a power meter: checking the emitted power against the
manual's table (8.5 mW into a 200 µm 0.57 NA fiber at 1000 mA) if the LED's output is ever in
doubt. Do not drive the LED at 1000 mA to "test the limit"; the rating is the vendor's.

### 4. `MicroscopeFollower` (mode 10)

Needs a Doric microscope for the channel to follow; this rig has none. `doric.Mode` omits it on
purpose. Nothing to do until such a setup exists.

### 5. GUI details that need a human

The main window was driven programmatically against the real device (see *Log*). Still worth a
human pass: the **Esc** key binding, the *Advanced settings…* pop-up (timing, trigger, complex
table, custom waveform import) clicked by hand, and save/load config through the file dialogs.

## Log

### 2026-09-17 — M0 spike, M4 GUI, M6 verification, `loadlibrary` fallback

Approved by the operator for this run, who confirmed **no animal connected and the fiber
terminated safely**. Doric Neuroscience Studio was not running. Currents stayed between 20 and
100 mA. Every run ended with the light off, the device closed and the library quit; the session
ended with no `doric_bridge.exe` process and both channels commanded `Off`.

Device: `DoricSystem.dll [1.3.0]` from `API/lib/x64/release/Qt`, LEDFLS on **port 4**, reported by
the library as `LED Driver`. Bridge 1.0.0, MinGW g++ 8.1, `ods=1`.

| Step | Result |
|---|---|
| Bridge loads the real DLL (`HELLO`) | Pass. Reported bridge 1.0.0, the expected DLL path, its pid, `ods=1` |
| `SIZES` against the real DLL | Pass. Matches `vendor-dll.md` §5 exactly (settings 2088, ttl 40, complex 40) |
| `INIT` + `LIST`, where the text arrives | Pass. All library text on **`src=stdio`**, nothing on `OutputDebugString`. `init` itself opens and closes the device once before any `open_device`. `INIT` 10–13 s, `LIST` 0.6–2.2 s |
| Port number | **4**, stable across nine `init`/`list` runs in the session |
| `OPEN` on the real port | Pass. `connect()` → `Ready` in ~16 s (`INIT` 10.1 s + `LIST` 0.6 s + `OPEN` 5.1 s + initial `STOPALL` 0.12 s) |
| `OPEN` on an invalid port | `connect()` refuses before touching the library: `doric:LightSource:deviceNotFound`, "Port 99 is not listed. Listed: LED Driver on port 4." |
| Channel 1 and 2 `CW` at 20 mA, start/stop | Pass, both channels, all commands acknowledged. **Light not observed** (pending 1.1) |
| `setCurrent` while running (20 → 50 → 100 → 20 mA) | Pass; the library logs `Sending new current N to channel 1`. Brightness change not observed (pending 1.2) |
| Latency, `SettleMs` 0 vs 100 | `CURRENT`/`START`/`STOP` **5–9 ms**, `SETTINGS` ~12 ms at 0; ~110–130 ms at 100. No trailing `wait()` needed |
| Burst of 10 non-blocking commands | Pass. Queued in 6.4 ms, no pipe deadlock, all acknowledged |
| Kill the MATLAB-side pipe with a channel running | Pass. MATLAB hard-killed (`taskkill /F`) with channel 1 at 50 mA; the bridge process exited by itself and no MATLAB-side stop ran, so only the stdin-EOF path can have stopped the channel. Fiber not observed (pending 1.5) |
| `Complex` with a `Delay` segment | Pass. CW(1) + Delay(10) + Triangle(4) accepted, started, echoed back unchanged — the `LightSourceComplexMode` values are correct (`vendor-dll.md` §9.4) |
| Does `ls_send_settings` stop a running channel? | No error, and the library says nothing about stopping; an explicit `START` afterwards also succeeded. Optically unresolved (pending 1.4) |
| The device's real maximum current | Not attempted by driving current; taken from the vendor manual instead (`vendor-dll.md` §10). Limit refusals verified at 2500 mA (`setCurrent`) and 3000 mA (`apply`), both `doric:Channel:overCurrent`, nothing sent |
| `MicroscopeFollower` (mode 10) | Not attempted; see pending 4 |
| **M6 mode matrix**, both channels | Pass, 18/18 with no failures: `Off`, `CW`, `ExtTTL`, `ExtAnalog`, `Square`, `Complex`, `Custom` (1000 points), `Triggered`, `Gated` — each applied, started, stopped on channel 1 and channel 2 |
| `startAll` / `stopAll` | Pass |
| `saveConfig` / `loadConfig` round trip | Pass; settings reloaded identical |
| `delete(led)` with a channel running | Pass; `stopAll` + `close` + `quit` inside `delete`, 1.7 s |
| **M4 GUI** on the real device (driven programmatically, window hidden) | Pass. Defaults `ExtTTL`/0 mA/both channels selected and nothing sent before Apply; Connect → `Ready` with device `LED Driver`; Apply then Start on both channels; live 30 → 80 mA while running; STOP ALL; deselect channel 2 and start channel 1 alone; over-limit Apply refused in the status line with nothing sent; closing the window with a channel running deleted the `LightSource` (stop all, close, quit) |
| **`loadlibrary` fallback** (`LibraryTransport`), throwaway MATLAB | Partly. `init`, `LIST`, `open_device`, `ls_send_settings`, `ls_send_current`, `ls_start_channel`, `ls_stop_all`, `close_device`, `quit` all succeeded and drove light; `LIST` reports 0 devices as documented; Complex settings refused by design. **The MATLAB process always dies with an access violation (0xc0000005)** — at `unloadlibrary` if called, otherwise at MATLAB exit |

Later the same day, with the device connected but **no channel ever started** (so no light), the
new current ceiling was checked end to end: defaults 700 mA per channel with the constant rating
at 1000 mA; `MaxCurrentmA = 2000` refused with `doric:Channel:aboveDeviceLimit`; `setCurrent(900)`
refused at the 700 mA default; raising the limit to 1000 mA accepted; `cw(1000)` applied (settings
only); `cw(1001)` refused. Both channels were set back to `Off` and the device released.

Two package bugs were found and fixed in the same session:

- `doric.LightSource.parseDevices` kept the library's own quoting and `[Doric System] : ` tag in
  the device name (`""[Doric System] : LED Driver"` instead of `LED Driver`), which also showed up
  in the GUI device list and in the invalid-port error message. Fixed; covered by
  `ProtocolCodecTest/parseDevicesStripsTheLibrarysOwnQuotingAndTag`.
- `doric.transport.LibraryTransport.close` called `unloadlibrary`, which faults inside the vendor
  DLL and takes MATLAB down. The unload is now opt-in (`UnloadOnClose`, default false) so user
  code can finish and save its data first; covered by
  `LibraryTransportTest/closeLeavesTheLibraryLoadedUnlessAsked`.
