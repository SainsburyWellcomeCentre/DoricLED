# DoricLED — Agent Instructions

MATLAB package `doric` to control the **Doric 2-channel LED fiber light source `LEDFLS_465_465`**
(2 × 465 nm, one TTL/analog input and one output per channel), through the vendor's
`DoricSystem.dll`. It must work **standalone** (scripts and GUI) and be **easily embedded in
any MATLAB package doing closed-loop hardware control**, Bpod protocols included.

`agent.md` is a symlink to this file. If your tool did not resolve the symlink, read `CLAUDE.md`.

## Start here (fresh session)

1. Read this file, then `docs/architecture.md` (decisions D1–D7, milestones),
   `docs/vendor-dll.md` (everything known about the DLL), `docs/bridge-protocol.md`,
   `docs/api-reference.md`, `docs/gui.md`.
2. Check **Status** below for the current milestone. When the operator says **"go"**, start the
   next unfinished work. Everything that is left needs the device, so ask for permission for that
   specific run before touching it (see *Hardware*), and write the results into
   `docs/rig-checks.md`.
3. Keep **Status** and the docs current as work lands (see *Docs rule*).

## Status

| Milestone | State |
|---|---|
| Phase 1: discovery and design | **Done** (2026-09-17). General-purpose package, full user control of every mode/setting in API and GUI, no protocol-specific code |
| M0: spike | **Partly done** (2026-09-17). Done without hardware: bridge builds and runs, struct sizes/offsets confirmed (`docs/vendor-dll.md` §5, §8), whole protocol exercised against `doric_bridge.exe --simulate`. **Every hardware step is still pending** and needs operator approval (`docs/rig-checks.md` §1) |
| M1: skeleton, enums, `ChannelSettings`, `SimulatedTransport`, tests | **Done** |
| M2: full bridge + `BridgeTransport` | **Done** (hardware check pending) |
| M3: `LightSource`/`Channel` | **Done** |
| M4: GUI | **Done** (operator walk-through pending, `docs/rig-checks.md` §2) |
| M5: examples, integration guide, README final | **Done** |
| M6: rig verification | **Not started** (`docs/rig-checks.md` §3) |

114 tests, all passing headless on R2025b in about 13 s. Nothing has touched the device yet.

**Next work**, when the operator approves a run: the M0 hardware steps in `docs/rig-checks.md` §1,
in that order, then §2–§4. They answer the open questions listed in `docs/vendor-dll.md` §8: where
the library's debug text goes (the bridge captures stdout/stderr *and* `OutputDebugString`, and
tags each line with `src=`), the LEDFLS port number and whether it is stable, whether commands need
a trailing `wait()`, real command latency, the `ComplexModulation.mode` enum, `MicroscopeFollower`
support, the device's real max current, and whether `ls_send_settings` stops a running channel.

## Environment

| Thing | Path / value |
|---|---|
| Project (edit here, from WSL) | `/mnt/c/Users/harrislab/Documents/MATLAB/DoricLED` |
| Same path from Windows | `C:\Users\harrislab\Documents\MATLAB\DoricLED` |
| Vendor files (**read-only**) | `DoricSystemDLL/`; runtime folder `DoricSystemDLL/API/lib/x64/release/Qt` |
| MATLAB | R2025b only usable (`/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe`). The `R2024b` folder is a leftover install with no `matlab.exe`, so R2024b cannot be tested here. Base MATLAB only, no toolboxes |
| C/C++ compiler | MinGW-w64 (MATLAB support package): `C:\ProgramData\MATLAB\SupportPackages\R2025b\3P.instrset\mingw_w64.instrset\bin\g++.exe`; also configured for `mex` |
| Device on Windows | "LightSource Driver", `USB\VID_04D8&PID_F57E`, class `USBDevice` (**not** a COM port) |
| Bpod reference (read-only) | `../Bpod_Gen2` |
| Python | Not on Windows (Store alias only); do not depend on it. WSL has `python3`, fine for editing files from the agent side |

Agents run in WSL; MATLAB, the compiler and the device are on Windows.

