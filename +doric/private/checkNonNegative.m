function value = checkNonNegative(value, fieldName, errorId)
%CHECKNONNEGATIVE Validate a finite real scalar >= 0 and return it as double.
%
%   value = checkNonNegative(value, fieldName, errorId)
%
%   See also checkInteger

    if ~isnumeric(value) || ~isscalar(value) || ~isreal(value) || ~isfinite(value) || value < 0
        error(errorId, '%s must be a finite real number >= 0.', fieldName);
    end
    value = double(value);
end
