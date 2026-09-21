# GUI: `doric.gui.LightSourceApp`

Programmatic `uifigure` (decision D7), implemented in `+doric/+gui/LightSourceApp.m` and covered
by 20 headless tests (`tests/GuiTest.m`). The GUI is a thin observer and controller over
`doric.LightSource`: every control calls a public API method, and every displayed value comes from
the object's properties or events. It has two windows:

- **Main window** (about 660 × 420 px): only the essential controls needed for closed-loop work —
  channel selection, mode, intensity, start/stop.
- **Advanced settings** pop-up: every other vendor field, opened from *Advanced settings…*.

Between them, **every vendor setting is editable**; the GUI never forces a mode on the user.

```matlab
doric.app()                      % owns a LightSource (real device); closes it on exit
doric.app('Transport', doric.transport.SimulatedTransport())   % owned, simulated
doric.app(led)                   % attaches to an existing LightSource; never closes it
doric.app(..., 'Visible', false) % hidden windows (tests, scripted checks)
```

## Main window

```
┌─────────────────────────────────────────────────────────────────────┐
│ Port [Auto ▾] [Scan] [Connect]  ● Ready - LEDFLS_465_465 on port 5  │
├─────────────────────────────────────────────────────────────────────┤
│ [✓] Channel 1  Mode [ExtTTL ▾]  [|---------] [   0] mA              │
│                Commanded: nothing sent           see Advanced…      │
│ [✓] Channel 2  Mode [ExtTTL ▾]  [|---------] [   0] mA              │
│                Commanded: ExtTTL, 100 mA, running                   │
├─────────────────────────────────────────────────────────────────────┤
│ Selected channels: [Apply] [Start] [Stop]  [✓] Live intensity       │
│ [Advanced settings...]   <last error, in red>        [ STOP ALL ]   │
├─────────────────────────────────────────────────────────────────────┤
│ 18:34:25.349  Library (info): LED Driver (Port #4)                  │
│ 18:34:25.394  State: Initialising -> Opening                        │
└─────────────────────────────────────────────────────────────────────┘
```

### Defaults when the window opens

| Control | Default |
|---|---|
| Channel selection | **Both channels selected** |
| Mode | **ExtTTL** on both |
| Intensity | **0 mA** on both |
| Live intensity | On |
| Port | **Auto** (the one listed device whose name matches `DeviceNamePattern`, default `'LED'`, so a rotary joint on the same PC is skipped; type a number or pick one after *Scan*) |

These are the GUI's starting *pending* values; they are **sent only when the user presses Apply or
Start**. They do not change the API's own defaults (`doric.ChannelSettings()` keeps the vendor
defaults — checked by a test). An **attached** window (`doric.app(led)`) leaves the host's pending
settings alone unless they are still the untouched API default, so it never overwrites what a
protocol prepared.

### Behaviour

- **Channel selection** checkboxes decide which channels *Apply*, *Start* and *Stop* act on. Each
  row's mode and intensity stay individually editable, so the channels can differ.
- **Mode** lists every vendor mode (Off, CW, ExtTTL, ExtAnalog, Square, Complex, Custom). A mode
  whose timing or sequence fields matter (Square, Complex, Custom, or any triggered/gated use)
  shows the hint *"see Advanced settings"*; nothing is locked. In **ExtAnalog** the current comes
  from the BNC voltage at 400 mA/V, so neither the intensity box nor `MaxCurrentmA` constrains it;
  the analog source itself must stay at or below 2.5 V (`vendor-dll.md` §10).
- **Intensity** slider plus numeric box, in mA. The slider's range follows the channel's
  `MaxCurrentmA`; the box stops at 1000 mA, the LED's rated maximum
  (`doric.Channel.DeviceMaxCurrentmA`), so an over-rating value cannot be typed at all, and a
  value above the channel's own `MaxCurrentmA` is refused by the API with an explicit message
  (never clamped). The slider snaps to the nearest whole mA (that is its resolution, not a clamp);
  a fractional value *typed* in the box is refused with a message. With *Live intensity* on and the channel running, changes
  call `setCurrent` (`ls_send_current`), throttled to about 10 Hz while dragging, with the final
  value always sent on release. With it off, intensity is sent on *Apply*.
- **Start** applies pending settings first when they differ from the commanded ones, and waits for
  that one command (about `SettleMs`), so a refused apply can never start the previous settings.
  Everything else is sent with `'Wait', false`.
- **Pending vs commanded.** An edited-but-unsent mode or intensity is highlighted; the *Commanded*
  line under each channel shows what was last sent successfully, with "(pending changes)" when the
  rest of the settings differ (D4).
