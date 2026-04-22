# Implementation Plan: Wire R6 Classes into Shiny Modules

**Branch**: `003-wire-r6-modules` | **Date**: 2026-04-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-wire-r6-modules/spec.md`

## Summary

Replace all calls to legacy procedural functions (`generer_demo()`, `prepare_df()`, `run_baseline()`, `run_simulation()`, `decider()`) in Shiny modules with the R6 `Simulation` orchestrator class. The R6 classes already exist and have been validated at 0.0% parity deviation. This is a pure wiring change — no new business logic.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem >= 0.4.0, R6 >= 2.5.0, shiny, bslib, dplyr, plotly, ompr, CVXR
**Storage**: N/A (in-memory simulation, CSV data files)
**Testing**: testthat (95 existing tests)
**Target Platform**: Linux server (GCP Cloud Run via Docker)
**Project Type**: web-service (Shiny dashboard)
**Performance Goals**: Simulation completes in <30s for 3-month period
**Constraints**: Downstream modules (mod_energie, mod_finances, etc.) expect `sim_filtered()` reactive to return a dataframe with specific columns — this interface must not change
**Scale/Scope**: 2 module files to modify (mod_sidebar.R, mod_dimensionnement.R), 1 file to delete (fct_legacy.R)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| VII. Tech Stack (R Shiny) | PASS | No stack change — same R6 + Golem |
| VIII. Project Structure | PASS | No new files, only modifications + 1 deletion |
| IX. Security | PASS | No secrets involved |
| X. R Dependency Management | PASS | No new dependencies |
| VI. Simplicity | PASS | Removes complexity (eliminates duplicated code in fct_legacy.R) |
| V. Documentation | PASS | Speckit workflow followed |

No violations. No complexity tracking needed.

## Project Structure

### Documentation (this feature)

```text
specs/003-wire-r6-modules/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (via /speckit.tasks)
```

### Source Code (files affected)

```text
R/
├── mod_sidebar.R           # PRIMARY: Rewire simulation workflow to use Simulation R6
├── mod_dimensionnement.R   # SECONDARY: Rewire scenario simulations to use Simulation R6
├── fct_legacy.R            # DELETE: No longer needed after rewiring
│
├── R6_simulation.R         # UNCHANGED: Orchestrator (already exists)
├── R6_params.R             # UNCHANGED: SimulationParams (already exists)
├── R6_baseline.R           # UNCHANGED: Baseline class (already exists)
├── R6_optimizer.R          # UNCHANGED: All optimizer classes (already exist)
├── R6_data_generator.R     # UNCHANGED: DataGenerator (already exists)
├── R6_kpi.R                # UNCHANGED: KPICalculator (already exists)
│
├── optimizer_lp.R          # UNCHANGED: LP solver (called by LPOptimizer)
├── optimizer_milp.R        # UNCHANGED: MILP solver (called by MILPOptimizer)
├── optimizer_qp.R          # UNCHANGED: QP solver (called by QPOptimizer)

tests/testthat/
├── helper-setup.R          # MAY NEED UPDATE: Remove fct_legacy.R sourcing if present
```

**Structure Decision**: No new files. Only modify mod_sidebar.R and mod_dimensionnement.R, then delete fct_legacy.R.