```bash
# headless MATLAB from WSL: the whole suite (no hardware, about 40 s including startup)
"/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe" -batch "cd('C:\Users\harrislab\Documents\MATLAB\DoricLED\tests'); r = run_tests; fprintf('total=%d failed=%d\n', numel(r), sum([r.Failed])); exit(any([r.Failed]))"

# one class only, e.g. while iterating
"/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe" -batch "cd('C:\Users\harrislab\Documents\MATLAB\DoricLED\tests'); run_tests('Filter', 'GuiTest')"

# rebuild the bridge after editing native/doric_bridge/doric_bridge.cpp
"/mnt/c/Program Files/MATLAB/R2025b/bin/matlab.exe" -batch "cd('C:\Users\harrislab\Documents\MATLAB\DoricLED'); doric.build('Verbose', true)"

# the bridge alone, from the shell (simulated; a slow feeder keeps stdin open)
(printf '1 HELLO\n2 SIZES\n'; sleep 1) | bin/doric_bridge.exe --simulate
```

If that fails with `Exec format error`, WSL's Windows interop is not registered (systemd is on in
`/etc/wsl.conf`). It needs sudo; ask the operator to run
`sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'`.

## Rules

### Workspace boundary
- **Create, edit or delete files only inside this project folder.** Reading elsewhere is fine
  (`../Bpod_Gen2`, other lab packages, for idioms). Never modify `DoricSystemDLL/`, the MATLAB
  path or startup files, Bpod settings, or other repositories. If something outside must change,
  tell the operator exactly what and where.
- Resolve paths from the package location (`mfilename('fullpath')`), never hard-code the
  absolute paths above in code.

### Git
- **The operator handles git manually.** Do not run any git command (`init`, `status`, `add`,
  `commit`, `diff`, …) unless the operator explicitly asks in that message. Do not create
  `.gitignore` or other git files unless asked.

### Hardware
- **Never touch the real device without the operator's explicit permission for that specific
  run**: no running the bridge against the DLL with the device attached, `connect`, or the GUI on
  the real transport. An animal may be connected to the fibers. Permission covers that request
  only.
- Building the bridge, running it with `--simulate`, and all tests on `SimulatedTransport` need no
  permission.
- Before a permitted run: confirm nothing else holds the device (Doric Neuroscience Studio,
  another MATLAB). Always end with light off (`stopAll`), device closed, library quit.
- Record every hardware run in `docs/rig-checks.md` (date, what ran, results). Things needing a
  person at the rig (seeing light, a power meter, replugging) go in its *Pending* list.
- Assume the library can leave the device in an unknown state. Never assume a mode or current
  that was not sent in this process.

### Scope
- No protocol-specific code: nothing tied to a particular experiment or pipeline. Integration stays generic:
  `docs/bpod-integration.md` and `examples/`.
- **The user has full control.** Expose every vendor mode and field in the API and the GUI. Never
  choose a mode for the user, never clamp silently. Limits are user-set and refusals are
  explicit errors.

## Architecture in brief

Full detail in `docs/architecture.md`.

- **D1** DLL runs in `doric_bridge.exe` (C++, MinGW, vendor headers), which speaks a line protocol
  over stdin/stdout (`docs/bridge-protocol.md`), captures the library's debug text (its only error
  channel), pumps `wait()` itself, and turns the light off if its stdin closes. `loadlibrary`
  transport is a fallback only.
- **D2** Layers: `doric.gui.*` / host → `doric.LightSource` → `doric.Channel` ×2 →
  `doric.transport.Transport` (`BridgeTransport` | `LibraryTransport` | `SimulatedTransport`).
  Transport is injectable, the one switch between real and simulated hardware.
- **D3** `doric.ChannelSettings` value class holds *every* vendor field; factories are shortcuts;
  JSON/struct round-trip.
- **D4** Commanded state only (the API is write-only); command success = ack + no library error text
  within the settle window.
- **D5** Safety: stop all on connect/disconnect/delete/GUI close/bridge stdin EOF; `stopAll` works
  in every state; per-channel `MaxCurrentmA` (user-set, default 2000) refuses, never clamps.
- **D6** Closed-loop friendly: non-blocking `'Wait', false` on every command, events
  (`StateChanged`, `CommandCompleted`, `LibraryMessage`, `Faulted`), latency stats, `record()` for
  data files, no printing on hot paths.
- **D7** GUI is a programmatic `uifigure` class (no `.mlapp`), owning or attaching to a
  `LightSource`. Simplified main window (channel selection, mode, intensity, Apply/Start/Stop,
  STOP ALL); defaults are both channels selected, ExtTTL, 0 mA, and nothing is sent until
  Apply/Start. *Advanced settings…* opens a pop-up with every other field (`docs/gui.md`).

