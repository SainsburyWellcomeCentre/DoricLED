# API reference

The public surface of the `doric` package as implemented (M1–M5). Channels are **1-based** in
MATLAB (1, 2); the transport converts to the vendor's 0-based index. Every name here is covered by
`tests/`.

Differences from the pre-implementation draft of this file: `save`/`load` are named
`saveConfig`/`loadConfig` (a `save` method would shadow `save(obj, file)` for the whole object),
the event-data property for the origin of library text is `LibrarySource` (`Source` is taken by
`event.EventData`), and `poll`, `AutoPoll`, `PollPeriodMs`, `CommandedState` and
`doric.ChannelSettings/with`, `peakCurrentmA`, `check` were added.

## `doric.LightSource` (handle)

### Construction

```matlab
ls = doric.LightSource()                         % real device, bridge transport
ls = doric.LightSource('Port', 5)                % Doric port number from doric.listDevices
ls = doric.LightSource('Transport', doric.transport.SimulatedTransport())
ls = doric.LightSource(..., 'Verbose', true, 'SettleMs', 100, 'InitWaitMs', 5000)
```

The constructor never touches hardware. Unknown options error `doric:LightSource:invalidOption`.

### Properties

Read-only: `State` (`Disconnected`, `Initialising`, `Opening`, `Ready`, `Closing`, `Faulted`),
`FaultReason`, `Channels` (`doric.Channel` 1×2), `Transport`, `DeviceName`, `Devices`
(table `Port`, `Name` from the last listing).

Settable: `Port` (only while `Disconnected` or `Faulted`, else `doric:LightSource:portLocked`;
`[]` means auto: the one listed device whose name matches `DeviceNamePattern`),
`DeviceNamePattern` (`'LED'`: a case-sensitive regular expression; see *Choosing the device*
below), `SettleMs` (100), `CommandTimeoutMs` (2000),
`InitWaitMs` (5000), `ListWaitMs` (500), `OpenWaitMs` (5000), `CloseWaitMs` (1000),
`ConnectTimeoutMs` (30000), `Debugger` (true), `AutoPoll` (true), `PollPeriodMs` (20),
`Verbose` (false), `LogCapacity` (1000).

### Choosing the device

The library lists every Doric USB device on the PC, not only light sources: at this rig an
*Assisted Rotary Joint (ARJ_24_Gen2)* on port 3 sits next to the *LED Driver* on port 4. With
`Port` empty, `connect` keeps only the listed names that match `DeviceNamePattern` (default
`'LED'`, case-sensitive, so `LED Driver` and `LEDFLS_465_465` match and the rotary joint does not)
and opens that one device. No match errors `doric:LightSource:deviceNotFound` and more than one
errors `doric:LightSource:portRequired`, both naming everything listed; nothing is opened in
either case. An explicit `Port` bypasses the pattern. The chosen device is logged (`log()`) and
reported in `DeviceName`/`Port`.

```matlab
led = doric.LightSource();                                  % auto: the one "LED" device
led = doric.LightSource('DeviceNamePattern', 'LED|Laser');  % another naming, the user's choice
led = doric.LightSource('Port', 4);                         % no matching at all
```

Timeout per request = the relevant library wait + `SettleMs` + `CommandTimeoutMs` (commands) or
+ `ConnectTimeoutMs` (`INIT`, `OPEN`).

### Methods

| Method | Description |
|---|---|
| `result = connect(...)` | `init` → `LIST` → `open_device` → `ls_stop_all`. `'Wait'` (default true), `'OnDone', fn`. Already connected: returns `Ok` at once. From `Faulted`: disconnects first |
| `disconnect()` | `ls_stop_all` → `close_device` → `quit` → transport close. Idempotent, never throws (problems become warnings) |
| `result = reconnect(...)` | `disconnect`, then `connect` |
| `result = stopAll(...)` | Emergency stop. Allowed in **every** state; with no open transport it returns `Ok` with "Nothing open" |
| `result = startAll(...)` | `ls_start_all`; marks every configured channel running |
| `results = apply(s1, s2, ...)` | Settings for channel 1 and 2; `[]` skips a channel. Returns a 1×2 cell of results |
| `devices = listDevices()` | table(`Port`, `Name`). When `Ready` it re-lists over the open connection; when disconnected it starts the transport, inits, lists, quits and stops it — **no device is opened** |
| `poll()` | Process replies, library text and events now. Called by the `AutoPoll` timer and by blocking commands; hosts that switch `AutoPoll` off call it themselves |
| `s = record()` | Plain struct (no objects) for data files: package/version, timestamp, state, port, device, transport, bridge info, per-channel limits, commanded and pending settings, `Stats`, `Log` |
| `t = log()` | Table `Time, Kind, Severity, Command, Channel, Id, Ok, LatencyMs, Text`. `Kind` is `command`, `library`, `state`, `event`, `reply` or `error` |
| `t = stats()` | Table `Command, Count, Failures, MeanMs, MedianMs, P95Ms, MaxMs` (host-side send→reply time) |
| `saveConfig(file)` | JSON of both channels' pending settings and limits |
| `loadConfig(file)` | Sets pending settings and limits from that JSON. Validates everything first and **sends nothing**; refuses a limit below a commanded current |
| `delete` | `disconnect`, stop the timer, delete an owned transport. Never throws |

