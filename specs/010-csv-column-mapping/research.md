# Research: CSV Column Mapping dynamique

**Feature**: `010-csv-column-mapping`
**Date**: 2026-05-26

## R1: Column name matching strategy

**Decision**: Simple keyword-based matching with priority rules (no ML, no fuzzy matching).

**Rationale**: CSV column names in our domain follow predictable conventions (`pv_kwh`, `gshp_kwh`, `offtake_kwh`, `t_ballon`). A lookup table of keywords per field is sufficient and deterministic. Fuzzy matching (e.g. Levenshtein distance) adds complexity without clear benefit — our users produce CSVs from BQ scripts or tools with consistent naming.

**Implementation**: A named list of regex patterns per target field, checked in priority order. First match wins. If no match, field is left unmapped.

```r
COLUMN_PATTERNS <- list(
  timestamp = "timestamp|time|datetime|date",
  pv_kwh = "pv|solar|photovoltaic",
  offtake_kwh = "offtake|soutirage|consumption|import|grid_import",
  feedin_kwh = "feedin|injection|export|grid_export|intake",
  pac1_kwh = "gshp|geo|pac_301|pac_3",
  pac2_kwh = "ashp|aero|pac_501|pac_5",
  pac_kwh = "^pac_kwh$|^pac$|heat_pump|heatpump",
  t_ballon = "t_ballon|tank|buffer|t_tank",
  t_sol = "t_sol|ground|borehole|soil",
  t_ext = "t_ext|outdoor|ambient|external"
)
```

**Alternatives considered**:
- Fuzzy matching (agrep): overkill, slower, non-deterministic results
- ML classifier: way overkill for a POC with <20 possible column names
- Position-based matching: fragile, column order varies between CSVs

## R2: Shiny UI pattern for dynamic mapping

**Decision**: Use `shiny::updateSelectInput()` to populate dropdowns after CSV upload, inside an `observeEvent(input$csv_file, ...)`.

**Rationale**: Standard Shiny pattern. The selectInputs are created in the UI with `choices = NULL`, then populated server-side when the CSV is loaded. This avoids re-rendering the entire sidebar.

**Flow**:
1. User uploads CSV → `input$csv_file` triggers
2. Server reads header: `names(readr::read_csv(path, n_max = 0))`
3. Server runs `suggest_column_mapping(col_names)` → named list of suggestions
4. Server calls `updateSelectInput()` for each field with choices = col_names, selected = suggestion

## R3: Explorer dynamic variables

**Decision**: Store CSV column names in a reactive value, merge with simulation-generated variables for the explorer dropdowns.

**Rationale**: The explorer (mod_comparaison) currently uses hardcoded named vectors for `vars_baseline` and `vars_optimised`. For CSV mode, we prepend a `vars_csv` section built from actual column names. Demo mode keeps the hardcoded lists.

**Implementation**: `vars_csv <- setNames(csv_cols, csv_cols)` — column name = display name = value. Merged with existing vars when simulation results are available.

## R4: Backward compatibility strategy

**Decision**: If all required columns match the current format exactly (exact name match), skip the mapping UI entirely and proceed as before.

**Rationale**: Existing users who already have CSVs in the right format should not see any difference. The mapping panel only appears when column names don't match or when there are extra/different columns.

**Detection**: After auto-matching, if `timestamp`, `pv_kwh`, `offtake_kwh`, and (`feedin_kwh` or `intake_kwh`) are all matched with exact name matches, mark as "auto-mapped" and collapse the mapping panel.
