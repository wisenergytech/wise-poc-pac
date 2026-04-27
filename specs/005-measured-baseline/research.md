# Research: 005-measured-baseline

**Date**: 2026-04-27

## No NEEDS CLARIFICATION items

All technical decisions were resolved during the spec clarification phase (5 questions). No unknowns remain.

## Design Decisions

### D1: CSV eligibility detection

**Decision**: A CSV is eligible for measured baseline when it contains `pac_kwh` + `offtake_kwh` + `feedin_kwh`/`intake_kwh` with < 10% NA on `pac_kwh`. The presence of `t_ballon` is optional (improves ECS estimation quality).

**Rationale**: `pac_kwh` is the critical column — it enables exact `conso_hors_pac` calculation. Without it, the PAC/other split is heuristic. `t_ballon` improves ECS estimation but isn't needed for financial KPIs.

**Alternatives considered**:
- Require all 5 columns (pac_kwh + meter + t_ballon): rejected — too strict, many users have sub-meters but no tank sensor.
- Require only meter (no pac_kwh): rejected — without pac_kwh, conso_hors_pac is approximated, defeating the purpose of "measured" baseline.

### D2: Baseline "measured" mode implementation

**Decision**: Add a `"measured"` mode to `Baseline$run()` that returns the prepared dataframe without thermal simulation. It's a pass-through: the existing `offtake_kwh`, `intake_kwh`, and `t_ballon` columns (if present) are kept as-is.

**Rationale**: Simplest possible implementation. No new class, no new abstraction. The Baseline class already supports multiple modes via a switch — adding a third is minimal.

**Alternatives considered**:
- Bypass Baseline entirely in Simulation$run_baseline(): rejected — would require special-casing downstream (optimizer, KPI). Keeping the Baseline interface uniform is cleaner.
- New R6 class MeasuredBaseline: rejected — violates Principle VI (simplicity). A mode flag is sufficient.

### D3: PV what-if toggle

**Decision**: Lock `pv_kwc` field (= pv_kwc_ref) in measured baseline mode. A checkbox "Tester un autre dimensionnement PV" unlocks it and triggers the switch to simulated baseline.

**Rationale**: Prevents accidental mode switches. The toggle makes the user's intent explicit and the UI state clear. Disabling the toggle re-locks pv_kwc and returns to measured mode.

**Alternatives considered**:
- Always editable, implicit switch: rejected — too easy to accidentally change pv_kwc and silently switch baseline mode.
- Confirmation dialog: rejected — intrusive UX for a common action.

### D4: pv_kwc_ref heuristic

**Decision**: Pre-fill `pv_kwc_ref` with `max(pv_kwh) / 0.25 / 0.90` rounded to nearest 0.5 kWc, with a visible message "Verifiez cette valeur".

**Rationale**: Better starting point than the current default of 6 kWc. The formula assumes: max observed quarter-hour production ≈ 90% of peak capacity × 0.25h. Fragile if no clear-sky day in the dataset or if inverter clips, but still closer than 6.

**Alternatives considered**:
- P99 instead of max: more robust against outliers but underestimates if only a few good days.
- Force user input: rejected — friction for users who may not know their kWc.

### D5: ECS field visibility

**Decision**: Hide `ecs_kwh_jour` input when CSV has `t_ballon` (ECS estimated from delta_t). Keep visible when `t_ballon` absent (user can adjust synthetic ECS profile via ecs_kwh_jour).

**Rationale**: When t_ballon is available, ECS estimation from temperature drops is automatic and more accurate than a flat daily number. Showing the field would be confusing (user sets a value that gets ignored). When t_ballon is absent, the synthetic profile uses ecs_kwh_jour, so the field remains relevant.

## Technology Patterns

### Shiny conditional UI pattern

The sidebar already uses `conditionalPanel()` and `renderUI()` extensively for dynamic visibility. The measured baseline UI will follow the same pattern:
- A `reactiveVal` `csv_eligible` (logical) tracks whether the loaded CSV qualifies
- `conditionalPanel` or `renderUI` hides/shows AC slider, calibration button, suivi PV checkbox, ECS field
- The toggle checkbox controls `pv_kwc` editability via `shinyjs::disable/enable` or a `conditionalPanel`

### Baseline mode propagation

Current flow:
```
mod_sidebar → baseline_mode_r ("thermostat" | "pv_tracking")
  → run_simulation(df, p, mode, baseline_mode)
    → Simulation$run_baseline(mode)
      → Baseline$run(df, params, mode)
```

New flow adds `"measured"` as a third baseline_mode_r value. No structural change — just a new case in the switch.
