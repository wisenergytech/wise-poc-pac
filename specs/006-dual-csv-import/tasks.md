# Tasks: Import à deux CSV avec détection automatique PAC et PV reconstitué

**Input**: Design documents from `/specs/006-dual-csv-import/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Included (unit tests for the 3 new fct_*.R files).

**Organization**: Tasks grouped by user story. US1 is the MVP.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup

**Purpose**: Verify existing test suite, prepare test data.

- [x] T001 Run existing test suite to confirm green baseline: `Rscript -e "devtools::test()"`
- [x] T002 [P] Verify test data files exist: `inst/extdata/bq_k0001_raw.csv` and `inst/extdata/bq_k0001_ores_raw.csv`

**Checkpoint**: All existing tests pass. Test CSV files available.

---

## Phase 2: Foundational (CSV Parsing & Joining)

**Purpose**: Core parsing functions that ALL user stories depend on. MUST be complete before any story begins.

- [x] T003 Create `R/fct_csv_parser.R` with `detect_timestep(timestamps)` function. Takes a vector of POSIXct, returns detected step as character ("5min", "15min", "60min") using median of first 10 diffs. Return "irregular" if no standard step matches (± 10% tolerance).
- [x] T004 [P] Add `parse_installation_csv(file_path)` to `R/fct_csv_parser.R`. Reads CSV, parses timestamp column (try "time" then "timestamp"), validates required column `Elec_consumption` exists, detects timestep, aggregates to 15-min if needed (sum for energies/powers, mean for T and COP). Returns list(df, timestep, report).
- [x] T005 [P] Add `parse_ores_csv(file_path)` to `R/fct_csv_parser.R`. Reads CSV, parses timestamp, validates `Consumption_index_kWh` and `Injection_index_kWh` exist, detects timestep, aggregates to 15-min (last index per qt), computes deltas with pmax(0, ...). Returns list(df, timestep, report).
- [x] T006 Add `join_sources(df_install, df_ores)` to `R/fct_csv_parser.R`. Inner join by timestamp on common period. Returns list(df, n_points, date_start, date_end, n_excluded).
- [x] T007 [P] Create `tests/testthat/test-fct_csv_parser.R`. Test: detect_timestep with 5-min and 15-min data. Test: parse_installation_csv with `inst/extdata/bq_k0001_raw.csv`. Test: parse_ores_csv with `inst/extdata/bq_k0001_ores_raw.csv`. Test: join_sources produces expected ~13000 rows.
- [x] T008 Run test suite to confirm parsing works: `Rscript -e "devtools::test()"`

**Checkpoint**: Parsing and joining works. Two raw CSVs → single joined dataframe at 15-min resolution.

---

## Phase 3: User Story 1 — Upload et jointure (Priority: P1) MVP

**Goal**: Two file inputs in sidebar, automatic parsing/joining, import report displayed.

**Independent Test**: Upload bq_k0001_raw.csv + bq_k0001_ores_raw.csv. See report with ~13000 qt, period 2025-11-20 → 2026-04-30.

### Implementation for User Story 1

- [x] T009 [US1] Replace single CSV fileInput in `R/mod_sidebar.R` with two fileInputs: `file_installation` ("Données installation (monitoring PAC)") and `file_ores` ("Données compteur ORES"). Remove old CSV upload logic and related reactiveVals (csv_measured_eligible, csv_has_t_ballon, csv_est_pac_th_kw, csv_est_volume_l).
- [x] T010 [US1] Add reactive logic in `R/mod_sidebar.R`: when both files are uploaded, call `parse_installation_csv()`, `parse_ores_csv()`, `join_sources()`. Store result in `reactiveVal(joined_data)`. If only one file uploaded, show message "Veuillez charger le second fichier".
- [x] T011 [US1] Add import report rendering in `R/mod_sidebar.R`. Display: number of points joined, period, detected timesteps for each file, any warnings (partial overlap, aggregation applied). Use existing notification style.
- [x] T012 [US1] Wire `joined_data()` to the existing simulation pipeline in `R/mod_sidebar.R`. The joined dataframe must pass through `R6_data_generator.R`'s `prepare_df()` (or a simplified version) to produce the simulation-ready dataframe with prix_offtake, t_ext, etc.
- [ ] T013 [US1] Manual test: upload both test CSVs, verify report appears, simulation pipeline triggers without error.

**Checkpoint**: Two-file upload works end-to-end. Import report visible. Simulation runs (even if PAC/PV not yet separated).

---

## Phase 4: User Story 2 — Détection automatique PAC (Priority: P2)

**Goal**: Automatic PAC detection via cascade (GSHP/ASHP → sous-compteur → COP/talon → fallback).

**Independent Test**: Upload Profondeville data. Report shows "Heuristique COP | P95 = ~13 kW | Talon = ~2 kW".

### Implementation for User Story 2

- [x] T014 [US2] Create `R/fct_pac_detection.R` with `detect_pac_consumption(df)` function. Input: joined dataframe with elec_kwh, cop (optional), gshp_kw (optional), ashp_kw (optional). Output: list(pac_kwh = numeric vector, method = character, p95_kw = numeric or NA, talon_w = numeric or NA).
- [x] T015 [US2] Implement cascade level (a) in `detect_pac_consumption()`: if `gshp_kw` and/or `ashp_kw` columns exist AND sum > 0, compute `pac_kwh = (gshp_kw + ashp_kw) * 0.25` (15-min energy). Set method = "sous-compteur (GSHP+ASHP)".
- [x] T016 [US2] Implement cascade level (c) in `detect_pac_consumption()`: if COP column present with > 20 values at 0 and > 20 values in (0,7), compute talon = median(elec_kwh[cop==0]), pac_kwh = pmax(0, elec_kwh - talon) when cop > 0 & cop < 7, pac_kwh = 0 otherwise. Compute p95_kw = quantile(pac_kwh[cop>0], 0.95) * 4. Set method = "heuristique COP".
- [x] T017 [US2] Implement cascade level (d) fallback: if no method applicable, set pac_kwh = elec_kwh, method = "fallback (total)", emit warning.
- [x] T018 [P] [US2] Create `tests/testthat/test-fct_pac_detection.R`. Test: with Profondeville data (GSHP/ASHP=0, COP available), method should be "heuristique COP". Test: P95 between 10-16 kW. Test: talon between 1-4 kW. Test: fallback when no COP column.
- [x] T019 [US2] Integrate `detect_pac_consumption()` into the import pipeline in `R/mod_sidebar.R`. After `join_sources()`, call detection. Add PAC method + metrics to import report. Set `pac_kwh` and `conso_hors_pac` columns in the simulation dataframe.
- [x] T020 [US2] Run full test suite + manual test with Profondeville data.

**Checkpoint**: PAC consumption correctly separated from talon. Report shows method and metrics.

---

## Phase 5: User Story 3 — PV reconstitué (Priority: P3)

**Goal**: Real PV from energy balance, stability diagnostic, Elia scaling option.

**Independent Test**: Upload Profondeville data. PV reconstructed, instability warning shown, Elia option available.

### Implementation for User Story 3

- [x] T021 [US3] Create `R/fct_pv_reconstruction.R` with `reconstruct_pv(df)` function. Input: joined dataframe with elec_kwh, offtake_kwh, feedin_kwh. Output: numeric vector `pv_reel = pmax(0, elec_kwh - offtake_kwh + feedin_kwh)`.
- [x] T022 [US3] Add `assess_pv_stability(pv_reel, timestamps, pv_elia = NULL)` to `R/fct_pv_reconstruction.R`. Computes monthly sums of pv_reel. If pv_elia provided, compute monthly ratios and CV. Returns list(stable = logical, cv = numeric, ratios = dataframe, msg = character).
- [x] T023 [P] [US3] Create `tests/testthat/test-fct_pv_reconstruction.R`. Test: pv_reel is non-negative. Test: nocturnal pv_reel ≈ 0. Test: stability assessment with Profondeville data gives CV > 30%.
- [x] T024 [US3] Integrate PV reconstruction into import pipeline in `R/mod_sidebar.R`. After join + PAC detection, call `reconstruct_pv()`. Set `pv_kwh` column. Run stability assessment if Elia data available.
- [x] T025 [US3] Add PV source selector UI in `R/mod_sidebar.R`. When PV is unstable: show warning + radio buttons ("PV reconstitué" / "PV Elia scalé"). If Elia selected, show numericInput for kWc and fetch Elia data via existing `R6_data_provider.R`.
- [x] T026 [US3] Run full test suite + manual test.

**Checkpoint**: PV reconstitué used by default. Instability detected and signaled. User can switch to Elia.

---

## Phase 6: User Story 4 — Diagnostic complet (Priority: P4)

**Goal**: Full energy diagnostic displayed in import report.

**Independent Test**: Upload Profondeville data. All 4 diagnostics visible (perimeter OK, autocons ~0%, PAC P95, PV instable).

### Implementation for User Story 4

- [x] T027 [US4] Adapt `R/fct_data_diagnostic.R` to work with the new joined dataframe format. The function `diagnose_energy_perimeter()` currently expects columns `pac_kwh, offtake_kwh, intake_kwh, pv_kwh, cop`. Map new column names (elec_kwh → pac_kwh equivalent, feedin_kwh → intake_kwh) or update the function signatures.
- [x] T028 [US4] Wire diagnostic call into import pipeline in `R/mod_sidebar.R`. After PV reconstruction, call `diagnose_energy_perimeter()` on the final dataframe. Append diagnostic results to import report.
- [ ] T029 [US4] Manual test: verify all 4 diagnostic lines appear in the import report with correct values for Profondeville.

**Checkpoint**: Full diagnostic integrated. User sees green/orange/red indicators.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Cleanup, documentation, remove dead code.

- [x] T030 [P] Remove old single-CSV parsing logic from `R/mod_sidebar.R` (dead code from previous implementation).
- [ ] T031 [P] Update `R/R6_data_generator.R` to remove the `has_pac_kwh` branch that assumed pac_kwh = PAC-only consumption. The new pipeline provides correct pac_kwh from the detection cascade.
- [ ] T032 [P] Update `vignettes/sources-de-donnees.Rmd` section 5: document the new two-CSV workflow, correct the column descriptions, reference the new parsing functions.
- [x] T033 Run full test suite: `Rscript -e "devtools::test()"`
- [ ] T034 Run quickstart.md validation: execute the manual test scenario end-to-end.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Phase 2 (parsing functions must exist)
- **US2 (Phase 4)**: Depends on US1 (needs import pipeline wired)
- **US3 (Phase 5)**: Depends on US1 (needs import pipeline), independent of US2
- **US4 (Phase 6)**: Depends on US2 + US3 (needs PAC + PV in dataframe)
- **Polish (Phase 7)**: Depends on all user stories

### User Story Dependencies

- **US1 (P1)**: Depends on Foundational only. This is the MVP.
- **US2 (P2)**: Depends on US1 (wiring in mod_sidebar).
- **US3 (P3)**: Depends on US1 (wiring in mod_sidebar). Can run in parallel with US2.
- **US4 (P4)**: Depends on US2 + US3 (needs both PAC and PV computed).

### Within Each User Story

- Functions (fct_*.R) before UI wiring (mod_sidebar.R)
- Tests in parallel with implementation (same phase, [P] marked)
- Integration test after wiring

### Parallel Opportunities

```
Phase 2:  T003 → T004 [P] + T005 [P] → T006 → T007 [P]