Command options, accepted by `connect`, `stopAll`, `startAll`, `apply` and every
`doric.Channel` command: `'Wait'` (default true), `'SettleMs'`, `'OnDone'` (`fn(result)`).

A `result` struct has `Id`, `Command`, `Channel`, `Ok`, `Code`, `Message`, `LatencyMs`, `Data`,
`LibraryText`. With `'Wait', true` a failure throws; with `'Wait', false` the call returns at once
with `Ok = []` and the outcome arrives through `OnDone`, the `CommandCompleted` event, `log()` and
the commanded properties.

### Events

`StateChanged`, `CommandCompleted`, `LibraryMessage`, `Faulted`; event data is a
`doric.DoricEventData` (`Id`, `Command`, `Channel`, `Ok`, `Code`, `Message`, `LatencyMs`, `Text`,
`Severity`, `LibrarySource`, `OldState`, `NewState`, `Reason`, `Message` struct for transports).
Events fire only when something listens, so an unobserved command costs nothing extra.

### Errors

`doric:LightSource:` `notReady`, `busy`, `deviceNotFound`, `portRequired`, `portLocked`,
`timeout`, `bridgeExited`, `libraryError`, `cancelled`, `invalidOption`, `invalidConfig`,
`fileError`. `loadConfig` also raises `doric:Channel:aboveDeviceLimit` (and
`limitBelowCommanded`) from its validation pass, before anything is assigned. Transport errors from `connect` pass through (e.g.
`doric:BridgeTransport:bridgeNotFound`). A timeout or a dead bridge also makes the object
`Faulted`; a library "Device not found" while `Ready` does too.

## `doric.Channel` (handle, created by `LightSource`)

| Member | Description |
|---|---|
| `Index` | 1 or 2 |
| `Settings` | Pending `doric.ChannelSettings` (settable; a struct is accepted and converted). Not sent until `apply` |
| `MaxCurrentmA` | User limit, default 700 (`RecommendedMaxCurrentmA`). `loadConfig` refuses a file whose limit is above `DeviceMaxCurrentmA` and loads nothing. A request above it errors `doric:Channel:overCurrent`; lowering it below `CommandedCurrentmA` errors `doric:Channel:limitBelowCommanded`; raising it above `DeviceMaxCurrentmA` errors `doric:Channel:aboveDeviceLimit`. Nothing is ever clamped |
| `DeviceMaxCurrentmA` | Constant 1000 mA: the rated maximum of a 465 nm LED head (Doric *LED Light Source* manual V2.1.1, table 5.8). A hard ceiling — no API or GUI path can command more, in any current mode. The driver's pulsed 2000 mA overdrive is deliberately out of reach. It does **not** apply in `ExtAnalog`, where the BNC voltage sets the current at 400 mA/V |
| `RecommendedMaxCurrentmA` | Constant 700 mA: Doric's recommended operating current for a 1000 mA LED (manual table 5.2), and the default of `MaxCurrentmA` |
| `CommandedSettings` | Last settings the device acknowledged, `[]` before any |
| `CommandedCurrentmA` | Last current acknowledged (from settings or `setCurrent`), `[]` before any |
| `IsRunning` | Commanded running flag |
| `CommandedState` | `Unconfigured` → `Configured` → `Running` ⇄ `Stopped` |
| `LastCommandAt` | `datetime` of the last acknowledged command (`NaT` before) |
| `apply()` / `apply(settings)` | `ls_send_settings`. `apply(settings)` also stores it as the pending `Settings`. The limit is checked against `peakCurrentmA` (current, segments **and** custom points), and `check()` warnings are raised as `doric:ChannelSettings:suspicious` |
| `start()` / `stop()` | `ls_start_channel` / `ls_stop_channel` |
| `setCurrent(mA)` | `ls_send_current`; allowed while running (fast path) |

