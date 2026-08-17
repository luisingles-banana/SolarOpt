function [idx, val, found] = findComponent(filename, filterCol, filterVal, targetCol, targetVal)
% Finds the closest-matching row in a CSV component database.

    % Default output values
    idx = 0;
    val = 0;
    found = false;

    % Verify file exists
    if ~isfile(filename)
        return;
    end

    % Read numeric CSV data (automatically skips header text)
    data = readmatrix(filename);
    if isempty(data)
        return;
    end

    % Extract target column values
    tvals = data(:, targetCol);

    % Apply optional filtering (e.g., voltage match)
    if filterCol > 0
        fvals = data(:, filterCol);
        passFilter = abs(fvals - filterVal) <= 0.5;
    else
        passFilter = true(size(data, 1), 1); % Keep all rows
    end

    % Compute absolute differences and mask out filtered rows
    diffs = abs(tvals - targetVal);
    diffs(~passFilter) = Inf; % Set non-matching rows to Infinity

    % Find the row index with the smallest difference
    [bestDiff, bestIdx] = min(diffs);

    % Return match results
    if ~isinf(bestDiff)
        idx = bestIdx;
        val = tvals(bestIdx);
        found = true;
    end
end