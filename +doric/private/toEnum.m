function value = toEnum(className, value, fieldName, errorId)
%TOENUM Convert an enumeration member, its name or its numeric value to a scalar member.
%
%   value = toEnum(className, value, fieldName, errorId)
%       className  enumeration class, e.g. 'doric.Mode'
%       value      member, name (char/string, case-insensitive) or integer vendor value
%       fieldName  used in the error message
%       errorId    error identifier raised when value is not a member
%
%   See also doric.ChannelSettings, doric.ComplexSegment

    if isa(value, className) && isscalar(value)
        return
    end
    members = enumeration(className);
    if (ischar(value) && (isrow(value) || isempty(value))) || (isstring(value) && isscalar(value))
        names = arrayfun(@char, members, 'UniformOutput', false);
        match = strcmpi(names, char(value));
        if any(match)
            value = members(find(match, 1));
            return
        end
    elseif (isnumeric(value) || islogical(value)) && isscalar(value)
        match = double(members) == double(value);
        if any(match)
            value = members(find(match, 1));
            return
        end
    end
    names = strjoin(arrayfun(@(m) sprintf('%s(%d)', char(m), int32(m)), members, ...
        'UniformOutput', false), ', ');
    error(errorId, '%s must be a %s member, name or value: %s.', fieldName, className, names);
end
