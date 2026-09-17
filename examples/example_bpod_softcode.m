function session = example_bpod_softcode(useHardware)
%EXAMPLE_BPOD_SOFTCODE Soft-code handler pattern for Bpod protocols (and any command dispatcher).
%
%   session = example_bpod_softcode()       simulated device; prints what each code does
%   session = example_bpod_softcode(true)   the real LEDFLS_465_465
%
%   The package ships no protocol-specific code. This example shows the generic pieces a Bpod
%   protocol needs: build the light source once (choosing the transport from EmulatorMode),
%   keep the handle where the soft-code handler can reach it, map soft codes to non-blocking
%   commands, and store led.record() with the session data. Here the codes are replayed in a
%   loop instead of coming from a state machine, so the file runs without Bpod.
%
%   In a protocol:
%       BpodSystem.SoftCodeHandlerFunction = 'DoricSoftCodeHandler';
%   with a DoricSoftCodeHandler.m on the path holding the switch below.
%
%   See also doric.LightSource, example_closed_loop, docs/bpod-integration.md

    if nargin < 1 || isempty(useHardware), useHardware = false; end

    % --- protocol setup (once, before the first trial) ----------------------------------------
    % In a protocol this branch is:  if BpodSystem.EmulatorMode, transport = Simulated...
    if useHardware
        transport = [];
    else
        transport = doric.transport.SimulatedTransport();
    end
    led = doric.LightSource('Transport', transport);
    cleanup = onCleanup(@() delete(led));      % light off however the protocol ends
    led.connect();

    led.Channels(1).MaxCurrentmA = 300;        % from the protocol's settings (S.Doric...)
    led.Channels(2).MaxCurrentmA = 300;
    led.apply(doric.ChannelSettings.cw(80), doric.ChannelSettings.extTTL(120));

    % The handler needs the object; a protocol can also keep it in a persistent variable or in
    % BpodSystem.PluginObjects. setappdata(0, ...) works from any function on any path.
    setappdata(0, 'DoricLED', led);
    appdataCleanup = onCleanup(@() rmappdata(0, 'DoricLED'));

    % --- trial loop ----------------------------------------------------------------------------
    % A real protocol sends and runs a state machine here; the soft codes arrive from it.
    for trial = 1:5
        for code = [1 3 2 4 9]
            doricSoftCodeHandler(code);
            pause(0.01);
        end
        led.poll();                            % harmless: AutoPoll already does this
    end

    % --- teardown (before RunProtocol('Stop')) -------------------------------------------------
    session = led.record();                    % BpodSystem.Data.DoricLED = session
    led.disconnect();
    clear appdataCleanup cleanup
end

function doricSoftCodeHandler(code)
%DORICSOFTCODEHANDLER Map a Bpod soft code to a light-source command (never blocks).
%   Copy this into DoricSoftCodeHandler.m in the protocol folder and set
%   BpodSystem.SoftCodeHandlerFunction = 'DoricSoftCodeHandler'.
    led = getappdata(0, 'DoricLED');
    if isempty(led) || ~isvalid(led)
        return
    end
    switch code
        case 1, led.Channels(1).start('Wait', false);
        case 2, led.Channels(1).stop('Wait', false);
        case 3, led.Channels(2).start('Wait', false);
        case 4, led.Channels(2).stop('Wait', false);
        case 5, led.Channels(1).setCurrent(50, 'Wait', false);
        case 9, led.stopAll('Wait', false);
        otherwise
            warning('doric:example:unknownSoftCode', 'Unhandled soft code %d.', code);
    end
end