Errors: `doric:Channel:` `overCurrent`, `aboveDeviceLimit`, `invalidSettings`, `invalidCurrent`,
`invalidLimit`, `limitBelowCommanded`, plus the outcome codes (`libraryError`, `timeout`,
`bridgeExited`, …) and `doric:LightSource:notReady`.

## `doric.ChannelSettings` (value)

Every vendor field, validated on assignment (`doric:ChannelSettings:invalidSettings`); an invalid
object cannot exist and nothing is clamped or rounded.

| Property | Vendor field | Type / range |
|---|---|---|
| `Mode` | `mode` | `doric.Mode` (member, name or value) |
| `IsTTLOutput` | `isTTLOutput` | logical |
| `TriggerType` | `triggerType` | `doric.TriggerType` |
| `TriggerMode` | `triggerMode` | `doric.TriggerMode` |
| `IsRepeatableSequence` | `isRepeatableSequence` | logical |
| `CurrentMode` | `currentMode` | `doric.CurrentMode` |
| `CurrentmA` | `ttlModulation.current` | integer 0–65535 |
| `StartingDelayMs` | `ttlModulation.startingDelayMs` | integer 0–4294967295 |
| `DelayBetweenSeqMs` | `ttlModulation.delayBetweenSeqMs` | integer 0–4294967295 |
| `PeriodMs` | `ttlModulation.periodMs` | real ≥ 0 |
| `TimeOnMs` | `ttlModulation.timeOnMs` | real ≥ 0 (`> PeriodMs` is warned by `check`, never enforced) |
| `RisingTimeMs`, `FallingTimeMs` | `ttlModulation.*` | integer 0–65535 |
| `NbOfSeq`, `NbOfPulsesPerSeq` | `ttlModulation.*` | integer 0–65535 (0 = infinite) |
| `ComplexSegments` | `complexModulations` + `nbComplexModulations` | `doric.ComplexSegment` vector, 0–32 (struct arrays accepted) |
| `CustomDataPoints` | `customDataPoint` | integers 0–65535, at most 1000 (sent zero-padded; trailing zeros are not transmitted) |

Constants: `MaxComplexSegments` (32), `MaxCustomDataPoints` (1000).

Factories (the vendor examples' values, `vendor-dll.md` §6; trailing name-value pairs override any
property): `off()`, `cw(mA)`, `extTTL(mA)`, `extAnalog(mA)`, `square(mA, periodMs, timeOnMs)`,
`triggered(mA)`, `gated(mA)`, `complex(segments)`, `custom(pointsmA, periodMs)`. Called with no
arguments each uses the vendor example's own numbers.

Methods: `with(name, value, ...)` (copy with changes), `peakCurrentmA()`, `check()` (cellstr of
plausibility warnings, never throws), `describe()`, `toStruct`/`fromStruct`, `toJSON`/`fromJSON`.

## `doric.ComplexSegment` (value)

`Mode` (`doric.ComplexMode`), `CurrentmA`, `DelayBetweenSeqMs`, `PeriodMs`, `TimeOnMs`, `NbOfSeq`,
`NbOfPulsesPerSeq`, `StartingDelayMs`; `toStruct`, `fromStruct`. Errors
`doric:ComplexSegment:invalidSettings`.

## Enumerations

Values from `vendor-dll.md` §4, pinned by `tests/EnumTest.m`: `doric.Mode` (Off…Custom),
`doric.CurrentMode`, `doric.TriggerType`, `doric.TriggerMode`, `doric.ComplexMode` (the vendor
Python enumeration, Off…LockIn). `MicroscopeFollower` (10) is **not** in `doric.Mode` until a rig
check confirms it; the bridge already accepts the value.

## Functions

| Function | Description |
|---|---|
| `doric.listDevices(...)` | Temporary transport: init → list → quit. Returns table(`Port`, `Name`). Takes the same options as `doric.LightSource` |
| `doric.build(...)` | Builds `bin/doric_bridge.exe` with MinGW-w64 (wraps `native/doric_bridge/build_bridge.m`); `'Verbose'`, `'Compiler'`, `'OutDir'` |
| `doric.app(...)` | Shortcut for `doric.gui.LightSourceApp(...)` |
| `doric.config(...)` | Resolved paths: `RootDir`, `BridgeExe`, `DllDir`, `Version`. Overrides by argument or `setpref('doric', 'DllDir', ...)` |
| `doric.version()` | Package version string |

## `doric.transport.Transport` (abstract handle)

Request/reply model shared by every transport:

```matlab
id = t.send(command, args)                    % queue, return at once
messages = t.poll()                           % drain what has arrived; never blocks
[reply, others] = t.request(command, args, timeoutMs)   % blocking convenience
```

