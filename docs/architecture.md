# Architecture

Design of the `doric` MATLAB package: a general-purpose driver, GUI and integration layer for
the Doric 2-channel LED fiber light source `LEDFLS_465_465` (2 × 465 nm). Status:
**implemented (M1–M6) and verified on the real device on 2026-09-17**; what is left needs an eye
or a power meter at the fiber (see §8 for milestones and `rig-checks.md`).

## 1. Goals and non-goals

**Goals**

1. **Standalone use.** A script, the command window or the GUI can control the device with no
   other toolbox or framework.
2. **Portable into any MATLAB package** that runs closed-loop hardware control, Bpod protocols
   included. The core has no globals, no framework dependency, no printing on hot paths and no
   hidden session state, and it can be swapped for a simulated device in tests and emulators.
3. **Full user control.** Every mode and every field the vendor API exposes is reachable from
   the API **and** the GUI. The package never picks a mode for the user and never silently
   changes a value.
4. **Safe by construction.** Light goes off on disconnect, object deletion, GUI close, errors
   and host crash. Limits exist but are user-set.
5. **Honest state.** The hardware cannot be queried (see `vendor-dll.md` §2), so the package
   reports what it *commanded* and what the library *complained about*, labelled as such.

**Non-goals**

- Any specific Bpod pipeline or protocol. Integration is documented as generic patterns
  (`bpod-integration.md`); no protocol-specific code lives here.
- OTPG and rotary-joint support (exported by the same DLL; the layering leaves room for them).
- Sub-millisecond timing from MATLAB. Precise timing belongs to the driver's own sequencing
  (Square/Complex/Custom) or to external TTL/analog inputs driven by the state machine.

## 2. Decisions

### D1. The DLL runs in a helper process (`doric_bridge.exe`), not inside MATLAB

A small C++ console program, built once with MinGW-w64 against the vendor headers, loads
`DoricSystem.dll` and serves a line protocol over stdin/stdout (`bridge-protocol.md`).

Why:
- **The API's only error channel is printed debug text.** Inside MATLAB that text is lost; a
  child process's streams can be read line by line.
- **Isolation.** The DLL drags in Qt6, OpenCV, HDF5 and FFmpeg. A crash or DLL clash kills the
  bridge, not MATLAB (with an animal session running).
- **Fail-safe.** When the bridge's stdin closes (MATLAB exited or crashed), it runs
  `ls_stop_all` on every open port, then `close_device` and `quit`.
- **Responsiveness.** `init` (5–10 s) and `open_device` (~5 s) run while MATLAB stays free.
  The GUI never freezes, and a host loop can keep running.
- **Event loop.** The library needs `wait()` to be pumped. The bridge pumps `wait(pumpMs)`
  continuously on its own thread, so no MATLAB code ever has to call `wait`.

Fallback: `doric.transport.LibraryTransport` (`loadlibrary` with a hand-written flat C header),
kept behind the same interface. The 2026-09-17 rig run settled its status: the flat commands do
work in-process and can drive light, but the MATLAB process always ends in an access violation
(0xc0000005) once the library has been initialised — at `unloadlibrary`, or otherwise at MATLAB
exit — and library text stays invisible. D1 stands; the fallback is for throwaway processes only
(`vendor-dll.md` §9.8).

MATLAB side (implemented): the bridge runs as a **Java `ProcessBuilder`** child with stdin and
stdout piped and stderr merged. `BufferedReader.ready()` tells MATLAB whether a whole line is
waiting, so `poll()` drains what has arrived and never blocks — .NET's `StreamReader.Peek` blocks
on pipes, which is why Java won. Two consequences learned while building it:

- **Drain on send.** A burst of non-blocking requests without polling would fill the bridge's
  stdout pipe, blocking the bridge in its write and then MATLAB in its own write: a deadlock.
  `BridgeTransport.sendImpl` therefore drains the incoming pipe before every write.
- **Emergency stop overtakes long waits.** `STOPALL` is a priority request in the bridge, served
  between `wait()` slices, so it never queues behind `INIT` (5–10 s) or `OPEN` (~5 s).
- **The bridge's own writes must never block.** A `WriteFile` to a full pipe blocks forever, and a
  bridge stuck in a write ignores stdin EOF — which is exactly the case where the light must go
  off (it happened once during development: a killed MATLAB left a bridge running). Output is
  therefore queued and written by a separate thread, dropping unsolicited events before replies
  when a host stops reading.

### D2. Layered package; transport is injectable

