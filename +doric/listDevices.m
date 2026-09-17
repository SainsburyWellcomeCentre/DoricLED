function devices = listDevices(varargin)
%LISTDEVICES Scan for Doric devices and return their port numbers.
%
%   devices = doric.listDevices() starts a temporary bridge, runs init, lists devices and quits.
%   It never opens a device and never changes an output. Takes about InitWaitMs + ListWaitMs.
%
%   devices = doric.listDevices('Transport', t, 'InitWaitMs', 5000, 'ListWaitMs', 500)
%
%   Returns a table with variables Port (double) and Name (string), parsed from the library's
%   "<name> (Port #<n>)" lines. An empty table means the library listed nothing.
%
%   Errors: as doric.LightSource/listDevices (bridge or library failures).
%
%   See also doric.LightSource, doric.transport.BridgeTransport

    lightSource = doric.LightSource(varargin{:});
    cleanup = onCleanup(@() delete(lightSource));
    devices = lightSource.listDevices();
    clear cleanup
end
