# Feature Specification: Real Solar Data Scaling

**Feature Branch**: `004-real-solar-scaling`
**Created**: 2026-04-23
**Status**: Draft
**Input**: User description: "Je voudrais que le user puisse choisir entre des données solaires purement synthétiques ou mise à l'échelle à partir du jeu de données excel dans le repo ../delaunoy, folder ./data sachant que l'installation delaunoy a 16kW crête en fonction de la configuration de KW crête qui a été mise en input. Implemente la fonction qui permet la mise à l'échelle. Aussi il faudrait voir à quel point on peut combiner avec les data belpex et openmeteo et CO2 car sur delaunoy on est en 2024 donc idéalement il faudrait que toutes nos séries dans ce cas soient 2024. Donc il faudrait aller récupérer les données 2024 en plus des 2025 pour ces providers"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Choose Solar Data Source (Priority: P1)

As a user, I want to choose between synthetic PV data or real measured solar data (from the Delaunoy installation) so that I can run simulations with either idealized or real-world production profiles.

In the sidebar parameters, a new selector allows me to pick the PV data source: "Synthétique" (current behavior) or "Réel (Delaunoy 2024)". When I select the real data source, the system loads the Delaunoy 2024 measured production data, automatically scaled to match my configured kWc capacity.

**Why this priority**: This is the core feature — without the data source selector, none of the other stories are relevant. It delivers immediate value by enabling real-world PV profiles in simulations.

**Independent Test**: Can be fully tested by selecting "Réel (Delaunoy 2024)" in the sidebar and verifying that the PV production column in the simulation uses scaled real data instead of synthetic sine-curve data.

**Acceptance Scenarios**:

1. **Given** the user has configured a 10 kWc installation, **When** the user selects "Réel (Delaunoy 2024)" as PV data source, **Then** the system loads Delaunoy 15-minute production data scaled by a factor of 10/16 (target capacity / Delaunoy reference capacity of 16 kWc).
2. **Given** the user selects "Synthétique", **When** the simulation runs, **Then** the PV data is generated using the existing synthetic formula (current behavior, unchanged).
3. **Given** the user switches from "Réel" to "Synthétique" and back, **When** the simulation runs each time, **Then** the results correctly reflect the selected data source.

---

### User Story 2 - Automatic Year Alignment to 2024 (Priority: P2)

As a user, when I select real Delaunoy solar data, I want all other data series (Belpex prices, OpenMeteo temperatures, CO2 intensity) to automatically align to the year 2024, so that all time series are temporally consistent and the simulation results are physically meaningful.

**Why this priority**: Without year alignment, mixing 2024 PV data with 2025 price/weather/CO2 data produces incoherent simulations. This is essential for the real data mode to be usable.

**Independent Test**: Can be tested by selecting "Réel (Delaunoy 2024)" and verifying that all data series (prices, temperature, CO2) display 2024 timestamps in the simulation output.

**Acceptance Scenarios**:

1. **Given** the user selects "Réel (Delaunoy 2024)" as PV source, **When** the simulation runs, **Then** Belpex prices are loaded from the 2024 historical dataset.
2. **Given** the user selects "Réel (Delaunoy 2024)" as PV source, **When** the simulation runs, **Then** OpenMeteo temperatures are loaded from the 2024 dataset.
3. **Given** the user selects "Réel (Delaunoy 2024)" as PV source, **When** the simulation runs, **Then** CO2 intensity data is loaded from the 2024 dataset.
4. **Given** the user selects "Synthétique" as PV source, **When** the simulation runs, **Then** data series use their default year behavior (unchanged from current behavior).

---

### User Story 3 - Scaled PV Data Validation (Priority: P3)

As a user, I want to see that the scaled PV data is physically plausible so that I can trust the simulation inputs. The status bar or energy tab should show the data source being used and the scaling factor applied.

**Why this priority**: Provides transparency and confidence in the data, but the simulation works correctly without this visibility.

**Independent Test**: Can be tested by checking that the status bar or energy tab displays the data source label and scaling ratio.

**Acceptance Scenarios**:

