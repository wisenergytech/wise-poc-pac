# Research: Real Solar Data Scaling

**Feature**: 004-real-solar-scaling
**Date**: 2026-04-23

## R1: Delaunoy Data Format & Integration

**Decision**: Load the processed file `../delaunoy/data/inverters_data_delaunoy.xlsx` using `readxl::read_excel()`. The file contains 3 columns: `Timestamp` (datetime), `Value` (float, kWh), `Unit` (always "kWh") — ~20,600 records at 15-minute resolution covering Jan 1 – Dec 31, 2024.

**Rationale**: The processed file is already aggregated across all 5 inverters and cleaned. Using the raw per-inverter files would require replicating the `make_data.R` pipeline. The RDS format is also available but Excel is more portable and explicitly requested.

**Alternatives considered**:
- Reading the RDS file (`inverters_data_delaunoy.rds`): Faster but less transparent; Excel is fine for ~20K rows.
- Reading raw per-inverter Excel files and aggregating: Unnecessary since `make_data.R` already produces the consolidated output.

## R2: Linear Scaling Approach

**Decision**: Scale PV production linearly: `scaled_kwh = value * (target_kwc / 16)` where 16 kWc is the Delaunoy reference capacity.

**Rationale**: Linear scaling is standard for PV system comparison at POC level. The approximation holds when installations share similar orientation, tilt, and climate zone (both are in Belgium). Non-linear effects (inverter clipping, cable losses at scale) are negligible for the kWc ranges used in this POC (typically 5–60 kWc).

**Alternatives considered**:
- Performance-ratio adjustment (accounting for different inverter efficiencies): Over-engineering for a POC.
- Irradiance-based modeling (pvlib/PVGIS): Would require separate irradiance data and system configuration; synthetic mode already covers this use case.

## R3: Year Alignment Strategy

**Decision**: When "Réel (Delaunoy 2024)" is selected, force all data providers to load 2024 data. The existing data files already cover 2024:
- `belpex_historical_2024.csv` — 8,779 hourly records (full year)
- `openmeteo_temp_2024.csv` — 8,785 hourly records (full year)
- `co2_historical_2024.csv` — 2,211 hourly records (partial, ~25% coverage)

For CO2 2024 gaps, the existing `FALLBACK_CO2_PROFILE` (24-element hourly vector based on Elia 2024 averages) will fill missing hours.

**Rationale**: All three 2024 CSV files already exist locally. No API fetching is needed. The simulation date range will be constrained to 2024 boundaries. The existing `load_belpex_prices()`, `load_openmeteo_temperature()`, and `fetch_co2_intensity()` functions already accept date range parameters — they just need to receive 2024 dates.

**Alternatives considered**:
- Fetching fresh 2024 data from APIs at runtime: Unnecessary since local CSVs are complete.
- Shifting Delaunoy timestamps to 2025 to match current default year: Would create non-physical correlations (2024 solar pattern with 2025 weather/prices).

## R4: Integration with Existing Data Flow

**Decision**: Add a new `pv_data_source` parameter to the sidebar and thread it through the data generation pipeline:
1. **Sidebar**: New `radioButtons` input ("Synthétique" / "Réel (Delaunoy 2024)")
2. **DataGenerator**: New method `load_delaunoy(file_path, target_kwc)` returning scaled 15-min tibble
3. **generate_demo()**: Accept `pv_data_source` parameter; when "real", substitute the PV column with scaled Delaunoy data
4. **Year propagation**: When pv_data_source is "real", the date range defaults/constraints switch to 2024

**Rationale**: This approach modifies the existing data flow minimally. The `generate_demo()` method already produces the `pv_kwh` column — we simply replace its source. The DataProvider already has 2024 data loading capability via date parameters.

**Alternatives considered**:
- Creating a completely separate data loading path for real data: Would duplicate date handling, interpolation, and preparation logic.
- Adding a new R6 class `RealDataLoader`: Over-engineering for what is essentially a column substitution + date constraint.

## R5: CO2 2024 Data Gap Handling

**Decision**: Use existing gap-filling mechanism. The `fetch_co2_intensity()` function already handles missing data by:
1. Loading local CSV first
2. Attempting Elia API for gaps
3. Falling back to `FALLBACK_CO2_PROFILE` (hourly averages from Elia ODS192 2024 data)

The 2024 CSV has ~2,211 records (~25% coverage). The fallback profile provides reasonable hourly averages for the remaining hours.

**Rationale**: The existing fallback mechanism is designed for this exact scenario. The FALLBACK_CO2_PROFILE values (115–252 gCO2eq/kWh by hour) are derived from 2024 Belgian averages, making them appropriate for filling 2024 gaps.

**Alternatives considered**:
- Fetching complete 2024 data from Elia APIs to fill the CSV: Could be done as a one-time data preparation step, but not required for POC functionality.
- Using 2025 CO2 data shifted to 2024 timestamps: Would defeat the purpose of year alignment.
