# DoricLED

MATLAB control of the **Doric 2-channel LED fiber light source** (`LEDFLS_465_465`, 2 × 465 nm):
a scriptable driver, an interactive GUI, and a simulated device for testing, built to run
standalone or inside Bpod protocols and other closed-loop experiments.

> **Status: verified on hardware (2026-09-17).** Every mode has been applied, started and stopped
> on both channels of a real `LEDFLS_465_465`, with the automated tests passing as well. What has
> not been checked is the light itself: no one has watched the fiber or put a power meter on it,
> and the external TTL/analog inputs have not been driven from a real source. Keep the first
> sessions at low current with no animal connected
> (see [docs/rig-checks.md](docs/rig-checks.md)).

## Features

- Every mode the driver supports: Off, CW, external TTL, external analog, Square, Complex and
  Custom, with triggered/gated operation and every timing field.
- Live current control on both channels, including while a channel is running.
- A GUI to check the hardware, switch channels, set modes and adjust current in real time.
- Safe by default: light is switched off when you disconnect, close the GUI, or MATLAB exits.
- A simulated device, so code that uses the LED can be developed and tested without hardware.
- Save and load complete channel configurations; a summary of what was sent can be stored with
  your experiment data.

## Requirements

- Windows 10/11, 64-bit
- MATLAB R2025b, no toolboxes needed (the only release tested here; the package uses no
  release-specific features, so earlier releases may work but are unverified)
- Doric `LEDFLS_465_465` connected by USB (it shows up as "LightSource Driver" in Device Manager)
- The Doric System DLL, included in `DoricSystemDLL/`
- MinGW-w64 C/C++ compiler (MATLAB Add-On *MATLAB Support for MinGW-w64 C/C++ Compiler*), only
  to build the helper program once

## Installation

1. Place this folder anywhere, e.g. `Documents\MATLAB\DoricLED`.
2. Add the folder (not its subfolders) to the MATLAB path:
   ```matlab
   addpath('C:\Users\<you>\Documents\MATLAB\DoricLED'); savepath
   ```
3. Build the helper program once:
   ```matlab
   doric.build()
   ```
4. Check the installation without touching the hardware:
   ```matlab
   cd(fullfile(fileparts(which('doric.version')), 'tests')); run_tests
   ```
5. Close Doric Neuroscience Studio or any other program using the light source.

## Quick start

```matlab
doric.listDevices()                          % find the device's port number

led = doric.LightSource('Port', 5);
led.connect();                               % takes a few seconds

led.Channels(1).MaxCurrentmA = 300;          % refuse anything brighter (0-1000; default 700)
led.Channels(1).apply(doric.ChannelSettings.cw(100));   % continuous, 100 mA
led.Channels(1).start();
led.Channels(1).setCurrent(150);             % change intensity while on
led.Channels(1).stop();

led.Channels(2).apply(doric.ChannelSettings.extTTL(200)); % follow the TTL input at 200 mA
led.Channels(2).start();

led.disconnect();                            % switches everything off
```

Every setting can be changed individually:

```matlab
s = doric.ChannelSettings.square(80, 1000, 500);  % 80 mA, 1 s period, 0.5 s on
s.TriggerType = doric.TriggerType.Gated;
s.NbOfSeq = 0;                                    % repeat indefinitely
led.Channels(1).apply(s);
```

Longer walk-throughs are in [`examples/`](examples): `example_basic.m` (every mode),
`example_closed_loop.m` (non-blocking control from a loop) and `example_bpod_softcode.m`. They run
on the simulated device as they are; set `useHardware = true` to drive the real one.

## GUI

```matlab
doric.app()          % opens the control window and manages the connection
doric.app(led)       % controls a LightSource you already opened (leaves it open on close)
```

The main window keeps to the essentials: device scan and connect, channel selection, mode and
intensity for each channel, Apply/Start/Stop for the selected channels, live intensity adjustment,
a message log, and a **STOP ALL** button (also the Esc key). It opens with both channels selected,
in ExtTTL mode at 0 mA; nothing is sent to the device until you press Apply or Start.

**Advanced settings…** opens a separate window with every other setting: current mode, timing,
trigger options, complex sequences, custom waveforms, current limits, and saving/loading
configurations.

## Testing without hardware

```matlab
led = doric.LightSource('Transport', doric.transport.SimulatedTransport());
```

The simulated device answers like the real one, records every call (`led.Transport.Calls`) and can
be told to fail (`failNext`), hang (`hangNext`) or die (`crash`), so error handling can be tested
too.

## Using it in a Bpod protocol

Connect once during protocol setup, change settings between trials, save `led.record()` with the
session data, and disconnect at the end. In emulator mode, use the simulated device. See
[docs/bpod-integration.md](docs/bpod-integration.md) for complete patterns.

## Safety

The package cannot read back the driver's state; it reports what it last sent. Set a per-channel
current limit that suits your LEDs and preparation:

```matlab
led.Channels(1).MaxCurrentmA = 500;
```

Requests above the limit are refused, never reduced silently.

**Current ceiling.** A 465 nm LED head is rated **1000 mA** and Doric recommends **700 mA** for
LEDs of that rating (*LED Light Source* user manual V2.1.1, tables 5.8 and 5.2). `MaxCurrentmA`
starts at 700 mA and cannot be set above 1000 mA from the API or the GUI, so nothing this package
sends can exceed the LED's rating. The driver hardware can go to 2000 mA in pulsed *overdrive*;
that is out of reach here on purpose, because Doric's manual restricts overdrive to pulsed
signals — otherwise it damages the light source.

One case the software cannot cover: in **external analog** mode the current follows the voltage on
the BNC input at 400 mA/V, so 2.5 V already asks for 1000 mA and 5 V asks for 2000 mA. Scale your
analog source accordingly; no limit set in MATLAB applies to it. The light is switched off when you
disconnect, when the object is deleted, when the GUI window closes, and when MATLAB exits or
crashes; `led.stopAll()` works in every state.

## Documentation

Technical documentation is in [`docs/`](docs): API reference, architecture, GUI and integration
guides, notes on the vendor DLL, and the rig-check log.
