function opts = commandOptions(opts, args, component)
%COMMANDOPTIONS Parse name-value options of a device command without inputParser (hot path).
%
%   opts = commandOptions(opts, args, component)
%       opts       struct of defaults; its field names are the accepted option names
%       args       cell array of name-value pairs (case-insensitive names)
%       component  used in the error identifier doric:<component>:invalidOption
%
%   See also doric.Channel, doric.LightSource

    if mod(numel(args), 2) ~= 0
        error(['doric:' component ':invalidOption'], 'Options must be name-value pairs.');
    end
    names = fieldnames(opts);
    for k = 1:2:numel(args)
        name = args{k};
        if ~(ischar(name) || (isstring(name) && isscalar(name)))
            error(['doric:' component ':invalidOption'], 'Option names must be text.');
        end
        match = strcmpi(names, char(name));
        if ~any(match)
            error(['doric:' component ':invalidOption'], 'Unknown option "%s". Valid: %s.', ...
                char(name), strjoin(names, ', '));
        end
        opts.(names{match}) = args{k + 1};
    end
end