Primitives (all non-blocking, all return the request id, channels 1-based, a trailing `settleMs`
is optional): `hello`, `sizes`, `init(debugger, waitMs)`, `listDevices(waitMs)`,
`openDevice(port, waitMs)`, `closeDevice(port, waitMs)`, `startChannel(port, channel)`,
`stopChannel(port, channel)`, `startAll(port)`, `stopAll(port)`
(`[]` = every port the transport opened), `sendSettings(port, channel, settings)`,
`sendCurrent(port, channel, currentmA)`, `quit`. Lifecycle: `open`, `close`, `isOpen`.

Message struct: `Kind` (`reply`, `libmsg`, `event`, `exit`), `Id`, `Ok`, `Code`, `Text`,
`Severity`, `Source`, `Name`, `Data`, `LatencyMs`, `Time`. Event `MessageReceived` fires once per
message when anyone listens.

Subclasses implement `open`, `close`, `isOpen`, `sendImpl`, `readImpl`; they call the protected
`readNew`/`stash` when they need to drain the link early.

### `doric.transport.BridgeTransport`

Real device through `doric_bridge.exe` (default transport). Options/properties: `ExePath`,
`DllDir`, `PumpMs`, `SettleMs`, `Debugger`, `CaptureOds`, `Simulate`, `SimDevices`,
`StartTimeoutMs`, `CloseTimeoutMs`; read-only `BridgeVersion`, `DllPath`, `Pid`, `ExitCode`.
Errors: `notWindows`, `bridgeNotFound`, `vendorDllNotFound`, `missingExport`, `startFailed`,
`bridgeExited`, `invalidOption`. `Simulate` runs the bridge with `--simulate` (no DLL, no
hardware) and is what the protocol tests use.

### `doric.transport.SimulatedTransport`

No hardware, any OS. Same replies and library strings as the bridge's `--simulate`, including the
stdin-EOF safety path on `close`. Properties: `Devices`, `LatencyMs`, `HonourWaits`; read-only
`Calls` (`Time`, `Id`, `Command`, `Args`, `Implicit`; `Args` are the protocol arguments, with the
`doric.ChannelSettings` object in `Args.Settings`), `Device` (per-port simulated state),
`IsInitialised`, `OpenPorts`. Fault injection: `failNext(command, text)`, `hangNext(command)`,
`crash(exitCode)`, `emitLibraryMessage(text)`, `clearCalls()`, `callsOf(command)`.

### `doric.transport.LibraryTransport`

Experimental `loadlibrary` fallback (D1). Library text cannot be captured in-process (so `LIST`
always reports zero devices and library errors are invisible) and Complex segments are unsupported
(`doric:LibraryTransport:unsupported`). Run against the device once, on 2026-09-17: the flat
commands work and can drive light, but the MATLAB process always ends in an access violation
(0xc0000005) once the library has been initialised. `UnloadOnClose` (default `false`) therefore
keeps `close` from calling `unloadlibrary`, which would crash MATLAB immediately; the process must
be treated as throwaway. Properties: `DllDir`, `PumpMs`, `Debugger`, `LibraryName`,
`UnloadOnClose`. See its help, `vendor-dll.md` §9 and `rig-checks.md`.

### `doric.transport.MessageClassifier` / `ProtocolCodec`

`classify(text)` → `error`/`warning`/`info` and `isDeviceNotFound(text)`; `encodeRequest`,
`settingsTokens`, `decodeLine`, `decodeValue` (see `bridge-protocol.md`).

## `doric.gui.LightSourceApp`

```matlab
app = doric.gui.LightSourceApp()            % owns its own LightSource; closes it on exit
app = doric.gui.LightSourceApp('Transport', t, 'Port', 5)   % owned, with LightSource options
app = doric.gui.LightSourceApp(ls)          % attaches; never disconnects it
app = doric.gui.LightSourceApp(..., 'Visible', false)       % hidden (tests)
```

| Member | Description |
|---|---|
| `LightSource`, `OwnsLightSource` | The object shown and whether the app created it |
| `Figure`, `AdvancedFigure` | Main window and advanced pop-up (`[]` until opened) |
| `Controls`, `AdvancedControls` | Structs of components, for scripting and tests |
| `LastError` | Text of the last error shown to the user |
| `openAdvanced()` | Open or raise the advanced settings window |
| `selectedChannels()` | Indices of the selected channels (default `[1 2]`) |
| `refresh()` | Redraw every control from the LightSource |
| `saveConfigTo(file)` / `loadConfigFrom(file)` | What the Save/Load buttons do |
| `close()` | Close both windows; disconnects only an owned LightSource |

Defaults on open: both channels selected, `ExtTTL`, 0 mA, nothing sent. See `gui.md`.
