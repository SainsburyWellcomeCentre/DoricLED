# Integrating with Bpod protocols and other closed-loop hosts

Generic blueprint. The package ships **no protocol-specific code**; a host decides which modes and
settings to use. The patterns below are what a Bpod protocol (or any MATLAB control loop) needs.
Runnable versions live in `examples/example_closed_loop.m` and `examples/example_bpod_softcode.m`,
both exercised by the test suite on the simulated device.

## 1. Choosing a control strategy

| Need | Strategy | Timing precision |
|---|---|---|
| Light follows state-machine outputs exactly | Channel in `ExtTTL` (or `ExtAnalog`); Bpod BNC/Wire output (or a pulse generator) drives the driver's input; MATLAB only sets current/mode between trials | Hardware (sub-ms) |
| Driver generates the waveform, a TTL starts or gates it | `Square`/`Complex`/`Custom` with `TriggerType` `Triggered` or `Gated` | Hardware |
| MATLAB decides on the fly (closed loop, soft codes) | `start`/`stop`/`setCurrent` from MATLAB with `'Wait', false` | Host + USB + library latency. The MATLAB-side cost is about 0.8 ms per command and the round trip to the bridge about 1.3 ms (`bridge-protocol.md`); the device's own latency is measured at the rig (M0/M6) |

## 2. Lifecycle in a Bpod protocol

```matlab
% --- setup (before the first trial) -------------------------------------
global BpodSystem
if BpodSystem.EmulatorMode
    transport = doric.transport.SimulatedTransport();   % logs what it would do
else
    transport = [];                                     % default: real device
end
led = doric.LightSource('Port', S.Doric.Port, 'Transport', transport);
cleanupLed = onCleanup(@() delete(led));                % light off on any exit
led.connect();                                          % ~10–15 s; do it once
led.Channels(1).MaxCurrentmA = S.Doric.MaxCurrentmA(1); % refuse, never clamp
led.apply(doric.ChannelSettings.fromStruct(S.Doric.Ch1), ...
          doric.ChannelSettings.fromStruct(S.Doric.Ch2));
led.startAll();

% Stop the session if the device or the bridge fails at any point:
faultListener = addlistener(led, 'Faulted', @(~, evt) ...
    warning('Doric LED faulted: %s', evt.Reason));

% --- trial loop ------------------------------------------------------------
for currentTrial = 1:maxTrials
    % Reprogram only in the inter-trial window, never mid-stimulus:
    led.Channels(1).setCurrent(trialCurrent(currentTrial), 'Wait', false);
    ... SendStateMachine / RunStateMachine ...
end

% --- teardown (in order, before RunProtocol('Stop')) -------------------------
BpodSystem.Data.DoricLED = led.record();   % settings as sent, log, latencies
SaveBpodSessionData;
led.disconnect();                          % stop all → close → quit
```

Rules of thumb:

- **Connect once** at session setup; `connect` takes several seconds.
- **Emulator mode** decides the transport in one place; nothing else in the protocol branches.
- **Program between trials.** `ls_send_settings` may interrupt a running sequence.
- **Save `record()`** once per session (small struct), not per trial. Take it *before*
  `disconnect`, so the commanded state is still in it.
- **Limits belong to the protocol's settings.** Set `MaxCurrentmA` per channel from `S` at setup;
  a request above it is an error, so a settings typo stops the session instead of the animal's
  preparation.
- **Emulator mode** can drive the GUI too: `doric.app(led)` attaches to the protocol's object
  without taking ownership, which is a quick way to watch what the protocol commands.
- **Tear down before** `RunProtocol('Stop')` removes the protocol folder from the path, and turn
  the light off before releasing any device that drives its inputs.
- Refuse to start a session that needs light if `connect` fails. Do not fall back to simulation
  silently on a real rig.

## 3. Soft-code driven control (closed loop from the state machine)

```matlab
BpodSystem.SoftCodeHandlerFunction = 'DoricSoftCodeHandler';

function DoricSoftCodeHandler(code)
    led = getappdata(0, 'DoricLED');           % or a persistent/handle owned by the protocol
    switch code
        case 1, led.Channels(1).start('Wait', false);
        case 2, led.Channels(1).stop('Wait', false);
        case 3, led.stopAll('Wait', false);
    end
end
```

Non-blocking calls return immediately; outcomes arrive as `CommandCompleted` events and in
`led.log()`. `examples/example_bpod_softcode.m` is a runnable version of exactly this pattern
(the codes are replayed in a loop so it runs without Bpod).

A soft-code handler must never block: use `'Wait', false` everywhere, and do not call
`log()`/`stats()`/`record()` inside it. With `AutoPoll` on (the default), replies are processed by
a timer whenever MATLAB is idle or in a `pause`/`drawnow`, which includes Bpod's own trial loop; a
host that wants full control sets `AutoPoll = false` and calls `led.poll()` once per trial.

## 4. Other hosts

Any package can embed the device the same way: construct with an injected transport, `connect`
in its own setup, subscribe to `Faulted` to stop its loop, call `record()` into its own data
file, and `disconnect` in its teardown. The GUI can attach to the host's object for live checks
(`doric.gui.LightSourceApp(led)`) without taking ownership.

What the host never has to do: call `wait()` (the bridge pumps it), parse library text (it arrives
classified as `LibraryMessage` events and in `log()`), or switch the light off on a crash (the
bridge does it when MATLAB's pipe closes).
