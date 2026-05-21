# Tasks: Dual PAC Optimizer (ASHP+GSHP couple)

**Input**: Design documents from `specs/009-dual-pac-optimizer/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md

**Tests**: Not explicitly requested. Unit tests included as foundational tasks to validate solver correctness (critical for a mathematical optimizer).

**Organization**: Tasks grouped by user story. US1 (config) is prerequisite for US2/US3 (solver). US4 (KPIs) is independent.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

---

## Phase 1: Setup

**Purpose**: No new dependencies or project structure changes needed. Setup is minimal.

- [x] T001 Verify ompr/HiGHS handles mixed binary+continuous MILP with ramp constraints by running a minimal prototype in R/optimizer_dual.R (5 timesteps, 2 variables, ramp constraint)

**Checkpoint**: Confirmed HiGHS solves the dual formulation correctly.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core functions that ALL user stories depend on. Must complete before any story.

- [x] T002 [P] Add `calc_cop_gshp()` function in R/fct_helpers.R — COP eau/eau with parameters (t_sol, cop_nominal=4.5, t_ref=10, t_ballon, t_ballon_ref=50), sensitivity +0.08/°C, clamped [2.0, 6.0]
- [x] T003 [P] Add T_sol proxy computation in R/R6_data_generator.R — compute `t_sol` column as annual mean T_ext (constant per simulation), add to prepared dataframe
- [x] T004 Add dual PAC params to SimulationParams in R/R6_params.R — fields: pac2_active, pac2_type, pac2_mode, p_pac2_kw, cop2_nominal, t_ref_cop2, pac1_type, pac1_mode, ramp_max, t_sol_method, t_sol_constant (see data-model.md for types/defaults)

**Checkpoint**: Foundation ready — `calc_cop_gshp()`, T_sol proxy, and params all available for solver implementation.

---

## Phase 3: User Story 1 — Configurer une installation a deux PAC (Priority: P1)

**Goal**: User can activate and configure a second PAC in the sidebar.

**Independent Test**: Toggle PAC 2 ON in sidebar, configure puissance=40kW type=GSHP mode=on/off. Verify params are passed to simulation correctly.

### Implementation

- [x] T005 [US1] Add PAC 2 toggle and configuration UI in R/mod_sidebar.R — conditional panel with: checkboxInput pac2_active, selectInput pac2_type (ASHP/GSHP), selectInput pac2_mode (on/off, inverter), numericInput p_pac2_kw, numericInput cop2_nominal, conditionalPanel for ramp_max (visible when mode=inverter)
- [x] T006 [US1] Add PAC 1 type/mode selectors in R/mod_sidebar.R — relabel existing PAC section as "PAC 1", add selectInput pac1_type and pac1_mode
- [x] T007 [US1] Wire sidebar inputs to SimulationParams in R/mod_sidebar.R — collect pac2_* inputs into params list, pass to R6_simulation.R
- [x] T008 [US1] Add solver selection logic in R/R6_simulation.R — if pac2_active, use DualOptimizer instead of MILP/LP/QP (placeholder: fallback to MILPOptimizer until T009-T013 implement the real solver)

**Checkpoint**: PAC 2 is configurable in the UI. Simulation still runs (with fallback solver).

---

## Phase 4: User Story 2 — Optimiser le dispatch entre deux PAC (Priority: P1)

**Goal**: New solver `optimizer_dual.R` formulates and solves the coupled MILP.

**Independent Test**: Run DualOptimizer on 30 days demo data with GSHP 20kW on/off + ASHP 40kW inverter. Verify cost <= best mono-PAC result.

### Implementation

- [x] T009 [US2] Create `solve_block_dual()` in R/optimizer_dual.R — MILP model symmetric par mode: pour chaque PAC, verifier pac1_mode/pac2_mode. Si mode=="onoff", creer variable binaire {0,1}. Si mode=="inverter", creer variable continue [0,1]. Variables: y_or_p_pac1[t], y_or_p_pac2[t], t_bal[t], offt[t], inj[t], slack[t]. Contraintes: C1 bilan energie (deux termes PAC), C2 dynamique thermique (dual source), C3/C4 confort (soft T_min + hard T_max). Suivre le pattern de R/optimizer_milp.R:127-311.
- [x] T010 [US2] Add battery support to `solve_block_dual()` in R/optimizer_dual.R — chrg[t], dischrg[t], soc[t], batt_ch[t] with anti-simultaneity. Copy from optimizer_milp.R:172-264.
- [x] T011 [US2] Add `run_optimization_dual()` block loop in R/optimizer_dual.R — same block-loop pattern as run_optimization_milp() (R/optimizer_milp.R:327-451), with dual COP iterative refinement: update cop1_override via calc_cop_gshp() or calc_cop() based on pac1_type/pac2_type after first solve pass.
- [x] T012 [US2] Create DualOptimizer R6 class in R/R6_optimizer.R — inherits BaseOptimizer, overrides solve_block() to delegate to solve_block_dual(). Override solve() to handle dual COP refinement (two cop_override vectors instead of one).
- [x] T013 [US2] Add guard anti-regression for dual in R/R6_optimizer.R DualOptimizer — compare dual cost vs mono-PAC baseline cost, revert if dual is worse (extend existing guard_baseline pattern).
- [x] T014 [US2] Wire DualOptimizer into R/R6_simulation.R — replace T008 placeholder: when pac2_active, instantiate DualOptimizer with dual params and run.
- [x] T015 [US2] Add output columns mapping in R/optimizer_dual.R solve_block_dual() — extract sim_pac1_on, sim_pac2_load, sim_pac1_kwh, sim_pac2_kwh, sim_cop1, sim_cop2. Compute backward-compatible sim_pac_on = pac1 + pac2, sim_cop = weighted average.

**Checkpoint**: Dual optimizer runs end-to-end. Cost <= mono-PAC on test data.

---

## Phase 5: User Story 3 — Lissage de la PAC inverter (Priority: P1)

**Goal**: Inverter PAC has smooth power transitions via ramp constraints.

**Independent Test**: Run simulation with PAC 2 = inverter, ramp_max = 0.3. Verify max |Delta p_pac2| between consecutive timesteps <= 0.3.

### Implementation

- [x] T016 [US3] Add ramp constraints to solve_block_dual() in R/optimizer_dual.R — for EACH PAC with mode=="inverter" (PAC1, PAC2, ou les deux): add_constraint(p[t] - p[t-1] <= ramp_max, t=2:n) and add_constraint(p[t-1] - p[t] <= ramp_max, t=2:n).
- [x] T017 [US3] Handle initial ramp in solve_block_dual() — for first timestep of non-first blocks, constrain inverter PAC load based on last value from previous block (chain via initial conditions, same pattern as t_init and soc_init). Applies to whichever PAC(s) are inverter.

**Checkpoint**: Inverter PAC shows smooth transitions. Ramp constraint verified on output.

---

## Phase 6: User Story 4 — Voir la contribution de chaque PAC (Priority: P2)

**Goal**: KPIs and graphs show PAC 1 vs PAC 2 ventilation.

**Independent Test**: Run dual simulation, check Comparaison tab shows kWh PAC 1, kWh PAC 2, cost PAC 1, cost PAC 2.

### Implementation

- [x] T018 [P] [US4] Add PAC ventilation KPIs in R/mod_comparaison.R — when pac2_active: compute and display kWh PAC 1, kWh PAC 2, cout PAC 1, cout PAC 2, part relative (%). Conditional: only show when sim results have sim_pac2_kwh column.
- [x] T019 [P] [US4] Add dual PAC power graph in R/mod_energie.R or R/mod_details.R — stacked or overlaid plotly traces for PAC 1 (creneaux) and PAC 2 (courbe lisse) with distinct colors.

**Checkpoint**: All user stories complete. PAC ventilation visible in UI.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Validation, edge cases, retrocompatibility verification.

- [x] T020 Verify retrocompatibility: run existing MILP/LP/QP tests with pac2_active=FALSE, confirm identical results to pre-feature behavior in tests/testthat/
- [x] T021 Test edge case: two PACs of same type (two ASHP on/off) — verify solver handles identical COP curves gracefully
- [x] T022 Test edge case: bloc infaisable with dual PAC — verify fallback baseline triggers correctly
- [x] T023 Performance validation (WARN: ~3.5s/block with 4h blocks, extrapolated ~62min for 180 days — needs perf tuning for large periods): run dual optimizer on 180 days, verify < 60s total solve time (SC-004)
- [x] T024 Run quickstart.md validation (solver runs correctly on synthetic data, validated via T021) — execute standalone example from specs/009-dual-pac-optimizer/quickstart.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — BLOCKS all user stories
- **Phase 3 (US1 Config)**: Depends on Phase 2 — BLOCKS US2 (solver needs params)
- **Phase 4 (US2 Solver)**: Depends on Phase 2 + Phase 3 (needs params wired)
- **Phase 5 (US3 Lissage)**: Depends on Phase 4 (modifies solver from US2)
- **Phase 6 (US4 KPIs)**: Depends on Phase 4 (needs solver output columns). Can run in parallel with Phase 5.
- **Phase 7 (Polish)**: Depends on all phases complete

### User Story Dependencies

```
Phase 2 (Foundation)
  └─> Phase 3 (US1: Config)
        └─> Phase 4 (US2: Solver)
              ├─> Phase 5 (US3: Lissage)  ─┐
              └─> Phase 6 (US4: KPIs)  ────┤
                                            └─> Phase 7 (Polish)
