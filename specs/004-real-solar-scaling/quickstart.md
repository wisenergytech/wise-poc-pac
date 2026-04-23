# Quickstart: Real Solar Data Scaling

**Feature**: 004-real-solar-scaling

## Prerequisites

- The Delaunoy data repository must be present at `../delaunoy/data/inverters_data_delaunoy.xlsx` relative to the project root.
- The `readxl` R package must be available (add to DESCRIPTION if not already present).
- Existing 2024 data CSVs in `data/` directory (belpex, openmeteo, co2) — already present.

## What Changes

### New files
- None (all changes are to existing files)

### Modified files

| File | Change |
|------|--------|
| `R/R6_data_generator.R` | Add `load_delaunoy()` method + integrate into `generate_demo()` |
| `R/R6_params.R` | Add `pv_data_source` field |
| `R/mod_sidebar.R` | Add PV data source selector + year constraint logic |
| `R/mod_status_bar.R` | Display PV source and scaling factor |
| `DESCRIPTION` | Add `readxl` to Imports (if not present) |

## How to Test

1. Start the app: `golem::run_app()`
2. In the sidebar, locate the new "Source PV" selector
3. Select "Réel (Delaunoy 2024)" — date range should auto-constrain to 2024
4. Set a kWc value (e.g., 10 kWc) and run the simulation
5. Verify: PV production profile looks realistic (not a smooth sine curve), and all data series timestamps are in 2024
6. Switch back to "Synthétique" — verify existing behavior is unchanged

## Key Design Decisions

- **Linear scaling**: `scaled = raw * (target_kwc / 16)` — simple, sufficient for POC
- **Year forcing**: Real data mode forces all series to 2024 to maintain temporal consistency
- **Pure function**: `load_delaunoy()` is a pure R6 method with no Shiny dependencies (per constitution Principle XI)
- **Graceful fallback**: If Delaunoy file is missing, falls back to synthetic with warning
