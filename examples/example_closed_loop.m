function session = example_closed_loop(useHardware, nTrials)
%EXAMPLE_CLOSED_LOOP Drive the light source from a control loop without blocking it.
%
%   session = example_closed_loop()               simulated device, 20 trials
%   session = example_closed_loop(true)           the real LEDFLS_465_465
%   session = example_closed_loop(false, 100)     simulated device, 100 trials
%
%   Shows the pattern any closed-loop host (a Bpod protocol, a behaviour rig, an acquisition
%   loop) should use: connect once, subscribe to the events, send commands with 'Wait', false,
%   and read the outcome from the events instead of waiting for it. Returns led.record(), the
%   struct to store with the experiment's data.
%
%   See also doric.LightSource, example_bpod_softcode, docs/bpod-integration.md

    if nargin < 1 || isempty(useHardware), useHardware = false; end
    if nargin < 2 || isempty(nTrials), nTrials = 20; end

    if useHardware
        transport = [];                                   % default: doric_bridge.exe
    else
        transport = doric.transport.SimulatedTransport();  % no hardware
    end

    led = doric.LightSource('Transport', transport);
    cleanup = onCleanup(@() delete(led));                  % light off on any exit

    faulted = false;
    failures = 0;
    listeners = [ ...
        addlistener(led, 'Faulted', @(~, evt) onFault(evt)), ...
        addlistener(led, 'CommandCompleted', @(~, evt) onCommand(evt))];

    led.connect();
    led.Channels(1).MaxCurrentmA = 300;
    led.Channels(1).apply(doric.ChannelSettings.extTTL(0));   % follows the rig's TTL input
    led.Channels(1).start();

    for trial = 1:nTrials
        if faulted
            warning('doric:example:faulted', 'Stopping: the light source faulted (%s).', ...
                led.FaultReason);
            break
        end

        % Whatever the experiment decides for this trial:
        currentmA = 50 + 10 * mod(trial, 5);

        % Non-blocking: returns after one pipe write, the outcome arrives as an event.
        led.Channels(1).setCurrent(currentmA, 'Wait', false);

        % ... run the trial here (state machine, acquisition, analysis) ...
        pause(0.02);

        % AutoPoll (a timer) processes replies on its own; hosts that switch it off poll here.
        led.poll();
    end

    led.stopAll();
    fprintf('%d trials, %d failed commands, commanded %d mA\n', trial, failures, ...
        led.Channels(1).CommandedCurrentmA);
    disp(led.stats());

    session = led.record();          % save this with the experiment's data
    delete(listeners);
    led.disconnect();
    clear cleanup

    function onFault(~)
        faulted = true;
    end

    function onCommand(evt)
        if ~isempty(evt.Ok) && ~evt.Ok
            failures = failures + 1;
        end
    end
end