## Conventions

- **Layout**: `+doric/` (`Mode`, `CurrentMode`, `TriggerType`, `TriggerMode`, `ComplexMode`,
  `ComplexSegment`, `ChannelSettings`, `Channel`, `LightSource`, `DoricEventData`, `app`, `build`,
  `config`, `listDevices`, `version`, `private/`), `+doric/+transport/` (`Transport`,
  `BridgeTransport`, `SimulatedTransport`, `LibraryTransport`, `ProtocolCodec`,
  `MessageClassifier`, `private/doric_flat.h`), `+doric/+gui/LightSourceApp.m`,
  `native/doric_bridge/` (`doric_bridge.cpp`, `build_bridge.m`), `bin/` (build output), `tests/`,
  `examples/`, `docs/`.
- **Style**: 4-space indent; `camelCase` locals and methods, `PascalCase` classes and properties;
  no variables named after builtins. Every file starts with an H1 help line and a help block
  (purpose, arguments, returns, errors, `See also`). Comments explain *why*.
- **Units in names**: `CurrentmA`, `PeriodMs`, `SettleMs`. Channels are 1-based in MATLAB and
  converted to 0-based only in the transport.
- **Errors**: `error('doric:<Component>:<reason>', ...)` with an actionable message.
  Warnings the same. `delete` never throws.
- **Portability of the core** (`+doric`, `+transport`): no `global`, `evalin`, `assignin`, `cd`,
  figures or `drawnow`; base MATLAB only; no printing unless `Verbose`.
- **Traps found while building this** (keep them in mind when editing):
  - A `timer` callback can run *inside* another `poll` or between sending a request and recording
    it. `LightSource` guards with a depth counter (`BusyDepth`); keep that invariant.
  - `BridgeTransport` must drain the bridge's output on every send, or a burst of non-blocking
    commands deadlocks on the pipes.
  - Latency and `MessageReceived` are handled once, in `Transport.readNew`; subclasses that read
    early call `readNew`, never `readImpl`.
  - `event.EventData` already defines `Source`, so the event payload uses `LibrarySource`.
  - A method named `save` would shadow `save(obj, file)`; the config methods are
    `saveConfig`/`loadConfig`.
- **Bridge (C++)**: C++17, single source file if practical, no dependencies beyond the Windows API
  and the vendor headers; include `<cstdint>` before vendor headers; only one thread calls the DLL.
  Build via `native/doric_bridge/build_bridge.m` (or the g++ command documented there) into `bin/`.

## Tests

- `matlab.unittest` class-based tests in `tests/`, run with `tests/run_tests.m` (headless; command
  above). No test may touch hardware; use `SimulatedTransport` or `doric_bridge.exe --simulate`.
- Current suite (114 tests): `ChannelSettingsTest` (13), `EnumTest` (5), `ProtocolCodecTest` (10),
  `SimulatedTransportTest` (11), `LightSourceTest` (34), `BridgeProtocolTest` (14, skipped without
  `bin/doric_bridge.exe`), `GuiTest` (20), `LibraryTransportTest` (4), `ExamplesTest` (3).
- New behaviour needs a test in the matching class. Keep `LightSourceTest` deterministic:
  `'AutoPoll', false`, zero waits, and an explicit `poll()` after a non-blocking command.
- Things worth keeping covered because they broke once: the settings round trip through the real
  bridge (`settingsSurviveTheRoundTrip`), a burst of unpolled commands
  (`aBurstOfCommandsDoesNotDeadlock`), and the stdin-EOF safety path.

## Docs rule

- `README.md` is **end-user only**: what it is, requirements, installation, quick start, GUI
  launch, basic API, pointer to `docs/`. No developer notes, milestones or agent rules.
- `docs/` holds technical material: `architecture.md`, `vendor-dll.md`, `bridge-protocol.md`,
  `api-reference.md`, `gui.md`, `bpod-integration.md`, `rig-checks.md`.
- A change to a public signature, the bridge protocol, a decision or the milestone status updates
  the matching doc (and **Status** above) in the same piece of work.
- Anything learned about the vendor DLL goes in `docs/vendor-dll.md`, replacing "verify" marks
  with facts.
