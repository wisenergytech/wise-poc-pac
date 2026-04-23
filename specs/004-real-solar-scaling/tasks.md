# Tasks: Real Solar Data Scaling

**Input**: Design documents from `/specs/004-real-solar-scaling/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, quickstart.md

**Tests**: Not explicitly requested in the specification. Test tasks included only for the core scaling function (FR-009 requires it to be a pure, testable function).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: Add the new dependency and verify data availability

- [x] T001 Add `readxl` to Imports in `DESCRIPTION` and run `renv::snapshot()` to update `renv.lock`
- [x] T002 Verify Delaunoy data file exists and is readable at `../delaunoy/data/inverters_data_delaunoy.xlsx` — confirm structure: columns `Timestamp`, `Value`, `Unit`; ~20,600 rows; date range 2024-01-01 to 2024-12-31

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core data loading and scaling function that all user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Add `pv_data_source` field (character, default `"synthetic"`) to `SimulationParams` class in `R/R6_params.R` — include in `initialize()` parameters and `as_list()` output
- [x] T004 Implement `load_delaunoy(file_path, target_kwc, ref_kwc = 16)` method in `DataGenerator` class in `R/R6_data_generator.R` — pure function that reads Excel via `readxl::read_excel()`, renames columns to `timestamp`/`pv_kwh`, scales by `target_kwc / ref_kwc`, returns tibble. Handle: file not found → return NULL + warning; target_kwc == 0 → all zeros
- [x] T005 Add unit test for `load_delaunoy()` in `tests/testthat/test-data-generator.R` — test cases: correct scaling (10 kWc → values × 0.625), zero kWc → all zeros, missing file → NULL + warning, output is tibble with `timestamp` + `pv_kwh` columns

**Checkpoint**: Scaling function works and is tested independently

---

## Phase 3: User Story 1 — Choose Solar Data Source (Priority: P1) MVP

**Goal**: User can select between synthetic and real PV data in the sidebar; simulation uses the selected source with correct scaling

**Independent Test**: Select "Réel (Delaunoy 2024)" in sidebar, configure 10 kWc, run simulation — PV column should show realistic (non-sine) production scaled to 10/16 of Delaunoy values

### Implementation for User Story 1

- [x] T006 [US1] Modify `generate_demo()` in `R/R6_data_generator.R` to accept `pv_data_source` parameter (default `"synthetic"`). When `"real_delaunoy"`: call `self$load_delaunoy()` to get scaled PV tibble, build the 15-min timestamp grid from Delaunoy data, and substitute the `pv_kwh` column. Keep all other column generation (t_ext, prix_eur_kwh, conso_base_kwh, soutirage_ecs_kwh) using existing logic but with the Delaunoy timestamp grid
- [x] T007 [US1] Add `radioButtons` input for PV data source in the PV section of `R/mod_sidebar.R` — choices: `c("Synthétique" = "synthetic", "Réel (Delaunoy 2024)" = "real_delaunoy")`, default `"synthetic"`. Wire the input value into `params_r()` as `pv_data_source`
- [x] T008 [US1] Thread `pv_data_source` from sidebar params through to `generate_demo()` call in `R/mod_sidebar.R` — when generating raw_data, pass `pv_data_source = params$pv_data_source` and the Delaunoy file path (`"../delaunoy/data/inverters_data_delaunoy.xlsx"`)
- [x] T009 [US1] Handle fallback in `R/mod_sidebar.R`: if `load_delaunoy()` returns NULL (file missing), show `showNotification("Fichier Delaunoy introuvable — données synthétiques utilisées", type = "warning")` and revert to synthetic mode

**Checkpoint**: User Story 1 fully functional — user can switch PV data source and simulation uses correct data

---

## Phase 4: User Story 2 — Automatic Year Alignment to 2024 (Priority: P2)

**Goal**: When real Delaunoy data is selected, all data series (Belpex, OpenMeteo, CO2) automatically load from 2024 datasets

**Independent Test**: Select "Réel (Delaunoy 2024)", run simulation — verify all timestamps in output are within 2024, and Belpex/temperature/CO2 values match 2024 historical data

### Implementation for User Story 2

- [x] T010 [US2] Modify date range logic in `R/mod_sidebar.R`: when `pv_data_source == "real_delaunoy"`, constrain `dateRangeInput` min/max to `2024-01-01`/`2024-12-31` and update current selection if outside 2024. When switching back to `"synthetic"`, restore default date range behavior
- [x] T011 [US2] Ensure `generate_demo()` in `R/R6_data_generator.R` propagates 2024 dates to DataProvider calls: when `pv_data_source == "real_delaunoy"`, the `date_start`/`date_end` passed to `data_provider$get_belpex()`, `data_provider$get_temperature()`, and the CO2 loading must use 2024 dates (derived from the constrained date range)
- [x] T012 [US2] Verify that existing `load_belpex_prices()`, `load_openmeteo_temperature()`, and `fetch_co2_intensity()` correctly load from `belpex_historical_2024.csv`, `openmeteo_temp_2024.csv`, and `co2_historical_2024.csv` when given 2024 date ranges — no code changes expected, just confirm the existing date-based file selection works for 2024

**Checkpoint**: All data series aligned to 2024 when using real PV data

---

## Phase 5: User Story 3 — Scaled PV Data Validation (Priority: P3)

**Goal**: Status bar displays the active PV data source and scaling factor for transparency

**Independent Test**: With "Réel (Delaunoy 2024)" selected and 20 kWc configured, status bar CFG line should show "PV: Réel Delaunoy ×1.25"

### Implementation for User Story 3

- [x] T013 [US3] Expose `pv_data_source` and `pv_kwc_eff` from sidebar returned reactives in `R/mod_sidebar.R` (if not already exposed) so status bar can compute the scaling factor display
- [x] T014 [US3] Update CFG line in `R/mod_status_bar.R`: replace current "Source=demo" segment with `"PV: Synthétique"` when `pv_data_source == "synthetic"`, or `"PV: Réel Delaunoy ×{factor}"` when `pv_data_source == "real_delaunoy"` (factor = `sprintf("%.2f", pv_kwc / 16)`)

**Checkpoint**: Status bar clearly indicates data source and scaling — all user stories complete

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and cleanup

- [x] T015 Run full app manually following `specs/004-real-solar-scaling/quickstart.md` test steps — verify both modes work end-to-end
- [x] T016 Verify no regressions: run existing tests with `testthat::test_dir("tests/testthat/")`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on T001 (readxl available) — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Phase 2 completion (T003–T005)
- **User Story 2 (Phase 4)**: Depends on Phase 3 (T006–T009) — needs the `pv_data_source` wiring in place
- **User Story 3 (Phase 5)**: Depends on Phase 3 (T007 at minimum — needs sidebar reactive)
- **Polish (Phase 6)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational — no dependencies on other stories
- **User Story 2 (P2)**: Depends on US1 (needs `pv_data_source` parameter wired through sidebar and generate_demo)
- **User Story 3 (P3)**: Depends on US1 (needs sidebar reactive for pv_data_source); can run in parallel with US2

### Within Each User Story

- Sidebar UI changes before server-side wiring
- Data flow changes before display changes

### Parallel Opportunities

- T001 and T002 can run in parallel (setup)
- T003 and T004 can run in parallel (different files: R6_params.R vs R6_data_generator.R)
- T013 and T014 can potentially run in parallel with T010–T012 (US3 vs US2, if US1 is done)

---

## Parallel Example: Phase 2

```bash
# Launch foundational tasks in parallel (different files):
Task: "Add pv_data_source field to SimulationParams in R/R6_params.R"
Task: "Implement load_delaunoy() method in R/R6_data_generator.R"
```

## Parallel Example: US2 + US3

```bash
# After US1 is complete, US2 and US3 can proceed in parallel:
Task: "Modify date range logic in R/mod_sidebar.R"  # US2
Task: "Update CFG line in R/mod_status_bar.R"        # US3
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001–T002)
2. Complete Phase 2: Foundational (T003–T005)
3. Complete Phase 3: User Story 1 (T006–T009)
4. **STOP and VALIDATE**: Test switching between synthetic and real PV data
5. Deploy/demo if ready — core value delivered

### Incremental Delivery

1. Complete Setup + Foundational → Scaling function ready
2. Add User Story 1 → Test source switching → Demo (MVP!)
3. Add User Story 2 → Test year alignment → Demo (coherent simulations)
4. Add User Story 3 → Test status display → Demo (full transparency)
5. Polish → Final validation

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- US2 depends on US1 being complete (needs pv_data_source wiring)
- US3 can partially overlap with US2 (status bar is independent of date logic)
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