```
 GUI (doric.gui.*)        host code (scripts, Bpod protocols, closed-loop packages)
        \                      /
         doric.LightSource  ── owns ──  doric.Channel ×2
                │                           │ uses
                │                     doric.ChannelSettings (value object, validation)
                ▼
      doric.transport.Transport  (abstract)
        ├── BridgeTransport      real device via doric_bridge.exe   (default)
        ├── LibraryTransport     real device via loadlibrary         (fallback)
        └── SimulatedTransport   no hardware; records calls, can inject faults
```

`doric.LightSource(..., 'Transport', t)` accepts any transport, so host packages and tests
choose real or simulated hardware in one place, and nothing else in the host needs to know.

### D3. Settings are complete value objects

`doric.ChannelSettings` holds **every** vendor `Settings` field, including the full
`TTLModulation`, up to 32 `ComplexModulation` segments and the 1000-point custom waveform.
It is a value class with validation in property setters, so an invalid object cannot exist.
Factory methods (`cw`, `extTTL`, `extAnalog`, `square`, `triggered`, `gated`, `complex`,
`custom`) are shortcuts that set fields to the vendor examples' values, and the user may
override any of them. `toStruct`/`fromStruct` and JSON save/load make any configuration
reproducible and storable in a data file. Nothing is sent until the user calls `apply`.

### D4. Commanded state, not measured state

Each `Channel` stores the last settings **successfully sent**, the last current, the running
flag and timestamps. A command is "successful" when the bridge acknowledged it and no library
error text arrived within the settle window (default 100 ms, configurable, 0 = do not wait).
Property names and GUI labels say *commanded*.

### D5. Safety limits are user-owned and explicit

- **The LED's rating is a hard ceiling, not a preference.** `doric.Channel.DeviceMaxCurrentmA`
  is a constant 1000 mA: the rated maximum of a 465 nm head (Doric *LED Light Source* manual
  V2.1.1, table 5.8, which covers the LEDFLS). `MaxCurrentmA` cannot be raised above it
  (`doric:Channel:aboveDeviceLimit`), so no API or GUI path can command more, in any mode. The
  driver itself would deliver up to 2000 mA — its pulsed *Overdrive* column — and this package
  deliberately does not expose that: reaching it safely needs the vendor's duty-cycle guidance,
  and the vendor's own manual says overdrive is for pulsed signals only, "AS IT CAN OTHERWISE
  DAMAGE THE LIGHT SOURCE".
- **The one gap, stated rather than papered over:** in `ExtAnalog` the current follows the BNC
  voltage at 400 mA/V, so the hardware, not the package, decides it. 2.5 V is already 1000 mA.
  No MATLAB-side guard can change that; the rig's analog source has to be scaled.
- **Changing the light source.** The 1000 mA ceiling is hard-coded for the LEDFLS_465_465. A
  developer moving the package to another Doric LED head, a laser or another driver must revisit
  `DeviceMaxCurrentmA` against that device's rating. It may be changed, with caution; whoever
  changes it takes full responsibility for any damage to the light source, fibers or
  preparation. The note sits next to the constant in `+doric/Channel.m`.
- Per channel: `MaxCurrentmA` (default 700 mA, Doric's recommended operating current for a
  1000 mA LED, manual table 5.2; the user can change it at any time, from the API or the GUI,
  anywhere in 0–1000). A request above it **errors**; it is never clamped.
- On connect: `ls_stop_all` before anything else.
- On `disconnect`/`delete`/GUI close (when the GUI owns the device)/error teardown:
  `ls_stop_all`, then `close_device`, then `quit`. Idempotent.
- Bridge watchdog: stdin EOF means stop all, close, quit, exit.
- An `EmergencyStop` path (`stopAll`) is allowed in **every** state, including `Faulted`.

### D6. Built for closed-loop hosts

- **Non-blocking API.** `connect` has a blocking form (default) and an async form with
  completion callbacks. Every command can be issued with `'Wait', false`, returning at once
  with the outcome delivered via event.
- **Fast paths.** `setCurrent(ch, mA)` → `ls_send_current` and `start/stop(ch)` skip settings
  re-validation and, with `'Wait', false`, cost MATLAB about one pipe write.
- **Events** (`notify`) for observers: `StateChanged`, `CommandCompleted`,
  `LibraryMessage`, `Faulted`, with `doric.DoricEventData`. They fire only when something
  listens. The GUI is only an observer, and a host logger can be one too.