- **Scan** runs `listDevices` (init → list → quit; no device is opened) and fills the dropdown with
  `<port> - <name>`. It blocks for a few seconds and is only enabled while disconnected.
- **Connect** is non-blocking (`'Wait', false` with a completion callback); the button becomes
  *Disconnect* when `Ready` and *Cancel* while connecting. The lamp is grey (disconnected), amber
  (connecting/closing), blue (ready) or red (faulted).
- **STOP ALL** is always enabled (every state, including `Faulted`) and bound to **Esc** in both
  windows.
- **Errors** never open a modal dialog: the failing call's message goes to the red status label,
  to the log and to `app.LastError`, so a headless test can read it.
- **Closing**: an owning window runs `disconnect` (which stops all) and closes the advanced
  pop-up. An attached window removes its listeners only.

## Advanced settings pop-up

Opened by *Advanced settings…*; a separate, non-modal `uifigure`, one per main window. If it is
already open, the button brings it to the front. One tab per channel, plus a *Limits & config* tab.

```
┌ Advanced settings - Doric LED ───────────────────────────────────────┐
│ [Channel 1] [Channel 2] [Limits & config]                            │
│ Preset [- ▾]   Mode and intensity are set in the main window.        │
│ ▸ Current mode      [Normal ▾]                                       │
│ ▸ Timing            Period, Time on, Starting delay, Delay between   │
│                     seq, Rising time, Falling time, Nb of sequences, │
│                     Pulses per sequence                              │
│ ▸ Trigger           Type [Manual ▾], Mode [Uninterrupted ▾],         │
│                     Repeatable sequence [ ], TTL output [ ]          │
│ ▸ Complex sequence  table ≤ 32 rows, [Add segment] [Remove]          │
│ ▸ Custom waveform   [workspace variable] [Import from workspace]     │
│                     [Import CSV...] [Clear]  n points, peak n mA     │
│                                              + preview plot          │
│                            [Revert] [Apply to channel] [Close]       │
└──────────────────────────────────────────────────────────────────────┘
Limits & config tab: MaxCurrentmA per channel, settle window, verbose output,
                     Save config... / Load config... (JSON, both channels)
```

- Mode and intensity are **not duplicated** here; they live in the main window. Both windows edit
  the same pending `Channel.Settings`, so a change in either shows up in the other at once.
- **Preset** fills every field from a `doric.ChannelSettings` factory (the vendor example values)
  while keeping the current intensity, and resets itself to `-`. Nothing is sent.
- **Complex sequence** is an editable table (mode as a dropdown, then current, timing, counts and
  delays). *Remove* drops the selected row, or the last one.
- **Custom waveform** imports a vector of mA values from the base workspace or a CSV/TXT file and
  previews it; *Clear* empties it.
- *Apply to channel* sends the full pending settings for that tab's channel, including the main
  window's mode and intensity. *Revert* reloads the commanded settings (disabled before anything
  was sent).
- Fields that the current mode does not use stay editable; their panel title says so
  ("Timing (not used by CW; still sent)") and is greyed, because the fields are transmitted
  whatever the mode.
- Every control has a tooltip giving the field's meaning and units.
- An invalid value is refused by the settings object; the message appears in the status label and
  the control snaps back to the stored value.
- *Load config* sets pending settings and limits only; nothing is sent until Apply.
- A limit change is refused (with a message) if the channel's commanded current is above the new
  limit; it never lowers the current silently.

## Style

Base MATLAB only, no `.mlapp`. Neutral theme, 465 nm blue accent (`[0.12 0.42 0.85]`); red only
for STOP ALL and faults; pale yellow for pending edits. The main window stays compact so it can
sit beside a task window.

## Testing

`tests/GuiTest.m` builds both windows on `SimulatedTransport` with `'Visible', false`, drives
controls the way a user would (set `Value`, then invoke the callback) and asserts on
`Transport.Calls`: the defaults (both selected, ExtTTL, 0 mA, nothing sent before Apply), connect
and disconnect, Apply/Start/Stop following the selection, live intensity, STOP ALL and Esc,
over-current refusal, fault display, advanced-window synchronisation, invalid values, presets,
complex-table editing, custom import, the limits tab and save/load. Ownership is covered too: an
owning window disconnects on close, an attached one does not.

On 2026-09-17 the main window was driven the same way against the **real device**: the defaults,
Connect (device `LED Driver` on port 4), Apply, Start on both channels, a live 30 → 80 mA change
while running, STOP ALL, starting one channel with the other deselected, an over-limit Apply
refused in the status line with nothing sent, and closing the window with a channel running (which
stops all, closes and quits). Esc, the *Advanced settings…* pop-up and the file dialogs still want
a human at the rig; both are recorded in `rig-checks.md`.
