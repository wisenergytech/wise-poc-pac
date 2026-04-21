# Feature Specification: Wire R6 Classes into Shiny Modules

**Feature Branch**: `003-wire-r6-modules`
**Created**: 2026-04-21
**Status**: Draft
**Input**: User description: "Remplacer les appels aux fonctions legacy (fct_legacy.R) dans les modules Shiny par les classes R6 existantes. mod_sidebar.R et mod_dimensionnement.R appellent encore generer_demo(), prepare_df(), run_baseline(), run_simulation(), decider() au lieu d'utiliser le workflow R6 Simulation$new() → $load_data() → $run_baseline() → $run_optimization() → $get_results(). Une fois le recâblage fait, supprimer fct_legacy.R."

## User Scenarios & Testing

### User Story 1 - Replace legacy calls in mod_sidebar.R (Priority: P1)

The main simulation workflow in mod_sidebar.R currently calls `generer_demo()`, `prepare_df()`, `run_baseline()`, `run_simulation()`, and `run_optimization_lp/qp()` from fct_legacy.R. These must be replaced by a single `Simulation` R6 object that orchestrates the full pipeline: `$load_data()` → `$run_baseline()` → `$run_optimization()` → `$get_results()`.

**Why this priority**: mod_sidebar.R is the heart of the app — it triggers all simulations. Without this, fct_legacy.R cannot be removed.

**Independent Test**: Launch the app with `make dev`, run a simulation with PAC 60kW / LP / baseline ingénieur, verify KPIs are identical to current values (facture, gain, autoconsommation). Repeat with MILP, QP, and Smart modes.

**Acceptance Scenarios**:

1. **Given** the app is running, **When** the user clicks "Simuler" with default parameters and LP optimizer, **Then** the results (facture, gain, autoconsommation) are identical (±0.1%) to the current fct_legacy.R implementation
2. **Given** the app is running, **When** the user switches optimizer mode to Smart/MILP/QP, **Then** the simulation runs via the R6 Simulation class and produces correct results
3. **Given** the app is running, **When** the user changes baseline mode (reactif, programmateur, surplus_pv, ingenieur, proactif), **Then** the baseline runs via the R6 Baseline class through Simulation
4. **Given** the app is running, **When** the user uploads a CSV file instead of using demo data, **Then** the R6 Simulation handles CSV loading correctly
5. **Given** the app is running, **When** the user enables battery storage, **Then** battery parameters are passed through the R6 workflow and results include battery state

---

### User Story 2 - Replace legacy calls in mod_dimensionnement.R (Priority: P2)

mod_dimensionnement.R runs multiple scenario simulations (PV sizing, battery sizing) using legacy functions. These must use the Simulation R6 class instead.

**Why this priority**: Secondary module, but still calls legacy functions. Must be wired before fct_legacy.R can be deleted.

**Independent Test**: Open the Dimensionnement tab, run the automagic scenario analysis, verify PV and battery scenario results are correct.

**Acceptance Scenarios**:

1. **Given** the Dimensionnement tab is open, **When** the user runs the automagic analysis, **Then** multiple Simulation R6 instances are created and solved correctly
2. **Given** the Dimensionnement tab is open, **When** PV scenario sliders are adjusted, **Then** each scenario uses an independent Simulation instance (no shared state)

---

### User Story 3 - Remove fct_legacy.R and clean up (Priority: P3)

Once US1 and US2 are complete, fct_legacy.R has zero callers and can be deleted. Any residual references in tests or scripts must be updated.

**Why this priority**: This is the cleanup step — only possible after US1 and US2 are done.

**Independent Test**: Delete fct_legacy.R, run `make test`, run `make dev` and verify the app works. Grep the entire codebase for `generer_demo|prepare_df|run_baseline|run_simulation|decider` and confirm zero hits outside of R6 classes and their tests.

**Acceptance Scenarios**:

1. **Given** US1 and US2 are complete, **When** fct_legacy.R is deleted, **Then** `make test` passes with zero failures
2. **Given** fct_legacy.R is deleted, **When** `make dev` is run, **Then** the app starts and all 7 tabs function correctly
3. **Given** fct_legacy.R is deleted, **When** grepping for legacy function names, **Then** no references exist outside R6 class definitions

### Edge Cases

- What happens when the optimizer mode is "smart" (which uses `decider()` + `run_simulation()` — different code path than LP/MILP/QP)?
- How does the CSV upload path handle the transition from `prepare_df()` to `Simulation$load_data(source="csv")`?
- What happens when the battery is active — does the R6 `SmartOptimizer` handle battery identically to the legacy `run_simulation()`?
- What happens during dimensionnement scenarios that create many Simulation instances in rapid succession?

## Requirements

### Functional Requirements

- **FR-001**: mod_sidebar.R MUST use `Simulation$new(params)` instead of calling `generer_demo()`, `prepare_df()`, `run_baseline()` separately
- **FR-002**: mod_sidebar.R MUST pass all user-selected parameters (PAC, PV, ballon, contrat, baseline mode, optimizer mode, curtailment, battery) to the Simulation R6 object via SimulationParams
- **FR-003**: mod_sidebar.R MUST use `Simulation$run_optimization(mode)` for all 4 modes (smart, milp, lp, qp) instead of calling `run_simulation()` or `run_optimization_lp/qp()` directly
- **FR-004**: mod_sidebar.R MUST expose `sim$get_results()` and `sim$get_baseline()` as reactive values for downstream modules (energie, finances, details, contraintes, co2)
- **FR-005**: mod_dimensionnement.R MUST use `Simulation$new()` for each scenario instead of calling legacy functions
- **FR-006**: The CSV export (downloadHandler) MUST use `Simulation$export_csv()` instead of manual column selection
- **FR-007**: fct_legacy.R MUST be deleted after all callers are migrated
- **FR-008**: All existing tests MUST continue to pass after migration
- **FR-009**: The `decider()` function (smart mode logic) MUST remain accessible — either kept in fct_legacy.R or moved to the SmartOptimizer R6 class

### Key Entities

- **Simulation**: R6 orchestrator — the single object that replaces the 5 legacy functions
- **SimulationParams**: R6 parameter container — replaces the plain list `p` built manually in mod_sidebar.R
- **sim_filtered reactive**: The reactive value returned by mod_sidebar_server that downstream modules consume — its structure must remain unchanged

## Success Criteria

### Measurable Outcomes

- **SC-001**: Zero calls to `generer_demo()`, `prepare_df()`, `run_baseline()`, `run_simulation()`, `decider()` remain in any module file (R/mod_*.R)
- **SC-002**: fct_legacy.R is deleted from the codebase
- **SC-003**: All 95 existing testthat tests pass
- **SC-004**: Simulation results (facture, gain, autoconsommation) are identical (±0.1%) before and after migration for all 4 optimizer modes × 5 baseline modes
- **SC-005**: The app starts and all 7 tabs function correctly after migration

## Assumptions

- The R6 classes (Simulation, SimulationParams, Baseline, all Optimizers) already implement the same logic as fct_legacy.R — this was validated during the 002-golem-r6-refactor with 0.0% parity deviation
- The reactive interface between mod_sidebar and downstream modules (sim_filtered, params_r) does not need to change — only the internal implementation of how sim_filtered is computed
- The `decider()` function logic already exists in the SmartOptimizer R6 class
- No new R6 classes need to be created — this is purely a wiring change
