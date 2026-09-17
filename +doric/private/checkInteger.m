function value = checkInteger(value, lo, hi, fieldName, errorId)
%CHECKINTEGER Validate a real integer scalar in [lo, hi] and return it as double.
%
%   value = checkInteger(value, lo, hi, fieldName, errorId)
%   Errors with errorId when value is not a finite integer scalar within the range. Values are
%   never clamped or rounded.
%
%   See also checkNonNegative

    if ~(isnumeric(value) || islogical(value)) || ~isscalar(value) || ~isreal(value)
        error(errorId, '%s must be a real numeric scalar.', fieldName);
    end
    value = double(value);
    if ~isfinite(value) || value ~= fix(value) || value < lo || value > hi
        error(errorId, '%s must be an integer in [%d, %d]; got %g.', fieldName, lo, hi, value);
    end
end
