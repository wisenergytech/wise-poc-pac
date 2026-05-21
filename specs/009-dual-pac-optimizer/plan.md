# Implementation Plan: Dual PAC Optimizer (ASHP+GSHP couple)

**Branch**: `009-dual-pac-optimizer` | **Date**: 2026-05-21 | **Spec**: `specs/009-dual-pac-optimizer/spec.md`
**Input**: Feature specification from `specs/009-dual-pac-optimizer/spec.md`

## Summary

Extend the PAC optimizer with a 4th solver (`optimizer_dual.R`) that formulates a single MILP coupling two heat pumps (one on/off binary, one inverter continuous with ramp smoothing) feeding the same thermal buffer. Inspired by IEEE 2019 MILP Dual Source HP and D'Ettorre 2019 MPC hybrid HP. Fully backward-compatible — existing MILP/LP/QP solvers remain unchanged.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: ompr 1.0.4, ompr.roi 1.0.2, ROI.plugin.highs (MILP solver), R6 >= 2.5.0, golem >= 0.4.0, shiny, bslib, dplyr, plotly
**Storage**: N/A (in-memory simulation, CSV/RDA data files)
**Testing**: testthat (unit tests for R6 classes and pure functions)
**Target Platform**: Linux server (Docker, Cloud Run)
**Project Type**: Web application (Shiny)
**Performance Goals**: Solver dual < 60s for 180 days (SC-004 from spec)
**Constraints**: ompr/HiGHS must handle MILP with mixed binary+continuous+ramp constraints; block size 4-8h with lookahead
**Scale/Scope**: POC — single installation (Profondeville), 2 PACs, 1 ballon

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Technology Stack | PASS (VII override) | R Shiny POC, no new framework. ompr/HiGHS already in stack. |
| II. Server-Side Security | PASS | No new API keys or secrets. T_sol is a calculated proxy. |
| III. Authentication Guard | PASS (IX override) | POC, no auth required. |
| IV. Observability | PASS | Solver logs already use `message()`. New solver follows same pattern. |
| V. Documentation Artifacts | IN PROGRESS | spec.md done. plan.md (this file), research.md, flows.md, tasks.md to follow. |
| VI. Simplicity | PASS | New solver is a single file + R6 class. No new abstractions. Ramp smoothing via linear constraints (not MIQP). |
| VII. R Stack | PASS | Same packages, no new dependencies. |
| VIII. Project Structure | PASS | New files follow existing R/ layout. |
| IX. Security | PASS | No secrets. |
| X. R Dependencies | PASS | No new packages. |
| XI. Separation of Concerns | PASS | All solver logic in R6/fct files. mod_sidebar only adds UI controls. |

No violations. Complexity Tracking table not needed.

## Project Structure

### Documentation (this feature)

```text
specs/009-dual-pac-optimizer/
├── spec.md              # Done
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (via /speckit-tasks)
```

### Source Code (repository root)

```text
R/
├── optimizer_dual.R          # NEW — solve_block_dual() MILP mixed binary+continuous+ramp
├── R6_optimizer.R            # MODIFY — add DualOptimizer class (inherits BaseOptimizer)
├── R6_data_generator.R       # MODIFY — add t_sol proxy column
├── fct_helpers.R             # MODIFY — add calc_cop_gshp()
├── mod_sidebar.R             # MODIFY — add PAC 2 toggle + config UI
├── mod_comparaison.R         # MODIFY — add PAC 1/PAC 2 ventilation KPIs
│
├── optimizer_milp.R          # UNCHANGED
├── optimizer_lp.R            # UNCHANGED
├── optimizer_qp.R            # UNCHANGED
└── R6_optimizer.R            # UNCHANGED (BaseOptimizer, MILPOptimizer, LPOptimizer, QPOptimizer)

tests/testthat/
├── test-optimizer_dual.R     # NEW — unit tests for solve_block_dual
└── test-cop_gshp.R           # NEW — unit tests for calc_cop_gshp
```

**Structure Decision**: Follows existing R/ flat layout. One new solver file (`optimizer_dual.R`) + modifications to 5 existing files. No new directories or structural changes.
