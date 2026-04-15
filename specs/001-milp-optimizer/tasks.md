# Tasks: MILP Optimizer Mode

**Input**: Design documents from `/specs/001-milp-optimizer/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Not explicitly requested. No test tasks generated.

**Organization**: Tasks grouped by user story for independent implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story (US1, US2, US3, US4)
- Exact file paths included

---

## Phase 1: Setup

**Purpose**: Install dependencies and create the optimizer module file

- [x] T001 Install ompr, ompr.roi, ROI.plugin.glpk via `Rscript -e 'renv::install(c("ompr", "ompr.roi", "ROI.plugin.glpk")); renv::snapshot()'` and update DESCRIPTION
- [x] T002 [P] Create empty module file `R/optimizer.R` with function signature `run_optimization_milp(df, params)` returning a tibble with the same columns as `run_simulation()`
- [x] T003 [P] Add `library(ompr)`, `library(ompr.roi)`, `library(ROI.plugin.glpk)` and `source("R/optimizer.R", local = TRUE)` to the top of `app.R`

---

## Phase 2: Foundational

**Purpose**: Core MILP solver function that all user stories depend on

**CRITICAL**: No UI work until this is validated standalone

- [x] T004 Implement `solve_one_day(day_data, params, t_init, soc_init)` in `R/optimizer.R` that formulates and solves the MILP for 96 quarter-hours: binary `pac_on[t]`, continuous `t_ballon[t]`, `offtake[t]`, `injection[t]`, objective `min sum(offtake * prix - injection * prix_inj)`, constraints: energy balance nodal, thermal dynamics, temperature bounds [T_min, T_max]
- [x] T005 Add battery variables and constraints to `solve_one_day()` in `R/optimizer.R`: continuous `charge[t]`, `discharge[t]`, `soc[t]`, binary `batt_charging[t]` for anti-simultaneity, SOC dynamics with efficiency, conditioned on `params$batterie_active`
- [x] T006 Implement `run_optimization_milp(df, params)` in `R/optimizer.R` that loops over days, calls `solve_one_day()` for each, chains `t_init`/`soc_init` between days, collects results into a tibble with columns: `sim_t_ballon`, `sim_pac_on`, `sim_offtake`, `sim_intake`, `sim_cop`, `decision_raison`, `batt_soc`, `batt_flux`
- [x] T007 Add error handling in `run_optimization_milp()` in `R/optimizer.R`: if solver returns infeasible for a day, fall back to rule-based smart mode for that day and log a warning message via `message()`

**Checkpoint**: `run_optimization_milp()` can be called from R console with demo data and returns valid results

---

## Phase 3: User Story 1+2 - Approach selector and optimizer results (Priority: P1)

**Goal**: User can switch between Rule-based and Optimiseur, launch simulation, see results in existing KPIs and graphs

**Independent Test**: Select "Optimiseur", click "Lancer la simulation", verify KPIs show positive gain vs thermostat reel, temperature stays in bounds

- [x] T008 [US1] Replace the mode `selectInput` section in the sidebar of `app.R` with a two-level structure: `radioButtons("approche")` with choices "Rule-based" / "Optimiseur", then `conditionalPanel` showing mode selector (Smart, Injection, etc.) only when "Rule-based" selected
- [x] T009 [US1] Modify `sim_result` eventReactive in `app.R` server to dispatch: if `input$approche == "optimiseur"` call `run_optimization_milp(df_prep, p)` else use existing rule-based logic
- [x] T010 [US2] Ensure `run_optimization_milp()` output in `R/optimizer.R` includes all columns needed by KPI, graph, and table renderPlotly/renderDT functions in `app.R` (verify: `sim_t_ballon`, `sim_pac_on`, `sim_offtake`, `sim_intake`, `sim_cop`, `decision_raison`, `batt_soc`, `batt_flux`, `mode_actif`)
- [x] T011 [US2] Add `withProgress()` calls inside `run_optimization_milp()` in `R/optimizer.R` to update progress bar with `setProgress(day / n_days, detail = sprintf("Jour %d/%d", day, n_days))` for each day solved
- [x] T012 [US1] Update the status bar `renderUI` in `app.R` to show "OPTIMISEUR" when `input$approche == "optimiseur"` instead of the rule-based mode name
- [x] T013 [US2] Handle infeasible solver result in `app.R` server: if `run_optimization_milp()` returns NULL or has attribute "infeasible", show `showNotification("Optimisation infaisable...", type = "error")`

**Checkpoint**: Full optimizer flow works end-to-end in the app, results visible in all existing tabs

---

## Phase 4: User Story 3 - Documentation pedagogique (Priority: P2)

**Goal**: User understands the conceptual difference between rule-based and optimizer approaches

**Independent Test**: Click "Documentation", find and read the new section on optimization approaches

- [x] T014 [US3] Add accordion panel "11. Rule-based vs Optimiseur" to the guide modal in `app.R` server (`observeEvent(input$show_guide)`): explain local decisions vs global optimization, chess analogy, when each approach excels, with concrete example (6h price profile showing why rule-based misses the optimal)
- [x] T015 [US3] Update accordion panel "4. Modes d'optimisation" in the guide modal in `app.R` to mention the Optimiseur approach as a separate category above the rule-based modes

**Checkpoint**: Documentation complete, accessible via button

---

## Phase 5: User Story 4 - Integration Automagic et Auto-adaptatif (Priority: P3)

**Goal**: Optimizer is included in grid search and auto-adaptive mode

**Independent Test**: Run Automagic, verify "optimizer" rows appear in results table

- [x] T016 [US4] Add "optimizer" to the `modes` vector in the Automagic `observeEvent(input$run_automagic)` in `app.R`, with special handling: call `run_optimization_milp()` instead of `run_simulation()` when mode is "optimizer"
- [x] T017 [US4] Add "optimizer" to the `candidats` vector in `run_simulation_auto()` in `app.R`, with special handling: call `run_optimization_milp()` for the optimizer candidate
- [x] T018 [US4] Add color for "optimizer" in the auto modes plot `mc` color vector in `app.R`: `optimizer = "#10b981"`

**Checkpoint**: Automagic and Auto-adaptatif include optimizer as candidate

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Finalization

- [x] T019 [P] Update Mermaid business logic diagrams in `docs/business-logic-diagram.md` to add optimizer flow (new diagram section)
- [x] T020 [P] Run `renv::snapshot()` to ensure `renv.lock` includes ompr, ompr.roi, ROI.plugin.glpk
- [x] T021 Validate quickstart.md scenarios in `specs/001-milp-optimizer/quickstart.md` by running the app with demo data in both modes and verifying results
- [x] T022 Commit and push all changes

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS all user stories
- **US1+2 (Phase 3)**: Depends on Phase 2 — core app integration
- **US3 (Phase 4)**: No dependency on Phase 3 — can be done in parallel
- **US4 (Phase 5)**: Depends on Phase 3 (needs working optimizer in app)
- **Polish (Phase 6)**: Depends on all phases complete

### User Story Dependencies

- **US1+2 (P1)**: Depends on Foundational only. Core MVP.
- **US3 (P2)**: Independent — documentation only, can be done in parallel with US1+2.
- **US4 (P3)**: Depends on US1+2 (needs `run_optimization_milp()` integrated in app).

### Within Each Phase

- Tasks marked [P] can run in parallel
- Sequential tasks depend on previous task in same phase

### Parallel Opportunities

- T002 and T003 can run in parallel (different files)
- T014 and T015 can run in parallel (different accordion panels)
- T019 and T020 can run in parallel (different files)
- Phase 4 (US3) can run in parallel with Phase 3 (US1+2)

---

## Implementation Strategy

### MVP First (US1+2)

1. Phase 1: Setup (T001-T003) — 10 min
2. Phase 2: Foundational (T004-T007) — core MILP solver — 2h
3. Phase 3: US1+2 (T008-T013) — UI + integration — 1h
4. **STOP and VALIDATE**: Test optimizer vs rule-based on demo data
5. If working: proceed to US3, US4, Polish

### Incremental Delivery

1. Setup + Foundational → solver works in R console
2. Add US1+2 → full app integration → **Demo-ready**
3. Add US3 → documentation complete
4. Add US4 → Automagic + Auto-adaptatif include optimizer
5. Polish → diagrams, renv, commit

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps to spec.md user stories
- US1 and US2 are merged in Phase 3 (both P1, tightly coupled)
- Commit after each phase checkpoint
- The MILP solver is the hardest task (T004-T005) — validate standalone before UI integration
