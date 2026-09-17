function value = checkLogical(value, fieldName, errorId)
%CHECKLOGICAL Validate a logical-like scalar (true/false/0/1) and return it as logical.
%
%   value = checkLogical(value, fieldName, errorId)
%
%   See also checkInteger

    if ~(islogical(value) || isnumeric(value)) || ~isscalar(value) || ...
            ~(double(value) == 0 || double(value) == 1)
        error(errorId, '%s must be true or false.', fieldName);
    end
    value = logical(value);
end
