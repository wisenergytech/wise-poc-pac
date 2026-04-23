# Implementation Plan: Real Solar Data Scaling

**Branch**: `004-real-solar-scaling` | **Date**: 2026-04-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-real-solar-scaling/spec.md`

## Summary

Add a PV data source selector allowing users to choose between synthetic PV generation (existing) and real measured solar data from the Delaunoy 2024 installation (16 kWc), linearly scaled to the configured kWc. When real data is selected, all data series (Belpex, OpenMeteo, CO2) are automatically aligned to 2024 for temporal consistency.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem, R6, shiny, bslib, dplyr, readxl (new), plotly, DT, ompr, CVXR, lubridate
**Storage**: Local CSV files (data/) + external Excel file (../delaunoy/data/)
**Testing**: testthat (unit tests for R6 classes)
**Target Platform**: Linux (Cloud Run via Docker)
**Project Type**: Web application (R Shiny, golem framework)
**Performance Goals**: Data source switch + simulation re-run < 5 seconds
**Constraints**: Delaunoy file must be accessible at relative path; 2024 date range constraint when using real data
**Scale/Scope**: Single-user POC, ~20,600 data points for PV series

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| VII. Tech Stack (R Shiny) | PASS | Uses R/Shiny ecosystem, readxl is a standard tidyverse-adjacent package |
| VIII. Project Structure (Golem + R6) | PASS | New logic in R6 class (DataGenerator), UI in mod_sidebar.R |
| IX. Security (no secrets exposed) | PASS | No secrets involved — file paths only, no API keys for this feature |
| X. Dependency Management | PASS | readxl will be added to DESCRIPTION + renv.lock |
| XI. Separation of Concerns | PASS | Scaling function is pure R6 method; sidebar only handles UI wiring |
| I–VI (Base) | PASS | No violations — feature is internal data handling |

**Post-Phase 1 Re-check**: PASS — no new concerns. The design keeps business logic (scaling, data loading) in R6 classes and UI wiring in modules.

## Project Structure

### Documentation (this feature)

```text
specs/004-real-solar-scaling/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0: research decisions
├── data-model.md        # Phase 1: data model
├── quickstart.md        # Phase 1: quickstart guide
└── checklists/
    └── requirements.md  # Spec quality checklist
```

### Source Code (modified files)

```text
R/
├── R6_data_generator.R  # Add load_delaunoy() + integrate into generate_demo()
├── R6_params.R          # Add pv_data_source field
├── mod_sidebar.R        # Add PV source selector + year constraint
└── mod_status_bar.R     # Display PV source + scaling factor

DESCRIPTION              # Add readxl to Imports
tests/testthat/
└── test-data-generator.R  # Test load_delaunoy() and scaling
```

**Structure Decision**: No new files needed. All changes fit cleanly into existing R6 classes and Shiny modules following the Golem structure.

## Implementation Design

### Phase 1: Pure scaling function (R6_data_generator.R)

Add `load_delaunoy(file_path, target_kwc, ref_kwc = 16)` method to `DataGenerator`:

```
Input:  file_path (string), target_kwc (numeric), ref_kwc = 16 (numeric)
Output: tibble(timestamp = POSIXct, pv_kwh = numeric)

Steps:
1. Read Excel file (readxl::read_excel)
2. Rename columns: Timestamp → timestamp, Value → pv_kwh
3. Scale: pv_kwh = pv_kwh * (target_kwc / ref_kwc)
4. Handle target_kwc == 0 → all zeros
5. Return tibble
```

Error handling: If file not found, return NULL and log warning.

### Phase 2: Integrate into generate_demo() (R6_data_generator.R)

Modify `generate_demo()` to accept `pv_data_source` parameter:
- `"synthetic"` → existing sine-curve formula (no change)
- `"real_delaunoy"` → call `load_delaunoy()`, merge into the demo tibble by timestamp

When `pv_data_source == "real_delaunoy"`:
- Force `date_start` to `2024-01-01` and `date_end` to `2024-12-31` if not already within 2024
- The 15-min timestamp grid is derived from the Delaunoy data itself
- Other columns (t_ext, prix_eur_kwh, conso_base_kwh, soutirage_ecs_kwh) are generated using existing logic but with 2024 dates

### Phase 3: Parameter extension (R6_params.R)

Add to `SimulationParams`:
- `pv_data_source` (character, default `"synthetic"`)
- Include in `as_list()` output

### Phase 4: Sidebar UI (mod_sidebar.R)

Add `radioButtons("pv_data_source", ...)` in the PV section of the sidebar:
- Choices: `c("Synthétique" = "synthetic", "Réel (Delaunoy 2024)" = "real_delaunoy")`
- Default: `"synthetic"`

When `"real_delaunoy"` is selected:
- Constrain date range picker to 2024-01-01 – 2024-12-31
- Pass `pv_data_source` to `generate_demo()` and through to params

### Phase 5: Status bar update (mod_status_bar.R)

In the CFG line, replace current "Source=demo" with:
- `"PV: Synthétique"` when synthetic
- `"PV: Réel Delaunoy ×{factor}"` when real (factor = target_kwc / 16, formatted to 2 decimals)

### Phase 6: Unit tests

Test `load_delaunoy()`:
- Correct scaling (10 kWc → values × 0.625)
- Zero kWc → all zeros
- Missing file → NULL + warning
- Output structure (tibble with timestamp + pv_kwh columns)

## Data Flow (Modified)

```
Sidebar: pv_data_source selector
  │
  ├── "synthetic" → existing flow (unchanged)
  │
  └── "real_delaunoy"
        │
        ├── Constrain date range to 2024
        ├── DataGenerator$load_delaunoy(path, target_kwc)
        │     → scaled 15-min PV tibble
        ├── DataGenerator$generate_demo(pv_data_source = "real_delaunoy", ...)
        │     → uses Delaunoy PV + 2024 Belpex/OpenMeteo/CO2
        └── params$pv_data_source = "real_delaunoy"
              → status bar displays source + scaling factor
```

## Complexity Tracking

No constitution violations to justify. All changes follow existing patterns.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Delaunoy file not found at runtime | Medium — user can't use real data | Graceful fallback to synthetic + warning notification |
| CO2 2024 gaps (~75% missing) | Low — affects CO2 tab accuracy | Existing fallback profile fills gaps with 2024 hourly averages |
| readxl package not in renv.lock | Low — build failure | Add to DESCRIPTION + `renv::snapshot()` during implementation |
| Date range mismatch (user sets 2025 dates with real data) | Medium — no data | Auto-constrain date picker to 2024 when real source selected |
