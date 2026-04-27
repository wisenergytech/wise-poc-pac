# Data Model: 005-measured-baseline

**Date**: 2026-04-27

## Entities

### CSV Eligibility (runtime detection, not persisted)

Computed after CSV upload in `mod_sidebar.R`. Determines which baseline mode to use.

| Field | Type | Source | Description |
|---|---|---|---|
| `has_pac_kwh` | logical | CSV column detection | pac_kwh column exists |
| `has_meter` | logical | CSV column detection | offtake_kwh + feedin_kwh/intake_kwh exist |
| `has_t_ballon` | logical | CSV column detection | t_ballon column exists |
| `pac_na_rate` | numeric | `sum(is.na(pac_kwh)) / n` | NA rate on pac_kwh |
| `is_eligible` | logical | derived | `has_pac_kwh & has_meter & pac_na_rate < 0.10` |

### Baseline Mode (enum, 3 values)

| Value | Trigger | Behavior |
|---|---|---|
| `"thermostat"` | Demo or CSV without suivi PV | Simulate ON/OFF hysteresis |
| `"pv_tracking"` | Demo or CSV with suivi PV checkbox | Simulate PV surplus following (alpha) |
| `"measured"` | CSV eligible + pv_kwc == pv_kwc_ref | Pass-through: use CSV data as-is |

### Transition rules

```
CSV uploaded
  → detect eligibility (has_pac_kwh + has_meter + NA rate)
  │
  ├── NOT eligible → baseline_mode = existing logic (thermostat / pv_tracking)
  │                   UI: slider AC, calibrate button, suivi PV checkbox visible
  │
  └── ELIGIBLE + pv_kwc == pv_kwc_ref
      → baseline_mode = "measured"
         UI: slider AC hidden, calibrate hidden, suivi PV hidden
             pv_kwc locked, toggle "Tester autre PV" visible
             ECS field hidden if has_t_ballon, visible otherwise
             bandeau: "Baseline = donnees mesurees [+ ECS info]"
      │
      └── User activates what-if toggle
          → pv_kwc unlocked, baseline_mode = "pv_tracking" or "thermostat"
             UI: slider AC + calibrate + suivi PV re-shown
          │
          └── User deactivates toggle
              → pv_kwc = pv_kwc_ref, baseline_mode = "measured"
                 UI: back to measured state
```

## Dataframe columns contract

### Baseline output (what Baseline$run() returns)

The KPI calculator and optimizer expect these columns from the baseline dataframe:

| Column | Type | Thermostat/PV-tracking | Measured mode |
|---|---|---|---|
| `offtake_kwh` | numeric | Computed from energy balance | From CSV (via prepare_df) |
| `intake_kwh` | numeric | Computed from energy balance | From CSV (renamed feedin_kwh) |
| `t_ballon` | numeric | Simulated by thermal model | From CSV if present, else NA |
| `pv_kwh` | numeric | From prepared data | From prepared data (possibly rescaled) |
| `conso_hors_pac` | numeric | From prepared data | From prepared data (exact via pac_kwh) |
| `prix_offtake` | numeric | From prepared data | From prepared data |
| `prix_injection` | numeric | From prepared data | From prepared data |
| `soutirage_estime_kwh` | numeric | From prepared data | From prepared data |
| `t_ext` | numeric | From prepared data | From prepared data |

In measured mode, the first 3 rows come directly from the CSV. All other columns are already in the prepared dataframe. The pass-through simply skips the thermal simulation loop.

### Special case: t_ballon absent in measured mode

When CSV is eligible (pac_kwh + meter) but lacks t_ballon:
- `t_ballon` column will be NA in the baseline output
- KPI conformity check must handle NA gracefully (report "N/A" instead of a percentage)
- The comparaison tab's "T° ballon baseline" trace must be hidden or show a message

## No new persistence

This feature adds no new files, databases, or storage. All state is in-memory Shiny reactives.
