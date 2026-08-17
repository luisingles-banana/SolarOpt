function [idx, val, found] = findComponent(filename, filterCol, filterVal, targetCol, targetVal)
%FINDCOMPONENT Find the closest-matching row in a component database.
%   [IDX,VAL,FOUND] = FINDCOMPONENT(FILENAME,FILTERCOL,FILTERVAL,...
%   TARGETCOL,TARGETVAL) searches the CSV database at FILENAME for the
%   data row whose value in column TARGETCOL is closest to TARGETVAL,
%   optionally restricted to rows whose value in column FILTERCOL is
%   approximately equal to FILTERVAL (pass FILTERCOL = 0 to disable
%   filtering, e.g. when matching panels with no voltage constraint).
%
%   This function prefers the compiled C MEX module (component_db,
%   see /mex/component_db.c) and transparently falls back to an
%   equivalent pure-MATLAB implementation if the MEX file has not
%   been compiled on this machine, so the app still runs either way.
%
%   IDX   - 1-based data row index of the best match (0 if none found)
%   VAL   - the matched row's value in TARGETCOL
%   FOUND - true if a match was found, false otherwise

    if exist('component_db', 'file') == 3   % 3 = compiled MEX-file on path
        try
            [idx, val, found] = component_db(filename, filterCol, filterVal, targetCol, targetVal);
            found = logical(found);
            return
        catch mexErr
            warning('SolarOpt:findComponent:mexFailed', ...
                'component_db MEX call failed (%s). Falling back to MATLAB implementation.', ...
                mexErr.message);
        end
    end

    [idx, val, found] = findComponentMatlab(filename, filterCol, filterVal, targetCol, targetVal);
end

function [idx, val, found] = findComponentMatlab(filename, filterCol, filterVal, targetCol, targetVal)
    T = readtable(filename);
    idx = 0;
    val = 0;
    found = false;
    bestDiff = inf;

    for r = 1:height(T)
        tval = T{r, targetCol};
        if iscell(tval), tval = tval{1}; end
        if ~isnumeric(tval) || isnan(tval)
            continue
        end

        passFilter = true;
        if filterCol > 0
            fval = T{r, filterCol};
            if iscell(fval), fval = fval{1}; end
            if ~isnumeric(fval) || abs(fval - filterVal) > 0.5
                passFilter = false;
            end
        end
        if ~passFilter
            continue
        end

        d = abs(tval - targetVal);
        if d < bestDiff
            bestDiff = d;
            val = tval;
            idx = r;
            found = true;
        end
    end
end