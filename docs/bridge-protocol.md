# `doric_bridge.exe` line protocol

The helper process of decision D1 (`architecture.md`). Source: `native/doric_bridge/doric_bridge.cpp`;
built with `native/doric_bridge/build_bridge.m` (or `doric.build()`) into `bin/doric_bridge.exe`.
MATLAB side: `doric.transport.BridgeTransport` and `doric.transport.ProtocolCodec`.

**Implemented and tested** with `--simulate` by `tests/BridgeProtocolTest.m` (13 tests), and
exercised end to end against the real DLL and device on 2026-09-17 (see `rig-checks.md`). The
library's debug text arrives only on the bridge's stdout/stderr capture (`src=stdio`), never
through `OutputDebugString`, so that capture is the whole error channel.

## Process

```
doric_bridge.exe --dll-dir "<...>\DoricSystemDLL\API\lib\x64\release\Qt"
                 [--pump-ms 10] [--settle-ms 100] [--debugger 1] [--capture-ods 1]
doric_bridge.exe --simulate [--sim-devices 5:LEDFLS_465_465,7:Other] [--pump-ms ...]
```

| Option | Meaning |
|---|---|
| `--dll-dir` | folder holding `DoricSystem.dll` and its Qt runtime. Required unless `--simulate` |
| `--pump-ms` | `wait()` slice while idle and inside long waits (1–1000, default 10) |
| `--settle-ms` | default settle window after each command (0–60000, default 100) |
| `--debugger` | value passed to `init(debuggerActive)` (default 1) |
| `--capture-ods` | also capture `OutputDebugString` text (default 1) |
| `--simulate` | do not load the DLL; reply as if every call succeeded, emit the library's own strings |
| `--sim-devices` | `port:name[,port:name]` list reported by `LIST` in `--simulate` (default `5:LEDFLS_465_465`) |

Startup, in order: duplicate the original stdin/stdout handles; parse arguments; (real mode)
redirect the process's stdout/stderr — Win32 handles **and** C-runtime descriptors 1 and 2 — into
an internal pipe, set `QT_FORCE_STDERR_LOGGING=1` and `QT_ASSUME_STDERR_HAS_CONSOLE=1`, start the
`OutputDebugString` listener, set `QT_PLUGIN_PATH` (if unset) and `SetDllDirectoryW` to the DLL
folder, `LoadLibraryExW(DoricSystem.dll, LOAD_WITH_ALTERED_SEARCH_PATH)`, resolve the 12 exports;
then start the stdin reader thread and emit `@D EVT READY`.

Threads: one reads stdin into a request queue (max 256, then `ERR busy`); one reads the capture
pipe; one listens for `OutputDebugString`; one writes the protocol output; the **main thread is
the only one that calls the DLL**. It executes queued requests and otherwise pumps `wait(pump-ms)`.

Output never blocks the bridge. Lines are queued (8192 max) and written by the writer thread,
because `WriteFile` on a full pipe blocks forever: a bridge blocked in a write would not notice
stdin EOF and would keep the device open with the light on. If the host stops reading, the queue
drops unsolicited `EVT` lines first (replies last), reports `EVT INFO text=dropped=<n> lines...`
once it can write again, and the stdin-EOF shutdown still runs. Before exiting, the bridge gives
the writer up to 1 s to drain.

Safety:

- **stdin EOF** (MATLAB exited, crashed, or `BridgeTransport.close`), even while the host has
  stopped reading the bridge's output: queued requests are dropped,
  then `ls_stop_all` + `close_device` for every opened port, `quit`, `@D EVT EXITING reason=stdinClosed`,
  exit 0.
- `STOPALL` is a **priority request**: it is served between `wait()` slices, so it does not queue
  behind a long `INIT` or `OPEN`.
- `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)`: a vendor crash dialog can never
  block the process.

Exit codes: 0 normal, 2 bad arguments, 3 DLL not found or `LoadLibrary` failed, 4 missing export.
Failures before the protocol is usable are reported as `@D EVT FATAL code=<code> text=<...>`.

## Framing

- UTF-8, one message per line, `\n` terminated, tokens separated by single spaces.
- **Protocol lines from the bridge start with `@D `.** Any other line on stdout or stderr is
  library output, so vendor text cannot corrupt the protocol.
- Values in `key=value` tokens are percent-encoded: `%` → `%25`, space → `%20`, control
  characters → `%XX`. `doric.transport.ProtocolCodec.decodeValue` reverses it. The free text after
  an `ERR <code>` is **not** encoded; it runs to the end of the line.

### Requests (MATLAB → bridge)

```
<id> <COMMAND> [key=value ...] [bare tokens]
```

`<id>` is a positive integer chosen by MATLAB and echoed in the reply. A malformed id is answered
with `@D 0 ERR invalidArgument ...`. Commands are case-insensitive on the wire (MATLAB sends upper
case). Every command accepts `settle=<ms>` (0–60000) to override `--settle-ms`.

### Replies and notifications (bridge → MATLAB)

```
@D <id> OK [key=value ...] [msgs=<n>]
@D <id> ERR <code> <free text to end of line>
@D EVT LIBMSG id=<id> src=stdio|ods sev=error|warning|info text=<encoded>
@D EVT READY bridge=<ver> simulate=0|1
@D EVT EXITING reason=quit|stdinClosed
@D EVT FATAL code=<code> text=<encoded>
@D EVT INFO text=<encoded>
@D EVT SIMCALL fn=<dll function> [args ...]        (--simulate only)
```

