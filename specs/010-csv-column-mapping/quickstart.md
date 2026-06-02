# Quickstart: CSV Column Mapping

**Feature**: `010-csv-column-mapping`
**Date**: 2026-05-26

## Testing the mapping with the dual PAC dataset

```r
# 1. Source the mapping function
source("R/fct_csv_mapping.R")

# 2. Read a CSV header
cols <- names(readr::read_csv("data/bq_k0001_dual_pac.csv", n_max = 0))
# Expected: timestamp, pv_kwh, gshp_kwh, ashp_kwh, pac_kwh, offtake_kwh,
#           feedin_kwh, t_ballon, t_sol, t_ext, cop_gshp, cop_ashp, cop

# 3. Run auto-matching
mapping <- suggest_column_mapping(cols)
print(mapping)
# Expected output:
#   timestamp → "timestamp"
#   pv_kwh → "pv_kwh"
#   offtake_kwh → "offtake_kwh"
#   feedin_kwh → "feedin_kwh"
#   pac1_kwh → "gshp_kwh"  (matched "gshp")
#   pac2_kwh → "ashp_kwh"  (matched "ashp")
#   t_ballon → "t_ballon"
#   t_sol → "t_sol"
#   t_ext → "t_ext"

# 4. Apply mapping to rename columns
df <- readr::read_csv("data/bq_k0001_dual_pac.csv")
df_mapped <- apply_column_mapping(df, mapping)
names(df_mapped)
# Should contain internal names: timestamp, pv_kwh, offtake_kwh, etc.
```

## Testing via the Shiny app

1. `golem::run_app()`
2. Select "CSV" data source
3. Upload `data/bq_k0001_dual_pac.csv`
4. Verify mapping panel appears with all fields pre-filled
5. Check PAC 1 is auto-suggested as GSHP, PAC 2 as ASHP
6. Click "Simuler" — should run DualOptimizer
7. Open Comparaison tab — dropdowns should show all CSV columns

## Testing backward compatibility

1. Upload a CSV in the old format (`timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh`)
2. Mapping panel should auto-collapse (all exact matches)
3. Simulation should work identically to before

## Key files

| File | What to understand |
|------|--------------------|
| `R/fct_csv_mapping.R` | Pure function: `suggest_column_mapping()`, `apply_column_mapping()` |
| `R/mod_sidebar.R:667+` | Current CSV import logic (to be refactored) |
| `R/mod_comparaison.R:60-97` | Current hardcoded variable lists (to be made dynamic) |