- **Who polls.** Replies are processed by `LightSource.poll`. A `timer` (`AutoPoll`, 20 ms,
  weak-referenced so it never keeps the object alive) calls it while connected, blocking commands
  call it in their wait loop, and a host can switch `AutoPoll` off and call `poll` from its own
  loop. MATLAB can run the timer callback *inside* another poll or between sending a request and
  recording it, which reordered messages during development, so a depth counter makes the timer
  skip its tick whenever a poll or a send is already in progress.
- **Measured latency.** Every command records host-side send→ack time; `stats()` summarises it.
- **No output on hot paths.** Logging goes to a bounded in-memory log (`log()`); printing is
  opt-in (`Verbose`).
- **Record for data files.** `record()` returns a plain struct (settings as sent, limits, device
  port, bridge/DLL versions, command log) for a host to save.

### D7. GUI is programmatic `uifigure`, not App Designer

`.mlapp` files are binary: they can't be diffed, reviewed or edited reliably by agents. The GUI is
a handle class building a `uifigure` in code (`gui.md`). It can **own** a device (opens it,
closes it on exit) or **attach** to one a host already opened (never closes it). Every control
maps 1:1 to API calls, so anything done in the GUI can be done in a script, and vice versa.

Two windows: a **simplified main window** with only what closed-loop work needs (channel
selection, mode, intensity, start/stop, STOP ALL). It opens with both channels selected, ExtTTL,
0 mA, and sends nothing until Apply/Start. An **Advanced settings** pop-up holds every other
field. Both edit the same pending settings.

## 3. Class overview

Full signatures: `api-reference.md`.

| Class | Kind | Responsibility |
|---|---|---|
| `doric.LightSource` | handle | Connection lifecycle, state machine, owns 2 `Channel`s, `stopAll`/`startAll`, events, log, `record` |
| `doric.Channel` | handle | One output: `apply(settings)`, `start`, `stop`, `setCurrent`, `MaxCurrentmA`, commanded state |
| `doric.ChannelSettings` | value | Every vendor field, validation, factories, struct/JSON conversion |
| `doric.ComplexSegment` | value | One `ComplexModulation` element |
| `doric.Mode`, `doric.CurrentMode`, `doric.TriggerType`, `doric.TriggerMode`, `doric.ComplexMode` | enumeration | Vendor values (`vendor-dll.md` §4) |
| `doric.DoricEventData` | event data | Payload of every event (`event.EventData` subclass) |
| `doric.listDevices` | function | Scan → table(`Port`, `Name`) parsed from the library's output |
| `doric.transport.Transport` | abstract handle | Primitive operations + message stream |
| `doric.transport.BridgeTransport` | handle | Process management, request/ack correlation, timeouts |
| `doric.transport.LibraryTransport` | handle | `loadlibrary` fallback |
| `doric.transport.SimulatedTransport` | handle | No hardware; call log, scripted faults, scripted device list, simulated device state |
| `doric.transport.ProtocolCodec` | static | Encode requests, decode bridge lines (`bridge-protocol.md`) |
| `doric.transport.MessageClassifier` | static | Severity of library text; mirrors the bridge's table |
| `doric.gui.LightSourceApp` | handle | The interactive window |
| `doric.config` | function | Resolves paths (vendor Qt folder, bridge exe); overridable by preference/argument |

## 4. Connection state machine

```
             connect()                 init done            open done
Disconnected ─────────► Initialising ─────────► Opening ─────────► Ready
     ▲                        │                    │                 │
     │   disconnect() / delete│/ error             │                 │ disconnect()
     │                        ▼                    ▼                 ▼
     └────────────────────── Closing ◄──────────────────────────── (any)
                                ▲
 any state ── bridge exited / timeout / "Device not found" ──► Faulted ── disconnect()/reconnect()
```

- Commands other than `stopAll` require `Ready`; otherwise `doric:LightSource:notReady`.
- `Faulted` keeps the reason (`FaultReason`); the library text that led to it is in `log()`.
- Channel sub-state (commanded, `Channel.CommandedState`): `Unconfigured → Configured →
  Running ⇄ Stopped`.
- A failed `connect` rolls back (stop, close, quit, transport close) and ends in `Faulted`;
  `connect` from `Faulted` disconnects first, so a retry is one call. Failures *before* the
  transport starts (missing executable, missing DLL) throw and leave the state `Disconnected`.

## 5. Error handling

