# Tasks: Baseline mesuree pour CSV complet

**Input**: Design documents from `/specs/005-measured-baseline/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md

**Tests**: Included (SC-004 requires non-regression, SC-005 requires new test).

**Organization**: Tasks grouped by user story. US1 is the MVP.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: No new project structure needed. Verify existing test suite passes before any changes.

- [ ] T001 Run existing test suite to establish green baseline: `Rscript -e "devtools::test()"`
- [ ] T002 Generate test CSV files if not present: `Rscript scripts/generate_test_csv.R`

**Checkpoint**: All existing tests pass. Test CSV files available in `data/`.

---

## Phase 2: Foundational (Baseline "measured" mode)

**Purpose**: Add the `"measured"` pass-through mode to the Baseline R6 class. This MUST be complete before any UI work.

- [ ] T003 Add mode `"measured"` to `Baseline$run()` in `R/R6_baseline.R`. When mode is `"measured"`, skip the thermal simulation loop entirely and return the input dataframe as-is (preserve existing `offtake_kwh`, `intake_kwh`, `t_ballon` columns). Add `"measured"` to the mode documentation. Handle the case where `t_ballon` is absent (set column to NA).
- [ ] T004 [P] Add unit test for measured mode in `tests/testthat/test-R6_baseline.R`. Test that `Baseline$run(df, params, mode = "measured")` returns the dataframe with `offtake_kwh`, `intake_kwh`, `t_ballon` identical to input. Test with and without `t_ballon` column.
- [ ] T005 Verify `Simulation$run_baseline(mode = "measured")` works in `R/R6_simulation.R`. The mode is already passed through to `Baseline$run()` — verify no special-casing is needed. Add `"measured"` to the `@param mode` roxygen documentation.
- [ ] T006 Run full test suite to confirm non-regression: `Rscript -e "devtools::test()"`

**Checkpoint**: `Baseline$run(mode = "measured")` works as pass-through. All existing tests still pass.

---

## Phase 3: User Story 1 — Baseline mesuree automatique (Priority: P1) MVP

**Goal**: When a CSV with pac_kwh + meter data is uploaded, automatically use measured data as baseline. Hide AC slider, calibration, suivi PV checkbox. Show informative banner.

**Independent Test**: Upload `data/test_csv_complet.csv`. Verify slider AC disappears, banner shows, KPI baseline matches CSV sums.

### Implementation for User Story 1

- [ ] T007 [US1] Add CSV eligibility detection function in `R/mod_sidebar.R`. After CSV is loaded and validated (around line 473), compute: `has_pac_kwh`, `has_meter`, `has_t_ballon`, `pac_na_rate`. Store result in a new `reactiveVal` `csv_measured_eligible` (logical). Eligibility = `has_pac_kwh & has_meter & pac_na_rate < 0.10`.
- [ ] T008 [US1] Add `pv_kwc_ref` heuristic pre-fill in `R/mod_sidebar.R`. When CSV is loaded and contains `pv_kwh`, compute `estimated_kwc = round(max(pv_kwh, na.rm=TRUE) / 0.25 / 0.90 * 2) / 2` (nearest 0.5). Update the `pv_kwc_ref` numericInput with this value. Add a form-text message below: "Estime a partir du pic PV observe. Verifiez cette valeur."
- [ ] T009 [US1] Conditionally hide baseline controls in `R/mod_sidebar.R`. When `csv_measured_eligible()` is TRUE and `pv_kwc == pv_kwc_ref` (no what-if): hide the checkbox "Suivi PV existant" (`pv_tracking`), the slider `autoconso_cible`, the button `calibrate_ac`, and the `renderUI` panel `autoconso_panel_calibrated`. Use `conditionalPanel` or `renderUI` wrapping with a reactive condition.
- [ ] T010 [US1] Conditionally hide ECS field in `R/mod_sidebar.R`. When `csv_measured_eligible()` is TRUE and `has_t_ballon` is TRUE, hide the `ecs_kwh_jour` numericInput. When `has_t_ballon` is FALSE but eligible, keep it visible.
- [ ] T011 [US1] Add measured baseline banner in `R/mod_sidebar.R`. When `csv_measured_eligible()` is TRUE, render a `renderUI` banner showing: "Baseline = donnees mesurees (completes)" if `has_t_ballon`, or "Baseline = donnees mesurees. ECS estime par profil synthetique (pas de t_ballon)." otherwise. Include the measured AC% as read-only: `AC = (sum(pv_kwh) - sum(feedin_kwh)) / sum(pv_kwh) * 100`. Style with the existing theme colors from `fct_ui_theme.R`.
- [ ] T012 [US1] Wire baseline mode to `"measured"` in `R/mod_sidebar.R`. In the `sim_result` eventReactive (around line 634), when `csv_measured_eligible()` is TRUE and no what-if active, set `baseline_mode_r <- "measured"` instead of thermostat/pv_tracking. Pass to `run_simulation()`.
- [ ] T013 [US1] Update status bar for measured mode in `R/mod_status_bar.R`. When baseline mode is "measured", display "Baseline=Mesuree" instead of "AC XX%" in the CFG line (around line 98).
- [ ] T014 [US1] Handle `t_ballon` NA in KPI conformity in `R/R6_kpi.R`. In `get_conformite()` (line 293), if all `sim_t_ballon` values are NA, return NA instead of computing percentages. In `compute()`, if `t_ballon` is all NA in baseline_data, set `conformite_baseline` to NA.
- [ ] T015 [US1] Run test suite + manual test with `data/test_csv_complet.csv` upload.

**Checkpoint**: Uploading a complete CSV activates measured baseline. KPI baseline = CSV sums. Slider AC hidden. Banner visible.

---

## Phase 4: User Story 2 — Bascule what-if PV (Priority: P2)

**Goal**: Toggle "Tester un autre dimensionnement PV" locks/unlocks pv_kwc and switches between measured and simulated baseline.

**Independent Test**: Upload complete CSV, verify measured mode. Activate toggle, change pv_kwc. Verify slider AC reappears. Deactivate toggle, verify return to measured.

### Implementation for User Story 2

- [ ] T016 [US2] Add what-if PV toggle checkbox in `R/mod_sidebar.R`. Add `checkboxInput(ns("pv_whatif"), "Tester un autre dimensionnement PV", value = FALSE)` in the PV section, visible only when `csv_measured_eligible()` is TRUE (via conditionalPanel). When unchecked, the `pv_kwc` field (slider or numericInput) is disabled/hidden and locked to `pv_kwc_ref`.
- [ ] T017 [US2] Wire toggle to baseline mode switch in `R/mod_sidebar.R`. Add an `observe` that watches `input$pv_whatif`. When toggled ON: enable pv_kwc field, re-show AC slider + calibration + suivi PV checkbox. When toggled OFF: reset pv_kwc to pv_kwc_ref value, re-hide controls, switch back to measured mode.
- [ ] T018 [US2] Update `baseline_mode_r` logic in `R/mod_sidebar.R`. The mode selection (around line 634) must account for the what-if state: `if (csv_measured_eligible() && !isTRUE(input$pv_whatif))` → measured, else → existing thermostat/pv_tracking logic.
- [ ] T019 [US2] Update banner text when what-if is active in `R/mod_sidebar.R`. When toggle is ON, replace the measured banner with: "PV rescale (XX kWc) -> baseline simulee (les mesures ne sont plus valides pour cette taille PV)." styled as a warning.
- [ ] T020 [US2] Manual test: upload CSV, toggle what-if on/off, verify mode switches correctly.

**Checkpoint**: Toggle cleanly switches between measured and simulated. Deactivating restores measured mode.

---

## Phase 5: User Story 3 — CSV partiel non-regression (Priority: P3)

**Goal**: CSV without pac_kwh must behave exactly as before. No visible change.

**Independent Test**: Upload `data/test_csv_complet_partial.csv`. Verify slider AC and suivi PV checkbox are visible, baseline is simulated.

### Implementation for User Story 3

- [ ] T021 [US3] Verify non-regression with partial CSV. Upload `data/test_csv_complet_partial.csv` (no pac_kwh, no t_ballon). Confirm: slider AC visible, calibrate button visible, suivi PV checkbox visible, banner not shown. No code change expected — just verify the conditionals from US1 correctly fall through.
- [ ] T022 [US3] Verify Demo mode non-regression. Switch to Demo mode. Confirm all controls visible, baseline simulated. No code change expected.
- [ ] T023 [US3] Run full test suite: `Rscript -e "devtools::test()"`

**Checkpoint**: Existing behavior preserved for Demo and partial CSV.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and final validation.

- [ ] T024 [P] Update `vignettes/lire-les-resultats.Rmd` — add a note in the "Conso PAC" section explaining that in measured baseline mode, the baseline values come directly from the CSV (not simulated). Mention that the bandeau in the sidebar indicates which mode is active.
- [ ] T025 [P] Update `vignettes/cas-usage-faq.Rmd` — add a new FAQ entry: "Baseline mesuree vs simulee : quelle difference ?" explaining when each mode is used, why measured is more reliable, and when it falls back to simulated (PV rescaling).
- [ ] T026 Commit all changes with descriptive message referencing the spec.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Phase 2 (measured mode must exist)
- **US2 (Phase 4)**: Depends on US1 (toggle extends the measured mode UI)
- **US3 (Phase 5)**: Can run in parallel with US2 (just verification)
- **Polish (Phase 6)**: Depends on US1 + US2

### User Story Dependencies

- **US1 (P1)**: Depends on Foundational only. This is the MVP.
- **US2 (P2)**: Depends on US1 (the toggle modifies UI built in US1).
- **US3 (P3)**: Independent of US1/US2 (just non-regression verification). Can run in parallel with US2.

### Within Each User Story

- T007 (detection) before T009-T012 (UI depends on detection)
- T008 (heuristic) parallel with T007 (different concern)
- T009, T010, T011 parallel (different UI sections)
- T012 after T007 + T009 (wiring depends on detection + UI)

### Parallel Opportunities

```
Phase 2:  T003 ──┬── T004 [P] (test in parallel with implementation)
                  └── T005 [P]

