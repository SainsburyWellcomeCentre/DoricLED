%EXAMPLE_BASIC Connect, run each mode on both channels, change intensity, disconnect.
%
%   Standalone walk-through of the package. It runs on the simulated device by default, so it
%   is safe to execute anywhere:
%
%       run('examples/example_basic.m')
%
%   Set useHardware = true (below) to drive the real LEDFLS_465_465. Check the fibers and the
%   preparation first: the currents here are low but the light is real.
%
%   See also doric.LightSource, doric.ChannelSettings, examples/example_closed_loop.m

useHardware = false;      % <-- true drives the real device
port = [];                % [] = the only listed device; or the Doric port number
maxCurrentmA = 200;       % refuse anything above this (per channel)

if useHardware
    transport = [];                                     % default: doric_bridge.exe
else
    transport = doric.transport.SimulatedTransport();    % no hardware
end

led = doric.LightSource('Port', port, 'Transport', transport, 'Verbose', true);
cleanup = onCleanup(@() delete(led));   % light off and device released on any exit

led.connect();
fprintf('State: %s (port %d, %s)\n', led.State, led.Port, led.DeviceName);

for k = 1:numel(led.Channels)
    led.Channels(k).MaxCurrentmA = maxCurrentmA;
end

% --- continuous wave on channel 1 -------------------------------------------------------------
led.Channels(1).apply(doric.ChannelSettings.cw(50));
led.Channels(1).start();
pause(0.5);
led.Channels(1).setCurrent(80);         % change the intensity while it runs
pause(0.5);
led.Channels(1).stop();

% --- follow an external TTL input on channel 2 -------------------------------------------------
led.Channels(2).apply(doric.ChannelSettings.extTTL(100));
led.Channels(2).start();
pause(0.2);

% --- a driver-generated pulse train, gated by the TTL input ------------------------------------
settings = doric.ChannelSettings.square(60, 1000, 500);   % 60 mA, 1 s period, 0.5 s on
settings.TriggerType = doric.TriggerType.Gated;
settings.TriggerMode = doric.TriggerMode.Restart;
settings.NbOfSeq = 0;                                     % 0 = repeat indefinitely
led.Channels(1).apply(settings);
fprintf('Channel 1 pending: %s\n', settings.describe());

% --- a Complex sequence and a Custom waveform --------------------------------------------------
segments = [ ...
    doric.ComplexSegment('Mode', 'Square', 'CurrentmA', 40, 'PeriodMs', 500, ...
        'TimeOnMs', 250, 'NbOfSeq', 3, 'NbOfPulsesPerSeq', 4), ...
    doric.ComplexSegment('Mode', 'Delay', 'PeriodMs', 1000, 'StartingDelayMs', 6000), ...
    doric.ComplexSegment('Mode', 'Triangle', 'CurrentmA', 80, 'PeriodMs', 1000, ...
        'TimeOnMs', 1000, 'StartingDelayMs', 7000)];
led.Channels(1).apply(doric.ChannelSettings.complex(segments));

ramp = round(linspace(0, 100, 250));                      % 250 points, 0 to 100 mA
led.Channels(2).apply(doric.ChannelSettings.custom(ramp, 1000));

% --- everything off, and a record of what was sent ---------------------------------------------
led.stopAll();
session = led.record();                                   % plain struct for a data file
disp(led.stats());

led.disconnect();
clear cleanup