1. **Given** the user has selected "Réel (Delaunoy 2024)" with a 20 kWc configuration, **When** the simulation completes, **Then** a status indicator shows "PV: Réel Delaunoy ×1.25" (20/16 scaling factor).
2. **Given** the user has selected "Synthétique", **When** the simulation completes, **Then** the status indicator shows "PV: Synthétique".

---

### Edge Cases

- What happens when the configured kWc is 0? The system produces zero PV production regardless of data source.
- What happens when the user selects a simulation date range that extends beyond the Delaunoy 2024 dataset (Jan 1 – Dec 31, 2024)? The system restricts the date range to available data or warns the user.
- What happens if the Delaunoy Excel file is not accessible (file missing or corrupted)? The system falls back to synthetic data with a warning message.
- What happens with the 2024 CO2 dataset which has partial coverage (~2,211 records out of ~8,760 expected)? The system uses available data and fills gaps using the existing fallback CO2 hourly profile.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a selector in the sidebar allowing the user to choose between "Synthétique" and "Réel (Delaunoy 2024)" PV data sources.
- **FR-002**: System MUST load the Delaunoy processed solar production data (15-minute resolution, full year 2024) from the external Excel file when the real data source is selected.
- **FR-003**: System MUST scale the Delaunoy production data linearly by the ratio (configured kWc / 16 kWc) where 16 kWc is the Delaunoy installation's peak capacity.
- **FR-004**: When "Réel (Delaunoy 2024)" is selected, all data series (Belpex, OpenMeteo temperature, CO2) MUST be loaded from their respective 2024 datasets to ensure temporal consistency.
- **FR-005**: When "Synthétique" is selected, the system MUST use the existing behavior for all data series (no change from current functionality).
- **FR-006**: System MUST display the active PV data source and scaling factor in the status bar or simulation output.
- **FR-007**: System MUST gracefully handle the absence of the Delaunoy data file by falling back to synthetic data with a user-visible warning.
- **FR-008**: System MUST handle a configured kWc of 0 by producing zero PV production regardless of data source.
- **FR-009**: The scaling function MUST be a pure function (no UI dependencies) that takes the raw Delaunoy data and target kWc as inputs and returns the scaled 15-minute production series.

### Key Entities

- **PV Data Source**: Selection of the origin of photovoltaic production data (synthetic or real measured). Determines which loading and transformation logic is used.
- **Delaunoy Reference Dataset**: The 2024 measured solar production from the Delaunoy installation (16 kWc, 15-minute resolution, ~20,600 records). Serves as the basis for linear scaling.
- **Scaling Factor**: The ratio of target kWc to reference kWc (16), applied uniformly to all production values.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can switch between synthetic and real PV data in under 5 seconds (selector interaction + simulation re-run).
- **SC-002**: Scaled real PV data produces annual production within ±5% of the expected linear scaling (e.g., 10 kWc installation produces ~62.5% of the 16 kWc Delaunoy total).
- **SC-003**: When using real PV data, all data series (prices, temperature, CO2) are from the same calendar year (2024), with no temporal mismatches.
- **SC-004**: Users can clearly identify which data source is active and what scaling has been applied, without needing to inspect raw data.

## Assumptions

- The Delaunoy processed Excel file (`inverters_data_delaunoy.xlsx`) at `../delaunoy/data/` is the authoritative source for real PV data. It contains aggregated production across all 5 inverters in kWh at 15-minute resolution.
- Linear scaling by kWc ratio is a sufficient approximation for this POC. Real-world factors (orientation, shading, inverter efficiency differences) are not modeled.
- The Delaunoy installation's reference peak capacity is 16 kWc (as stated by the user).
- Belpex 2024 and OpenMeteo 2024 local CSV datasets are already available in the project's `data/` directory and are complete for the full year.
- The CO2 2024 dataset has partial coverage (~2,211 hourly records); gaps will be filled using the existing fallback CO2 hourly profile.
- The simulation date range will be constrained to 2024 when real data is selected.
- The Delaunoy data file path is relative to the project root (`../delaunoy/data/inverters_data_delaunoy.xlsx`) and is expected to be available on the developer's machine. It is not bundled with the application.