Phase 3:  T007 ──┬── T009 [P] (hide controls)
          T008   ├── T010 [P] (hide ECS)
                 ├── T011 [P] (banner)
                 └── T012 (wire mode — after T007)
                      T013 [P] (status bar)
                      T014 [P] (KPI NA handling)

Phase 5:  T021 ──┬── T022 [P]
                 └── T023

Phase 6:  T024 ──┬── T025 [P]
```

---

## Implementation Strategy

### MVP First (US1 Only)

1. Complete Phase 1: Setup (T001-T002)
2. Complete Phase 2: Foundational (T003-T006) — measured mode exists
3. Complete Phase 3: US1 (T007-T015) — full measured baseline UX
4. **STOP and VALIDATE**: Upload test_csv_complet.csv, verify measured baseline works
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Measured mode available in R6 classes
2. US1 → Measured baseline auto-detected + UI → **MVP deployed**
3. US2 → What-if PV toggle → More flexibility for power users
4. US3 → Non-regression verified → Confidence
5. Polish → Documentation updated → Feature complete

---

## Notes

- No new R packages required
- All business logic changes in R6 classes (Principle XI)
- All UI changes in mod_sidebar.R (Shiny wiring only)
- Test CSV files already generated by `scripts/generate_test_csv.R`
- Total: 26 tasks across 6 phases
