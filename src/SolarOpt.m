classdef SolarOpt < matlab.apps.AppBase

    % --- UI COMPONENTS ---
    properties (Access = public)
        UIFigure                   matlab.ui.Figure
        TabGroup                   matlab.ui.container.TabGroup
        SizingTab                  matlab.ui.container.Tab
        ChartsTab                  matlab.ui.container.Tab
        
        % Inputs
        DailyEnergyEditField       matlab.ui.control.NumericEditField
        LoadProfileDropDown        matlab.ui.control.DropDown
        SystemVoltageDropDown      matlab.ui.control.DropDown
        DerateFactorEditField      matlab.ui.control.NumericEditField
        PSHEditField               matlab.ui.control.NumericEditField
        PanelWattageEditField      matlab.ui.control.NumericEditField
        InverterEffEditField       matlab.ui.control.NumericEditField
        AutonomyEditField          matlab.ui.control.NumericEditField
        DoDEditField               matlab.ui.control.NumericEditField
        BattEffEditField           matlab.ui.control.NumericEditField
        
        % Actions & Outputs
        CalculateButton            matlab.ui.control.Button
        ResultsTextArea            matlab.ui.control.TextArea
        
        % Plotting Axes
        GenerationAxes             matlab.ui.control.UIAxes
        SOCAxes                    matlab.ui.control.UIAxes
        DistributionAxes           matlab.ui.control.UIAxes
        ComparisonAxes             matlab.ui.control.UIAxes
    end

    % --- PRIVATE CALCULATION & PLOTTING METHODS ---
    methods (Access = private)

        % Main Sizing Algorithm
        function results = computeSizing(app)
            % 1. Read values directly from UI fields
            Eday_kWh     = app.DailyEnergyEditField.Value;
            loadProfile  = app.LoadProfileDropDown.Value;
            Vsys         = str2double(app.SystemVoltageDropDown.Value);
            derate       = app.DerateFactorEditField.Value / 100; % Convert % to decimal
            PSH          = app.PSHEditField.Value;
            panelTargetW = app.PanelWattageEditField.Value;
            invEff       = app.InverterEffEditField.Value / 100;
            autonomyDays = app.AutonomyEditField.Value;
            DoD          = app.DoDEditField.Value / 100;
            battEff      = app.BattEffEditField.Value / 100;

            % Input Validation
            if Eday_kWh <= 0 || PSH <= 0 || panelTargetW <= 0 || isnan(Vsys) || Vsys <= 0
                uialert(app.UIFigure, 'Please enter positive numeric values for all fields.', 'Invalid Input');
                results = [];
                return;
            end

            Eday_Wh = Eday_kWh * 1000;

            % 2. Solar Array Sizing
            requiredArrayW = Eday_Wh / (PSH * derate * invEff);
            numPanelsIdeal = ceil(requiredArrayW / panelTargetW);

            % Database lookup with fallback
            dataFolder = app.resolveDataFolder();
            panelDb    = fullfile(dataFolder, 'panel_database.csv');
            matchedPanel = table();
            actualPanelW = panelTargetW;

            if isfile(panelDb)
                pTable = readtable(panelDb);
                [~, minIdx] = min(abs(pTable.WattagePeak - panelTargetW));
                matchedPanel = pTable(minIdx, :);
                actualPanelW = matchedPanel.WattagePeak;
            end
            actualArrayW = numPanelsIdeal * actualPanelW;

            % 3. Battery Bank Sizing
            requiredBankWh = (Eday_Wh * autonomyDays) / (DoD * battEff);
            requiredBankAh = requiredBankWh / Vsys;

            batteryDb = fullfile(dataFolder, 'battery_database.csv');
            matchedBattery = table();
            actualBankAh = requiredBankAh;

            if isfile(batteryDb)
                bTable = readtable(batteryDb);
                validRows = bTable(bTable.Voltage == Vsys, :);
                if ~isempty(validRows)
                    [~, minIdx] = min(abs(validRows.CapacityAh - requiredBankAh));
                    matchedBattery = validRows(minIdx, :);
                    numBatteriesParallel = ceil(requiredBankAh / matchedBattery.CapacityAh);
                    actualBankAh = numBatteriesParallel * matchedBattery.CapacityAh;
                else
                    numBatteriesParallel = 1;
                end
            else
                numBatteriesParallel = 1;
            end
            actualBankWh = actualBankAh * Vsys;
            overallEff   = derate * invEff * battEff * 100;

            % 4. 24-Hour Simulation Profile
            hours = 0:0.5:24;
            dayLength = min(max(PSH * 1.6, 6), 14);
            sunrise   = 12 - dayLength / 2;
            sunset    = 12 + dayLength / 2;
            
            genProfile = zeros(size(hours));
            inDay = hours >= sunrise & hours <= sunset;
            genProfile(inDay) = actualArrayW * derate * ...
                sin(pi * (hours(inDay) - sunrise) / (sunset - sunrise)) .^ 1.2;

            % Load Profile Selection
            switch loadProfile
                case 'Residential'
                    loadShape = 0.5 + 0.35 * exp(-((hours - 7).^2) / 8) + 0.55 * exp(-((hours - 20).^2) / 10);
                case 'Commercial'
                    loadShape = 0.25 + 0.75 * (hours >= 8 & hours <= 18);
                case 'Industrial'
                    loadShape = 0.8 + 0.15 * sin(2 * pi * hours / 24);
                otherwise
                    loadShape = ones(size(hours)) * 0.6;
            end
            
            avgLoadW   = Eday_Wh / 24;
            loadPowerW = avgLoadW * (loadShape / mean(loadShape));

            % 5. Battery State of Charge (SOC)
            dt = hours(2) - hours(1);
            capWh = max(actualBankWh, 1);
            soc = zeros(size(hours));
            soc(1) = 80; % Starting SOC
            netPowerW = genProfile - loadPowerW;
            minSOC = 100 * (1 - DoD);

            for k = 2:length(hours)
                if netPowerW(k) >= 0
                    dSOC = (netPowerW(k) * dt) / capWh * 100 * sqrt(battEff);
                else
                    dSOC = (netPowerW(k) * dt) / capWh * 100 / sqrt(battEff);
                end
                soc(k) = min(max(soc(k-1) + dSOC, minSOC), 100);
            end

            % Energy breakdown
            usefulEnergyWh = Eday_Wh;
            inverterLossWh = max(Eday_Wh / invEff - Eday_Wh, 0);
            derateLossWh   = max(requiredArrayW * PSH - Eday_Wh / invEff, 0);

            % Pack outputs into a struct
            results = struct( ...
                'requiredArrayW', requiredArrayW, 'numPanelsIdeal', numPanelsIdeal, ...
                'matchedPanel', matchedPanel, 'actualArrayW', actualArrayW, ...
                'panelTargetW', panelTargetW, 'requiredBankWh', requiredBankWh, ...
                'requiredBankAh', requiredBankAh, 'matchedBattery', matchedBattery, ...
                'numBatteriesParallel', numBatteriesParallel, 'actualBankAh', actualBankAh, ...
                'actualBankWh', actualBankWh, 'overallEff', overallEff, 'Vsys', Vsys, ...
                'DoDpercent', app.DoDEditField.Value, 'hours', hours, 'genProfile', genProfile, ...
                'loadPowerW', loadPowerW, 'soc', soc, 'usefulEnergyWh', usefulEnergyWh, ...
                'inverterLossWh', inverterLossWh, 'derateLossWh', derateLossWh ...
            );
        end

        % Update Text Summary Window
        function updateResultsText(app, r)
            out = {};
            out{end+1} = '=== SOLAR ARRAY SIZING ===';
            out{end+1} = sprintf('Required Array Power: %.1f W', r.requiredArrayW);
            out{end+1} = sprintf('Panels Needed: %d (%.0f W target)', r.numPanelsIdeal, r.panelTargetW);
            if ~isempty(r.matchedPanel)
                out{end+1} = sprintf('Database Match: %s %s (%.0f W)', ...
                    r.matchedPanel.Manufacturer{1}, r.matchedPanel.Model{1}, r.matchedPanel.WattagePeak);
            end
            
            out{end+1} = '';
            out{end+1} = '=== BATTERY BANK SIZING ===';
            out{end+1} = sprintf('Required Capacity: %.1f Ah @ %.0f V (%.2f kWh)', ...
                r.requiredBankAh, r.Vsys, r.requiredBankWh/1000);
            if ~isempty(r.matchedBattery)
                out{end+1} = sprintf('Database Match: %s %s (%.0f Ah)', ...
                    r.matchedBattery.Manufacturer{1}, r.matchedBattery.Model{1}, r.matchedBattery.CapacityAh);
            end
            
            out{end+1} = '';
            out{end+1} = sprintf('Overall System Efficiency: %.1f%%', r.overallEff);
            app.ResultsTextArea.Value = out;
        end

        % Plot Calculations onto Charts
        function updateCharts(app, r)
            % Chart 1: PV Generation vs Load Demand
            cla(app.GenerationAxes);
            plot(app.GenerationAxes, r.hours, r.genProfile, 'LineWidth', 2);
            hold(app.GenerationAxes, 'on');
            plot(app.GenerationAxes, r.hours, r.loadPowerW, '--', 'LineWidth', 1.5);
            hold(app.GenerationAxes, 'off');
            legend(app.GenerationAxes, {'PV Output', 'Load'}, 'Location', 'best');
            title(app.GenerationAxes, 'Solar Power Generation vs Load');
            grid(app.GenerationAxes, 'on');

            % Chart 2: State of Charge (SOC)
            cla(app.SOCAxes);
            plot(app.SOCAxes, r.hours, r.soc, 'LineWidth', 2, 'Color', [0.2 0.6 0.3]);
            yline(app.SOCAxes, 100 - r.DoDpercent, ':', 'Min Allowed SOC');
            title(app.SOCAxes, 'Battery State of Charge (24h)');
            grid(app.SOCAxes, 'on');

            % Chart 3: Energy Losses Pie Chart
            cla(app.DistributionAxes);
            pie(app.DistributionAxes, ...
                [r.usefulEnergyWh, r.inverterLossWh, r.derateLossWh], ...
                {'Useful Energy', 'Inverter Loss', 'System Loss'});
            title(app.DistributionAxes, 'Daily Energy Breakdown');

            % Chart 4: Sizing Comparisons
            cla(app.ComparisonAxes);
            cats = categorical({'Array Output (W)', 'Battery Capacity (Ah)'});
            bar(app.ComparisonAxes, cats, [[r.requiredArrayW, r.requiredBankAh]; [r.actualArrayW, r.actualBankAh]]');
            legend(app.ComparisonAxes, {'Required', 'Actual Matched'}, 'Location', 'best');
            title(app.ComparisonAxes, 'Required vs. Actual Sizing');
            grid(app.ComparisonAxes, 'on');
        end

        % Helper function to resolve external folder paths
        function p = resolveDataFolder(~)
            p = fullfile(pwd, 'data');
            if ~isfolder(p)
                p = pwd; 
            end
        end
    end

    % --- CALLBACKS & INITIALIZATION ---
    methods (Access = private)

        function startupFcn(app)
            % Setup dropdown choices
            app.LoadProfileDropDown.Items = {'Residential', 'Commercial', 'Industrial'};
            app.SystemVoltageDropDown.Items = {'12', '24', '48'};
            
            % Set sensible default values
            app.DailyEnergyEditField.Value  = 5;
            app.DerateFactorEditField.Value = 80;
            app.PSHEditField.Value          = 4.5;
            app.PanelWattageEditField.Value = 350;
            app.InverterEffEditField.Value  = 95;
            app.AutonomyEditField.Value     = 1;
            app.DoDEditField.Value          = 50;
            app.BattEffEditField.Value      = 90;

            app.ResultsTextArea.Value = {'Enter parameters and click "Calculate" to begin.'};
        end

        function CalculateButtonPushed(app, ~)
            r = app.computeSizing();
            if isempty(r)
                return; 
            end
            app.updateResultsText(r);
            app.updateCharts(r);
            app.TabGroup.SelectedTab = app.ChartsTab; % Automatically switch to plots
        end

        function createComponents(app)
            % Figure Window
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 950 680];
            app.UIFigure.Name = 'SolarOpt - Solar System Designer';

            % Main Layout Tabs
            app.TabGroup = uitabgroup(app.UIFigure);
            app.TabGroup.Position = [10 10 930 660];
            
            app.SizingTab = uitab(app.TabGroup, 'Title', 'System Sizing');
            app.ChartsTab = uitab(app.TabGroup, 'Title', 'Simulation & Charts');

            % --- SIZING TAB LAYOUT (Grid Managed) ---
            mainGrid = uigridlayout(app.SizingTab, [1, 2]);
            mainGrid.ColumnWidth = {400, '1fr'};

            % Input Fields Grid (11 rows x 2 cols)
            inputGrid = uigridlayout(mainGrid, [11, 2]);
            inputGrid.RowHeight = repmat({30}, 1, 11);
            inputGrid.ColumnWidth = {'1fr', 120};

            % Input Component Initializations
            uilabel(inputGrid, 'Text', 'Daily Energy (kWh):');
            app.DailyEnergyEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Load Profile:');
            app.LoadProfileDropDown = uidropdown(inputGrid);

            uilabel(inputGrid, 'Text', 'System Voltage (V):');
            app.SystemVoltageDropDown = uidropdown(inputGrid);

            uilabel(inputGrid, 'Text', 'Derate Factor (%):');
            app.DerateFactorEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Peak Sun Hours (PSH):');
            app.PSHEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Target Panel (W):');
            app.PanelWattageEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Inverter Efficiency (%):');
            app.InverterEffEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Autonomy (Days):');
            app.AutonomyEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Depth of Discharge (%):');
            app.DoDEditField = uieditfield(inputGrid, 'numeric');

            uilabel(inputGrid, 'Text', 'Battery Efficiency (%):');
            app.BattEffEditField = uieditfield(inputGrid, 'numeric');

            % Calculate Button
            app.CalculateButton = uibutton(inputGrid, 'push', 'Text', 'Calculate');
            app.CalculateButton.FontWeight = 'bold';
            app.CalculateButton.ButtonPushedFcn = createCallbackFcn(app, @CalculateButtonPushed, true);
            app.CalculateButton.Layout.Column = [1, 2]; % Span both columns

            % Text Results Box
            app.ResultsTextArea = uitextarea(mainGrid, 'Editable', 'off');

            % --- CHARTS TAB LAYOUT (2x2 Grid) ---
            chartsGrid = uigridlayout(app.ChartsTab, [2, 2]);
            
            app.GenerationAxes   = uiaxes(chartsGrid);
            app.SOCAxes          = uiaxes(chartsGrid);
            app.DistributionAxes = uiaxes(chartsGrid);
            app.ComparisonAxes   = uiaxes(chartsGrid);

            app.UIFigure.Visible = 'on';
        end
    end

    % --- APP CREATION AND CLEANUP ---
    methods (Access = public)
        function app = SolarOpt
            createComponents(app)
            registerApp(app, app.UIFigure)
            runStartupFcn(app, @startupFcn)
            if nargout == 0
                clear app
            end
        end

        function delete(app)
            delete(app.UIFigure)
        end
    end
end