- Error identifiers: `doric:<Component>:<reason>`. Planned reasons: `notReady`,
  `invalidSettings`, `overCurrent`, `bridgeNotFound`, `bridgeExited`, `vendorDllNotFound`,
  `timeout`, `deviceNotFound`, `libraryError`, `portInUse`.
- Library text is classified by pattern into error / warning / info (patterns in one table,
  `doric.transport.MessageClassifier`, mirrored in the bridge; both tables were filled from the
  strings found in the DLL, see `vendor-dll.md` §8). Unknown text is `info`; it is never silently
  dropped.
- Timeouts per operation (init, open, command) are properties with defaults from M0 timings; the
  rig run measured `INIT` 10–13 s, `OPEN` 5.1 s, `LIST` 0.6–2.2 s and 5–9 ms per running command,
  all inside those defaults.
- Constructors do not touch hardware. `connect` does. Failures inside `connect` roll back
  (stop, close, quit) before rethrowing.
- `delete` never throws; teardown failures become warnings.

## 6. Portability rules for the core

- No `global`, no `evalin`, no `assignin`, no reliance on the current folder.
- Paths resolved from `mfilename('fullpath')` or explicit arguments.
- No figure creation or `drawnow` outside `+gui`. Blocking calls (`connect`, commands with
  `'Wait', true`) poll the transport in short `pause` steps bounded by their timeout. Hosts that
  cannot afford a callback-yielding `pause` use `'Wait', false`.
- Base MATLAB only (no toolbox).
- Windows only for real transports; `SimulatedTransport` works on any OS.

## 7. Repository layout (target)

```
DoricLED/
  +doric/                       package (see §3)
    +transport/  +gui/  private/
  native/doric_bridge/          bridge source + build script (build_bridge.m)
  bin/                          built doric_bridge.exe (build output)
  tests/                        matlab.unittest tests (122); run_tests.m
  examples/                     example_basic.m, example_closed_loop.m, example_bpod_softcode.m
  docs/                         this folder
  DoricSystemDLL/               vendor files (read-only)
  CLAUDE.md, agent.md -> CLAUDE.md, README.md
```

## 8. Milestones

| # | Milestone | Hardware? | State |
|---|---|---|---|
| M0 | **Spike.** (a) Build `doric_bridge.exe`. (b) Confirm the vendor Qt folder loads out-of-process. (c) Capture what `available_devices_with_ports` prints and on which stream; record the LEDFLS port number. (d) Print `sizeof`/`offsetof` of the structs. (e) CW on ch1 at a low current, seen by the operator. (f) Measure command latency with and without trailing `wait`. (g) Try the complex-mode enum question. (h) Brief `loadlibrary` smoke test. | (a), (d): no. (b), (c), (e)–(h): **yes** | **Done** 2026-09-17 (`vendor-dll.md` §9, `rig-checks.md`). Only the operator's own look at the fiber in (e) is outstanding |
| M1 | Package skeleton: enums, `ChannelSettings`/`ComplexSegment` with validation and factories, `SimulatedTransport`, test runner | No | **Done** |
| M2 | Full `doric_bridge` protocol + `BridgeTransport` (process, correlation, timeouts, message classification) | Build: no. Check: yes | **Done**: 13 protocol tests against `doric_bridge.exe --simulate`, and the whole protocol exercised against the real DLL on 2026-09-17 |
| M3 | `LightSource`/`Channel`: state machine, commands, limits, events, log, `record`, JSON config | No (simulated) | **Done**: 36 tests including fault injection (library error, timeout, bridge exit) and the LED-rating ceiling |
| M4 | GUI `doric.gui.LightSourceApp` exposing every field | No (simulated); rig check | **Done**: 21 headless tests, plus the main window driven against the real device on 2026-09-17. Esc, the advanced pop-up and the file dialogs still want a human pass |
| M5 | `examples/`, `bpod-integration.md`, README | Emulator only | **Done**: 3 examples, each run by the test suite |
| M6 | Rig verification: every mode on both channels, limits, stop-on-close, stop-on-MATLAB-kill, latency table | Yes | **Done** 2026-09-17: 18/18 mode-channel combinations, limit refusals, stop on window close and on MATLAB kill, latency table (`rig-checks.md`). Physical observation of the light, port stability across replug/reboot and Auto port with the rotary joint attached remain pending there |

Test counts as of 2026-09-21: 122 tests, all passing headless in about 13 s on MATLAB R2025b
(`matlab -batch "results = run_tests; exit(any([results.Failed]))"` from `tests/`).