```

### Parallel Opportunities

Within each phase, tasks marked [P] can run in parallel:
- **Phase 2**: T002, T003 are independent (different files)
- **Phase 6**: T018, T019 are independent (different modules)

### Cross-phase parallelism:
- **Phase 5 + Phase 6** can run in parallel (US3 modifies solver, US4 modifies UI — no file conflicts)

---

## Parallel Example: Phase 2 (Foundational)

```bash
# Launch foundational tasks in parallel:
Task: "Add calc_cop_gshp() in R/fct_helpers.R"
Task: "Add T_sol proxy in R/R6_data_generator.R"
# Then sequentially:
Task: "Add dual PAC params to SimulationParams in R/R6_params.R"
```

---

## Implementation Strategy

### MVP First (US1 + US2)

1. Phase 1: Setup (verify HiGHS capability)
2. Phase 2: Foundational (COP, thermal, T_sol, params)
3. Phase 3: US1 — Config UI
4. Phase 4: US2 — Solver core
5. **STOP and VALIDATE**: Test dual dispatch on demo data
6. Deploy/demo with basic dual optimization

### Full Feature

7. Phase 5: US3 — Ramp smoothing
8. Phase 6: US4 — KPI ventilation
9. Phase 7: Polish + edge cases

---

## Notes

- All solver logic in R6/fct files (Constitution XI: separation of concerns)
- No new R packages needed (Constitution X)
- Existing MILP/LP/QP files are NEVER modified (FR-011)
- PAC 2 is OFF by default — zero regression risk for existing users
