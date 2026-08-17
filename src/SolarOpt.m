classdef SolarOpt < matlab.apps.AppBase

    % UI COMPONENTS
    properties (Access = public)
        UIFigure                     matlab.ui.Figure
        TabGroup                     matlab.ui.container.TabGroup
        SizingTab                    matlab.ui.container.Tab
        ChartsTab                    matlab.ui.container.Tab
        
        % Input Controls
        SystemModeDropDownLabel      matlab.ui.control.Label
        SystemModeDropDown           matlab.ui.control.DropDown
        DailyEnergyEditFieldLabel   matlab.ui.control.Label
        DailyEnergyEditField        matlab.ui.control.NumericEditField
        LoadProfileDropDownLabel    matlab.ui.control.Label
        LoadProfileDropDown         matlab.ui.control.DropDown
        SystemVoltageDropDownLabel  matlab.ui.control.Label
        SystemVoltageDropDown       matlab.ui.control.DropDown
        DerateFactorEditFieldLabel  matlab.ui.control.Label
        DerateFactorEditField       matlab.ui.control.NumericEditField
        PSHEditFieldLabel           matlab.ui.control.Label
        PSHEditField                matlab.ui.control.NumericEditField
        PanelWattageEditFieldLabel  matlab.ui.control.Label
        PanelWattageEditField       matlab.ui.control.NumericEditField
        NumberOfPanelsEditFieldLabel matlab.ui.control.Label
        NumberOfPanelsEditField      matlab.ui.control.NumericEditField
        InverterEffEditFieldLabel   matlab.ui.control.Label
        InverterEffEditField        matlab.ui.control.NumericEditField
        AutonomyEditFieldLabel      matlab.ui.control.Label
        AutonomyEditField           matlab.ui.control.NumericEditField
        DoDEditFieldLabel           matlab.ui.control.Label
        DoDEditField                matlab.ui.control.NumericEditField
        BattEffEditFieldLabel       matlab.ui.control.Label
        BattEffEditField            matlab.ui.control.NumericEditField
        
        % Actions & Outputs
        CalculateButton             matlab.ui.control.Button
        ResultsTextArea             matlab.ui.control.TextArea

        % Plotting Axes
        GenerationAxes              matlab.ui.control.UIAxes
        SOCAxes                     matlab.ui.control.UIAxes
        DistributionAxes            matlab.ui.control.UIAxes
        ComparisonAxes              matlab.ui.control.UIAxes
    end

    properties (Access = private)
        LastResults = [] % Holds output structure from the last successful calculation
    end

    % CALCULATION & PLOTTING METHODS
    methods (Access = private)
        
        % Main Sizing Algorithm
        function results = computeSizing(app)
            % Read values directly from UI fields
            daily_energy_kwh  = app.DailyEnergyEditField.Value;
            load_profile_type = app.LoadProfileDropDown.Value;
            system_voltage_v  = str2double(app.SystemVoltageDropDown.Value);
            derate_factor     = app.DerateFactorEditField.Value / 100;
            sun_hours_psh     = app.PSHEditField.Value;
            target_panel_w    = app.PanelWattageEditField.Value;
            inverter_eff      = app.InverterEffEditField.Value / 100;
            autonomy_days     = app.AutonomyEditField.Value;
            depth_of_discharge= app.DoDEditField.Value / 100;
            battery_eff       = app.BattEffEditField.Value / 100;

            % Input Validation
            if daily_energy_kwh <= 0 || sun_hours_psh <= 0 || target_panel_w <= 0 || isnan(system_voltage_v) || system_voltage_v <= 0
                uialert(app.UIFigure, ...
                    'Please enter positive numbers for all required energy, panel, and voltage inputs.', ...
                    'Input Error');
                results = [];
                return;
            end

            daily_energy_wh = daily_energy_kwh * 1000;

            % Solar Array Sizing
            required_array_w = daily_energy_wh / (sun_hours_psh * derate_factor * inverter_eff);
            
            data_folder = app.resolveDataFolder();
            panel_db_file = fullfile(data_folder, 'panel_database.csv');
            battery_db_file = fullfile(data_folder, 'battery_database.csv');

            % Read CSV databases (if present)
            if isfile(panel_db_file)
                panel_table = readtable(panel_db_file);
            else
                panel_table = table();
            end

            mode_selection = app.SystemModeDropDown.Value;
            matched_panel = table();

            if strcmp(mode_selection, 'I need panels/battery')
                num_panels_needed = ceil(required_array_w / target_panel_w);
                
                % Check database match
                if ~isempty(panel_table) && ismember('WattagePeak', panel_table.Properties.VariableNames)
                    [~, closest_idx] = min(abs(panel_table.WattagePeak - target_panel_w));
                    matched_panel = panel_table(closest_idx, :);
                    actual_panel_w = matched_panel.WattagePeak;
                else
                    actual_panel_w = target_panel_w;
                end
                actual_array_w = num_panels_needed * actual_panel_w;

            else % Mode: 'I have panels'
                num_panels_needed = app.NumberOfPanelsEditField.Value;
                if num_panels_needed <= 0 || target_panel_w <= 0
                    uialert(app.UIFigure, 'Please specify a valid number of existing panels and panel wattage.', 'Input Error');
                    results = [];
                    return;
                end
                actual_panel_w = target_panel_w;
                actual_array_w = num_panels_needed * actual_panel_w;
            end

            % Battery Bank Sizing
            required_bank_wh = (daily_energy_wh * autonomy_days) / (depth_of_discharge * battery_eff);
            required_bank_ah = required_bank_wh / system_voltage_v;

            matched_battery = table();
            if isfile(battery_db_file)
                battery_table = readtable(battery_db_file);
                if ~isempty(battery_table) && ismember('CapacityAh', battery_table.Properties.VariableNames)
                    [~, batt_idx] = min(abs(battery_table.CapacityAh - required_bank_ah));
                    matched_battery = battery_table(batt_idx, :);
                    num_batteries_parallel = ceil(required_bank_ah / matched_battery.CapacityAh);
                    actual_bank_ah = num_batteries_parallel * matched_battery.CapacityAh;
                else
                    num_batteries_parallel = 1;
                    actual_bank_ah = required_bank_ah;
                end
            else
                num_batteries_parallel = 1;
                actual_bank_ah = required_bank_ah;
            end

            actual_bank_wh = actual_bank_ah * system_voltage_v;
            overall_efficiency = derate_factor * inverter_eff * battery_eff * 100;

            % 24-Hour Simulation Profile
            time_hours = 0:0.5:24;
            day_length_hours = min(max(sun_hours_psh * 1.6, 6), 14);
            sunrise_hour = 12 - (day_length_hours / 2);
            sunset_hour = 12 + (day_length_hours / 2);

            % Solar profile calculation
            generation_profile_w = zeros(size(time_hours));
            daytime_indices = (time_hours >= sunrise_hour) & (time_hours <= sunset_hour);
            solar_curve = sin(pi * (time_hours(daytime_indices) - sunrise_hour) / (sunset_hour - sunrise_hour)) .^ 1.2;
            generation_profile_w(daytime_indices) = actual_array_w * derate_factor * solar_curve;

            % Load Profile Selection
            switch load_profile_type
                case 'Residential'
                    load_shape = 0.5 + 0.35 * exp(-((time_hours - 7).^2) / 8) + 0.55 * exp(-((time_hours - 20).^2) / 10);
                case 'Commercial'
                    load_shape = 0.25 + 0.75 * (time_hours >= 8 & time_hours <= 18);
                case 'Industrial'
                    load_shape = 0.8 + 0.15 * sin(2 * pi * time_hours / 24);
                otherwise
                    load_shape = ones(size(time_hours)) * 0.6;
            end

            load_shape = max(load_shape, 0.15);
            average_load_w = daily_energy_wh / 24;
            load_power_w = average_load_w * (load_shape / mean(load_shape));

            % Battery State of Charge (SOC) Simulation
            time_step = time_hours(2) - time_hours(1);
            battery_capacity_wh = max(actual_bank_wh, 1);
            battery_soc = zeros(size(time_hours));
            battery_soc(1) = 80; % Initial state of charge (80%)

            net_power_w = generation_profile_w - load_power_w;
            minimum_soc = 100 * (1 - depth_of_discharge);

            for step = 2:length(time_hours)
                if net_power_w(step) >= 0
                    soc_change = (net_power_w(step) * time_step) / battery_capacity_wh * 100 * sqrt(battery_eff);
                else
                    soc_change = (net_power_w(step) * time_step) / battery_capacity_wh * 100 / sqrt(battery_eff);
                end
                
                new_soc = battery_soc(step-1) + soc_change;
                battery_soc(step) = min(max(new_soc, minimum_soc), 100);
            end

            % Energy breakdown
            useful_energy_wh = daily_energy_wh;
            inverter_loss_wh = max((daily_energy_wh / inverter_eff) - daily_energy_wh, 0);
            derate_loss_wh   = max((required_array_w * sun_hours_psh) - (daily_energy_wh / inverter_eff), 0);

            % Output Structure Creation
            results = struct();
            results.requiredArrayW        = required_array_w;
            results.numPanelsIdeal        = num_panels_needed;
            results.matchedPanel          = matched_panel;
            results.actualArrayW          = actual_array_w;
            results.panelTargetW          = target_panel_w;
            results.requiredBankWh        = required_bank_wh;
            results.requiredBankAh        = required_bank_ah;
            results.matchedBattery        = matched_battery;
            results.numBatteriesParallel  = num_batteries_parallel;
            results.actualBankAh          = actual_bank_ah;
            results.actualBankWh          = actual_bank_wh;
            results.overallEff            = overall_efficiency;
            results.Vsys                  = system_voltage_v;
            results.DoDpercent            = depth_of_discharge * 100;
            results.hours                 = time_hours;
            results.genProfile            = generation_profile_w;
            results.loadPowerW            = load_power_w;
            results.soc                   = battery_soc;
            results.usefulEnergyWh        = useful_energy_wh;
            results.inverterLossWh        = inverter_loss_wh;
            results.derateLossWh          = derate_loss_wh;
        end

        % Update Text Summary Window
        function updateResultsText(app, r)
            lines = {};
            lines{end+1} = '=== SOLAR ARRAY SIZING ===';
            lines{end+1} = sprintf('Required Solar Output: %.1f W', r.requiredArrayW);

            if strcmp(app.SystemModeDropDown.Value, 'I have panels')
                lines{end+1} = sprintf('Existing Panels (%.0f W each): %d panels', r.panelTargetW, r.numPanelsIdeal);
                lines{end+1} = sprintf('Current Solar Array Capacity: %.1f W', r.actualArrayW);
                
                if r.actualArrayW < r.requiredArrayW
                    extra_panels = ceil((r.requiredArrayW - r.actualArrayW) / r.panelTargetW);
                    lines{end+1} = sprintf('Additional Panels Needed: %d', extra_panels);
                else
                    lines{end+1} = 'Status: Existing panels are sufficient.';
                end
            else
                lines{end+1} = sprintf('Panels Required (%.0f W target): %d panels', r.panelTargetW, r.numPanelsIdeal);
                if ~isempty(r.matchedPanel) && ismember('Manufacturer', r.matchedPanel.Properties.VariableNames)
                    lines{end+1} = sprintf('Database Match: %s %s (%.0f W)', ...
                        r.matchedPanel.Manufacturer{1}, r.matchedPanel.Model{1}, r.matchedPanel.WattagePeak);
                else
                    lines{end+1} = 'Database Match: None found (Using generic parameters).';
                end
                lines{end+1} = sprintf('Actual System Array Output: %.1f W', r.actualArrayW);
            end

            lines{end+1} = '';
            lines{end+1} = '=== BATTERY BANK SIZING ===';
            lines{end+1} = sprintf('Required Bank Capacity: %.1f Ah @ %.0f V (%.2f kWh)', ...
                r.requiredBankAh, r.Vsys, r.requiredBankWh / 1000);

            if ~isempty(r.matchedBattery) && ismember('Manufacturer', r.matchedBattery.Properties.VariableNames)
                lines{end+1} = sprintf('Database Match: %s %s (%.0f Ah)', ...
                    r.matchedBattery.Manufacturer{1}, r.matchedBattery.Model{1}, r.matchedBattery.CapacityAh);
                lines{end+1} = sprintf('Parallel Strings Needed: %d', r.numBatteriesParallel);
            else
                lines{end+1} = 'Database Match: None found for selected voltage.';
            end
            
            lines{end+1} = sprintf('Total Bank Capacity: %.1f Ah (%.2f kWh)', r.actualBankAh, r.actualBankWh / 1000);
            lines{end+1} = '';
            lines{end+1} = '=== SYSTEM PERFORMANCE ===';
            lines{end+1} = sprintf('Overall System Efficiency: %.1f%%', r.overallEff);

            app.ResultsTextArea.Value = lines;
        end

        % Update 2D Simulation Plots
        function updateCharts(app, r)
            % Chart 1: PV Generation vs Load
            cla(app.GenerationAxes);
            plot(app.GenerationAxes, r.hours, r.genProfile, 'LineWidth', 2, 'Color', [0.90 0.55 0.10]);
            hold(app.GenerationAxes, 'on');
            plot(app.GenerationAxes, r.hours, r.loadPowerW, '--', 'LineWidth', 1.5, 'Color', [0.20 0.40 0.75]);
            hold(app.GenerationAxes, 'off');
            legend(app.GenerationAxes, {'PV Generation', 'Load Demand'}, 'Location', 'best');
            title(app.GenerationAxes, 'Solar Generation vs. Load Profile (24h)');
            xlabel(app.GenerationAxes, 'Hour of Day');
            ylabel(app.GenerationAxes, 'Power (Watts)');
            grid(app.GenerationAxes, 'on');

            % Chart 2: Battery State of Charge
            cla(app.SOCAxes);
            plot(app.SOCAxes, r.hours, r.soc, 'LineWidth', 2, 'Color', [0.20 0.60 0.30]);
            hold(app.SOCAxes, 'on');
            yline(app.SOCAxes, 100 - r.DoDpercent, ':', 'Min Allowed SOC', 'Color', [0.7 0.2 0.2]);
            hold(app.SOCAxes, 'off');
            title(app.SOCAxes, 'Battery State of Charge (SOC)');
            xlabel(app.SOCAxes, 'Hour of Day');
            ylabel(app.SOCAxes, 'SOC (%)');
            ylim(app.SOCAxes, [0 105]);
            grid(app.SOCAxes, 'on');

            % Chart 3: Energy Distribution
            cla(app.DistributionAxes);
            
            energy_vals = [r.usefulEnergyWh, r.inverterLossWh, r.derateLossWh];
            total_energy = sum(energy_vals);
            
            if total_energy > 0
                pct = (energy_vals / total_energy) * 100;
                pie_labels = { ...
                    sprintf('Useful Load: %.0f Wh (%.1f%%)', r.usefulEnergyWh, pct(1)), ...
                    sprintf('Inverter Loss: %.0f Wh (%.1f%%)', r.inverterLossWh, pct(2)), ...
                    sprintf('Derate Loss: %.0f Wh (%.1f%%)', r.derateLossWh, pct(3)) ...
                };
            else
                pie_labels = {'Useful Load', 'Inverter Loss', 'Derate Loss'};
            end

            pie(app.DistributionAxes, energy_vals, pie_labels);
            title(app.DistributionAxes, 'Daily Energy Distribution Breakdown');

            % Chart 4: Sizing Comparison
            cla(app.ComparisonAxes);
            categories = categorical({'Array (W)', 'Battery Bank (Ah)'});
            categories = reordercats(categories, {'Array (W)', 'Battery Bank (Ah)'});
            required_vals = [r.requiredArrayW, r.requiredBankAh];
            actual_vals   = [r.actualArrayW, r.actualBankAh];
            bar(app.ComparisonAxes, categories, [required_vals; actual_vals]');
            legend(app.ComparisonAxes, {'Required Target', 'Matched/Actual'}, 'Location', 'best');
            title(app.ComparisonAxes, 'Required vs. Actual Sizing');
            grid(app.ComparisonAxes, 'on');
        end

        % Folder Helper
        function path_out = resolveDataFolder(~)
            try
                path_out = fullfile(fileparts(mfilename('fullpath')), '..', 'data');
            catch
                path_out = fullfile(pwd, 'data');
            end
            if ~isfolder(path_out)
                path_out = fullfile(pwd, 'data');
            end
        end
    end

    % CALLBACKS
    methods (Access = private)
        
        function startupFcn(app)
            % Default form initialization
            app_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(genpath(app_root));

            app.SystemModeDropDown.Items    = {'I need panels/battery', 'I have panels'};
            app.SystemModeDropDown.Value    = 'I need panels/battery';
            app.LoadProfileDropDown.Items   = {'Residential', 'Commercial', 'Industrial'};
            app.LoadProfileDropDown.Value   = 'Residential';
            app.SystemVoltageDropDown.Items = {'12', '24', '48'};
            app.SystemVoltageDropDown.Value = '24';

            % Default values
            app.DailyEnergyEditField.Value     = 5;    % kWh/day
            app.DerateFactorEditField.Value    = 80;   % %
            app.PSHEditField.Value             = 4.5;  % hours
            app.PanelWattageEditField.Value    = 350;  % Watts
            app.NumberOfPanelsEditField.Value   = 6;    % quantity
            app.InverterEffEditField.Value     = 95;   % %
            app.AutonomyEditField.Value        = 1;    % days
            app.DoDEditField.Value             = 50;   % %
            app.BattEffEditField.Value         = 90;   % %

            % Initially hide existing panel count
            app.NumberOfPanelsEditField.Visible      = 'off';
            app.NumberOfPanelsEditFieldLabel.Visible = 'off';

            app.ResultsTextArea.Value = {'Enter system parameters and click "Calculate" to perform analysis.'};
        end

        function SystemModeDropDownValueChanged(app, ~)
            % Toggle visibility based on selected mode
            switch app.SystemModeDropDown.Value
                case 'I need panels/battery'
                    app.PanelWattageEditFieldLabel.Text      = 'Target panel wattage (W)';
                    app.NumberOfPanelsEditFieldLabel.Visible  = 'off';
                    app.NumberOfPanelsEditField.Visible       = 'off';
                case 'I have panels'
                    app.PanelWattageEditFieldLabel.Text      = 'Existing panel wattage (W)';
                    app.NumberOfPanelsEditFieldLabel.Visible  = 'on';
                    app.NumberOfPanelsEditField.Visible       = 'on';
            end
        end

        function CalculateButtonPushed(app, ~)
            % Perform calculations and refresh display
            calc_results = app.computeSizing();
            if isempty(calc_results)
                return;
            end

            app.LastResults = calc_results;
            app.updateResultsText(calc_results);
            app.updateCharts(calc_results);

            % Switch view tab to charts automatically
            app.TabGroup.SelectedTab = app.ChartsTab;
        end
    end

    % COMPONENT INITIALIZATION
    methods (Access = private)

        function createComponents(app)
            % Main Window Initialization
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 950 680];
            app.UIFigure.Name = 'SolarOpt - Solar Power Management System';

            % Tab Container
            app.TabGroup = uitabgroup(app.UIFigure);
            app.TabGroup.Position = [10 10 930 660];

            app.SizingTab = uitab(app.TabGroup);
            app.SizingTab.Title = 'System Sizing';

            app.ChartsTab = uitab(app.TabGroup);
            app.ChartsTab.Title = 'Simulation & Charts';

            % Layout Positions for Inputs
            label_x = 30; field_x = 260; field_width = 140; row_height = 34;
            y_position = 550;

            % System Mode Dropdown
            app.SystemModeDropDownLabel = uilabel(app.SizingTab);
            app.SystemModeDropDownLabel.Position = [30 y_position+50 180 22];
            app.SystemModeDropDownLabel.Text = 'System mode';

            app.SystemModeDropDown = uidropdown(app.SizingTab);
            app.SystemModeDropDown.Position = [210 y_position+50 190 22];
            app.SystemModeDropDown.ValueChangedFcn = createCallbackFcn(app, @SystemModeDropDownValueChanged, true);

            % Energy Field
            app.DailyEnergyEditFieldLabel = uilabel(app.SizingTab);
            app.DailyEnergyEditFieldLabel.Position = [label_x y_position 220 22];
            app.DailyEnergyEditFieldLabel.Text = 'Daily energy consumption (kWh)';

            app.DailyEnergyEditField = uieditfield(app.SizingTab, 'numeric');
            app.DailyEnergyEditField.Position = [field_x y_position field_width 22];

            % Load Profile Dropdown
            y_position = y_position - row_height;
            app.LoadProfileDropDownLabel = uilabel(app.SizingTab);
            app.LoadProfileDropDownLabel.Position = [label_x y_position 220 22];
            app.LoadProfileDropDownLabel.Text = 'Load profile type';

            app.LoadProfileDropDown = uidropdown(app.SizingTab);
            app.LoadProfileDropDown.Position = [field_x y_position field_width 22];

            % System Voltage Dropdown
            y_position = y_position - row_height;
            app.SystemVoltageDropDownLabel = uilabel(app.SizingTab);
            app.SystemVoltageDropDownLabel.Position = [label_x y_position 220 22];
            app.SystemVoltageDropDownLabel.Text = 'System voltage (V)';

            app.SystemVoltageDropDown = uidropdown(app.SizingTab);
            app.SystemVoltageDropDown.Position = [field_x y_position field_width 22];

            % Derate Factor Field
            y_position = y_position - row_height;
            app.DerateFactorEditFieldLabel = uilabel(app.SizingTab);
            app.DerateFactorEditFieldLabel.Position = [label_x y_position 220 22];
            app.DerateFactorEditFieldLabel.Text = 'System derate factor (%)';

            app.DerateFactorEditField = uieditfield(app.SizingTab, 'numeric');
            app.DerateFactorEditField.Position = [field_x y_position field_width 22];

            % Peak Sun Hours Field
            y_position = y_position - row_height;
            app.PSHEditFieldLabel = uilabel(app.SizingTab);
            app.PSHEditFieldLabel.Position = [label_x y_position 220 22];
            app.PSHEditFieldLabel.Text = 'Peak sun hours per day (PSH)';

            app.PSHEditField = uieditfield(app.SizingTab, 'numeric');
            app.PSHEditField.Position = [field_x y_position field_width 22];

            % Panel Wattage Field
            y_position = y_position - row_height;
            app.PanelWattageEditFieldLabel = uilabel(app.SizingTab);
            app.PanelWattageEditFieldLabel.Position = [label_x y_position 220 22];
            app.PanelWattageEditFieldLabel.Text = 'Target panel wattage (W)';

            app.PanelWattageEditField = uieditfield(app.SizingTab, 'numeric');
            app.PanelWattageEditField.Position = [field_x y_position field_width 22];

            % Number of Panels Field
            y_position = y_position - row_height;
            app.NumberOfPanelsEditFieldLabel = uilabel(app.SizingTab);
            app.NumberOfPanelsEditFieldLabel.Position = [label_x y_position 220 22];
            app.NumberOfPanelsEditFieldLabel.Text = 'Number of existing panels';

            app.NumberOfPanelsEditField = uieditfield(app.SizingTab, 'numeric');
            app.NumberOfPanelsEditField.Position = [field_x y_position field_width 22];

            % Inverter Efficiency Field
            y_position = y_position - row_height;
            app.InverterEffEditFieldLabel = uilabel(app.SizingTab);
            app.InverterEffEditFieldLabel.Position = [label_x y_position 220 22];
            app.InverterEffEditFieldLabel.Text = 'Inverter efficiency (%)';

            app.InverterEffEditField = uieditfield(app.SizingTab, 'numeric');
            app.InverterEffEditField.Position = [field_x y_position field_width 22];

            % Autonomy Days Field
            y_position = y_position - row_height;
            app.AutonomyEditFieldLabel = uilabel(app.SizingTab);
            app.AutonomyEditFieldLabel.Position = [label_x y_position 220 22];
            app.AutonomyEditFieldLabel.Text = 'Desired autonomy (days)';

            app.AutonomyEditField = uieditfield(app.SizingTab, 'numeric');
            app.AutonomyEditField.Position = [field_x y_position field_width 22];

            % Depth of Discharge Field
            y_position = y_position - row_height;
            app.DoDEditFieldLabel = uilabel(app.SizingTab);
            app.DoDEditFieldLabel.Position = [label_x y_position 220 22];
            app.DoDEditFieldLabel.Text = 'Depth of discharge, DoD (%)';

            app.DoDEditField = uieditfield(app.SizingTab, 'numeric');
            app.DoDEditField.Position = [field_x y_position field_width 22];

            % Battery Efficiency Field
            y_position = y_position - row_height;
            app.BattEffEditFieldLabel = uilabel(app.SizingTab);
            app.BattEffEditFieldLabel.Position = [label_x y_position 220 22];
            app.BattEffEditFieldLabel.Text = 'Battery round-trip efficiency (%)';

            app.BattEffEditField = uieditfield(app.SizingTab, 'numeric');
            app.BattEffEditField.Position = [field_x y_position field_width 22];

            % Calculate Push Button
            y_position = y_position - row_height - 10;
            app.CalculateButton = uibutton(app.SizingTab, 'push');
            app.CalculateButton.Position = [label_x y_position 180 34];
            app.CalculateButton.Text = 'Calculate';
            app.CalculateButton.FontWeight = 'bold';
            app.CalculateButton.ButtonPushedFcn = createCallbackFcn(app, @CalculateButtonPushed, true);

            % ----- Sizing Tab Output Text Box (Right Column) -----
            app.ResultsTextArea = uitextarea(app.SizingTab);
            app.ResultsTextArea.Position = [460 40 440 572];
            app.ResultsTextArea.Editable = 'off';

            % ----- Charts Tab Grid Layout -----
            app.GenerationAxes = uiaxes(app.ChartsTab);
            app.GenerationAxes.Position = [20 330 440 290];

            app.SOCAxes = uiaxes(app.ChartsTab);
            app.SOCAxes.Position = [470 330 440 290];

            app.DistributionAxes = uiaxes(app.ChartsTab);
            app.DistributionAxes.Position = [20 20 440 290];

            app.ComparisonAxes = uiaxes(app.ChartsTab);
            app.ComparisonAxes.Position = [470 20 440 290];

            % Render app visible
            app.UIFigure.Visible = 'on';
        end
    end

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