A request completes with its `OK` or `ERR`. After the DLL call the bridge pumps `wait(settle)`,
then gives the capture threads 2 ms to catch up, and collects the library text emitted in that
window (`msgs=<n>` counts it). If any collected line is classified `error`, the reply is
`ERR libraryError <first error line>`; otherwise `OK`. Each line is *also* delivered as
`EVT LIBMSG` tagged with the id of the request in flight (0 when idle), so nothing is dropped.

Severity patterns (case-insensitive substrings, error wins; mirrored in
`doric.transport.MessageClassifier`):

| Severity | Patterns |
|---|---|
| error | `unable to`, `could not`, `couldn't`, `not initialized`, `device not found`, `not a lightsource driver`, `wrong controller`, `error`, `failed`, `invalid` |
| warning | `no available device`, `already initialized`, `warning`, `timeout`, `timed out` |
| info | anything else (never dropped) |

## Commands

| Command | Args | DLL calls | Reply data |
|---|---|---|---|
| `HELLO` | | none | `bridge=<ver> dll=<path\|none> pid=<n> simulate=0/1 pumpms=<n> settlems=<n> ods=0/1` |
| `INIT` | `debugger=0/1` `waitms=<n>` (default 5000) | `init`, `wait` | |
| `LIST` | `waitms=<n>` (default 200) | `available_devices_with_ports`, `wait` | `n=<k>` = lines containing `(Port #`; MATLAB parses the names from the `LIBMSG` text |
| `OPEN` | `port=<p>` `waitms=<n>` (5000) | `open_device`, `wait` | port is remembered only if no error text arrived |
| `CLOSE` | `port=<p>` `waitms=<n>` (1000) | `close_device`, `wait` | |
| `START` / `STOP` | `port=<p>` `ch=<0-based>` | `ls_start_channel` / `ls_stop_channel` | |
| `STARTALL` | `port=<p>` | `ls_start_all` | |
| `STOPALL` | `port=<p>` optional | `ls_stop_all` per port; without `port`, every port the bridge opened (none before `INIT`) | `ports=<n>` |
| `CURRENT` | `port=<p>` `ch=<i>` `ma=<0..65535>` | `ls_send_current` | |
| `SETTINGS` | see below | `ls_send_settings` | |
| `SIZES` | | none | `sizeof`/`offsetof` of the three structs plus `compiler=mingw-gcc-<v>` |
| `QUIT` | | stop all, close all, `quit` | replies `OK`, then `EVT EXITING reason=quit`, then exits 0 |
| `SIMFAIL` | `<COMMAND> <text...>` (bare tokens, `--simulate` only) | none | the next `<COMMAND>` emits `<text>` as library output |
| `SIMCRASH` | (`--simulate` only) | none | exits with code 9 **without** the stdin-EOF safety path (fault-injection hook) |

`LIST`, `OPEN`, `CLOSE`, `START`, `STOP`, `STARTALL`, `CURRENT` and `SETTINGS` are refused with
`ERR notInitialised` before `INIT`. `STOPALL` is allowed in every state.

`SETTINGS` keeps the struct it sent alive per channel, because the library may read it after the
call returns.

### `SETTINGS` arguments

All keys are optional except `port` and `ch`; omitted keys take the vendor header defaults.

```
port= ch= mode= ttlout= trigtype= trigmode= repeat= curmode=
ttl.current= ttl.startdelay= ttl.seqdelay= ttl.period= ttl.on= ttl.rise= ttl.fall=
ttl.nseq= ttl.npulses=
ncx=<0..32>
cx<k>.mode= cx<k>.current= cx<k>.seqdelay= cx<k>.period= cx<k>.on= cx<k>.nseq=
cx<k>.npulses= cx<k>.startdelay=        (k = 0 .. ncx-1)
custom=<v0,v1,...>                      up to 1000 uint16 values; the missing tail is zero-filled
```

Enumerations travel as integers (the MATLAB enumeration classes own the names): `mode` accepts
0–6 and 10, `cx<k>.mode` 0–11, `trigtype` 0/1/255, `trigmode` 0–3, `curmode` 0–2. Bounds are
checked for every field; an unknown key, an out-of-range value or a `cx<k>` index at or above
`ncx` gives `ERR invalidArgument <key>: <why>`. The bridge allocates the 32-element
`ComplexModulation` array itself. MATLAB validates first (`doric.ChannelSettings`), the bridge
checks again.

## Error codes

`invalidArgument`, `unknownCommand`, `notInitialised`, `libraryError`, `vendorDllNotFound`,
`missingExport`, `busy`.

## Measured behaviour (`--simulate`, MATLAB R2025b, 2026-09-17)

| Step | Time |
|---|---|
| `BridgeTransport.open` (process start, `READY`, `HELLO`) | 40–90 ms |
| Non-blocking command (`'Wait', false`): MATLAB call to pipe write | 0.8 ms |
| Round trip send → reply, `settle=0` (`stats()` over 500 commands) | mean 1.3 ms, median 1.1 ms, P95 2.6 ms, max 16.8 ms |
| Blocking command, `SettleMs` 0 | 1.1 ms |
| Blocking command, `SettleMs` 100 | 119 ms |

Real-device latency, measured through `LightSource` on 2026-09-17: `CURRENT`, `START` and `STOP`
5–9 ms and `SETTINGS` ~12 ms with `settle=0`; ~110–130 ms with `SettleMs` 100. `INIT` 10–13 s,
`OPEN` 5.1 s and `LIST` 0.6–2.2 s, each dominated by its own `waitms`.

**Host rule:** a burst of non-blocking requests without polling could fill the bridge's stdout
pipe, which blocks the bridge and then the host's own write. `BridgeTransport.sendImpl` therefore
drains the incoming pipe on every send; `tests/BridgeProtocolTest.m` covers 200 unpolled commands.
