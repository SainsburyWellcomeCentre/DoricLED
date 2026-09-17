classdef DoricEventData < event.EventData
%DORICEVENTDATA Event data for doric.LightSource and transport events.
%
%   Fields are filled according to the event; unused ones stay empty.
%
%   StateChanged      OldState, NewState, Reason
%   CommandCompleted  Id, Command, Channel, Ok, Code, Message, LatencyMs
%   LibraryMessage    Id, Text, Severity, LibrarySource
%   Faulted           Reason, NewState
%   MessageReceived   Message (transport message struct)
%
%   See also doric.LightSource, doric.transport.Transport

    properties
        Id = []
        Command = ''
        Channel = []
        Ok = []
        Code = ''
        Message = ''
        LatencyMs = NaN
        Text = ''
        Severity = ''
        LibrarySource = ''
        OldState = ''
        NewState = ''
        Reason = ''
    end
end