Phase 4:  T014 → T015, T016, T017 (sequential within cascade)
          T018 [P] (test in parallel with impl)

Phase 5:  T021 + T022 (sequential)
          T023 [P] (test in parallel)
          T024 → T025

Phase 7:  T030 [P] + T031 [P] + T032 [P] (all parallel)
```

---

## Implementation Strategy

### MVP First (US1 Only)

1. Complete Phase 1: Setup (T001-T002)
2. Complete Phase 2: Foundational (T003-T008) — parsing works
3. Complete Phase 3: US1 (T009-T013) — two-file upload end-to-end
4. **STOP and VALIDATE**: Upload test CSVs, verify import report + simulation runs
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → Parsing functions available
2. US1 → Two-file upload working → **MVP deployed**
3. US2 → PAC correctly separated → KPIs become meaningful
4. US3 → PV reconstitué → Autoconsommation KPIs correct
5. US4 → Diagnostic integrated → User confidence in data quality
6. Polish → Dead code removed, docs updated → Feature complete

---

## Notes

- No new R packages required
- All business logic in fct_*.R (Principle XI)
- mod_sidebar.R = UI wiring only
- Test data: `inst/extdata/bq_k0001_raw.csv` + `inst/extdata/bq_k0001_ores_raw.csv`
- Total: 34 tasks across 7 phases
- The existing `fct_data_diagnostic.R` is reused (US4 adapts it, doesn't rewrite)
