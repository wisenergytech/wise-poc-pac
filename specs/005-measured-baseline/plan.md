# Implementation Plan: Baseline mesuree pour CSV complet

**Branch**: `005-measured-baseline` | **Date**: 2026-04-27 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/005-measured-baseline/spec.md`

## Summary

When a user uploads a CSV with `pac_kwh` + meter data (`offtake_kwh`, `feedin_kwh`), use measured data directly as baseline instead of re-simulating a fictitious behavior. This provides more reliable gain estimates (optimized vs real). The feature adds a `"measured"` mode to the Baseline R6 class (pass-through), conditionally hides the AC slider / calibration UI, locks the PV field with a what-if toggle, and pre-fills `pv_kwc_ref` from a heuristic.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem, R6, shiny, bslib, dplyr, plotly (no new dependencies)
**Storage**: N/A (in-memory simulation, CSV data files)
**Testing**: testthat (existing test suite in tests/testthat/)
**Target Platform**: Linux server (Cloud Run Docker container)
**Project Type**: Web application (R Shiny)
**Performance Goals**: N/A (no new computation — pass-through is faster than simulation)
**Constraints**: No new R packages. Shiny reactive cycle must not introduce visible latency on mode switch.
**Scale/Scope**: 3 R6 files touched, 1 Shiny module, 2 vignettes

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Technology Stack | PASS (override VII) | R Shiny, no new dependencies |
| II. Server-Side Security | PASS | No new secrets, no browser exposure |
| III. Authentication Guard | PASS (override IX) | POC, no auth required |
| IV. Observability | PASS | Existing message() logging in Baseline/Simulation |
| V. Documentation Artifacts | PASS | spec.md, plan.md, research.md, tasks.md produced |
| VI. Simplicity | PASS | No new abstraction — pass-through mode is minimal |
| VIII. Project Structure | PASS | Changes in existing R6 + mod files, no new files except test |
| X. R Dependency Management | PASS | No new packages |
| XI. Separation of Concerns | PASS | Baseline mode logic in R6_baseline.R (business), UI conditionals in mod_sidebar.R (Shiny) |

No violations. Complexity Tracking table not needed.

## Project Structure

### Documentation (this feature)

```text
specs/005-measured-baseline/
├── spec.md              # Feature specification (done)
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── tasks.md             # Phase 2 output (via /speckit.tasks)
```

### Source Code (impacted files)

```text
R/
├── R6_baseline.R          # Add mode "measured" (pass-through)
├── R6_simulation.R        # Propagate mode "measured"
├── mod_sidebar.R          # CSV detection, conditional UI, toggle, pv_kwc_ref heuristic
│
├── R6_kpi.R               # No change (already uses pac_kwh)
├── R6_optimizer.R          # No change (guard_baseline works as-is)
├── R6_data_generator.R     # No change (prepare_df already handles pac_kwh)
└── fct_sizing.R            # No change (compute_ac_bounds not called in measured mode)

vignettes/
├── lire-les-resultats.Rmd          # Document measured baseline
├── cas-usage-faq.Rmd               # FAQ: measured vs simulated
└── comprendre-votre-installation.Rmd  # Already updated (PV rescaling)

tests/testthat/
└── test-R6_baseline.R     # Add test for mode "measured"

scripts/
└── generate_test_csv.R    # Already created (test data generator)
```

**Structure Decision**: No new files except a test. All changes in existing R6 classes (business logic) and mod_sidebar.R (UI wiring), respecting Principle XI separation.
