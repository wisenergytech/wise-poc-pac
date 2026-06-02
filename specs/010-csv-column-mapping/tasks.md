# Tasks: CSV Column Mapping dynamique

**Input**: Design documents from `specs/010-csv-column-mapping/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md

**Tests**: Not explicitly requested. Foundational matching logic will be validated via quickstart.md.

**Organization**: US1 (mapping) and US2 (pre-suggestion) are tightly coupled (same P1) — combined in one phase. US3 (PAC config) and US4 (explorer) are P2, independent.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

---

## Phase 1: Setup

**Purpose**: No new dependencies. Nothing to setup.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure function for column matching — used by both mapping UI and pre-suggestion.

- [x] T001 Create `suggest_column_mapping()` in R/fct_csv_mapping.R — pure function (no Shiny dependency). Takes a character vector of CSV column names, returns a named list mapping target fields to suggested source columns (or NA). Use keyword regex matching from research.md R1. Target fields: timestamp, pv_kwh, offtake_kwh, feedin_kwh, pac1_kwh, pac2_kwh, pac_kwh, t_ballon, t_sol, t_ext. Include PAC type detection: if pac1_kwh matched "gshp" -> suggest pac1_type="gshp", etc.
- [x] T002 Create `apply_column_mapping()` in R/fct_csv_mapping.R — pure function. Takes a dataframe + a named list (mapping), renames columns from source to target names. Keeps unmapped columns as-is. Returns the renamed dataframe.
- [x] T003 Create `detect_auto_mappable()` in R/fct_csv_mapping.R — pure function. Takes a mapping result, returns TRUE if all required fields (timestamp, pv_kwh, offtake_kwh, feedin_kwh/intake_kwh) have exact name matches. Used to decide if mapping panel should auto-collapse.

**Checkpoint**: `suggest_column_mapping(names(readr::read_csv("data/bq_k0001_dual_pac.csv", n_max=0)))` returns correct mapping for all fields.

---

## Phase 3: User Story 1+2 — Mapper les colonnes + Pre-suggestion (Priority: P1)

**Goal**: User imports a CSV, mapping panel appears with pre-filled suggestions, user can adjust and launch simulation.

**Independent Test**: Import `bq_k0001_dual_pac.csv`, all fields auto-mapped, simulation runs without manual adjustment.

### Implementation

- [x] T004 [US1] Add mapping UI panel in R/mod_sidebar.R — inside the `conditionalPanel(data_source == "csv")` block, after file upload: add a collapsible panel "Mapping colonnes" with one `selectInput` per target field (timestamp, PV, offtake, feedin, PAC 1, PAC 2, t_ballon, t_sol, t_ext). Each selectInput has choices = NULL (populated server-side). Include a "Non disponible" option.
- [x] T005 [US1] Add server-side mapping logic in R/mod_sidebar.R — `observeEvent(input$csv_file)`: read CSV header with `names(readr::read_csv(path, n_max=0))`, call `suggest_column_mapping()`, call `updateSelectInput()` for each field with choices = csv_columns + "—" and selected = suggestion. If `detect_auto_mappable()` is TRUE, collapse the mapping panel.
- [x] T006 [US1] Refactor `compute_raw_data()` in R/mod_sidebar.R — replace the hardcoded column name validation (lines 676-689) with: read CSV, get mapping from input selectors, call `apply_column_mapping()`, then proceed with the renamed dataframe. Keep the existing import report logic but adapt it to use the mapped names.
- [x] T007 [US1] Add validation before simulation in R/mod_sidebar.R — check that required fields (timestamp + at least offtake or feedin) are mapped (not "—"). Show notification if missing. Prevent simulation launch.

**Checkpoint**: Import CSV with non-standard names, map manually, simulate — works. Import standard CSV — auto-mapped, simulate — works.

---

## Phase 4: User Story 3 — Configurer chaque PAC independamment (Priority: P2)

**Goal**: When a PAC column is mapped, show config controls (type, mode, puissance, COP) for that PAC.

**Independent Test**: Map gshp_kwh to PAC 1, configure as GSHP on/off 40kWth, map ashp_kwh to PAC 2, configure as ASHP inverter 24kWth. DualOptimizer uses these params.

### Implementation

- [x] T008 [US3] Add conditional PAC config in R/mod_sidebar.R — for PAC 1 and PAC 2 mapped columns: show type (ASHP/GSHP), mode (on/off, inverter), puissance thermique, COP nominal. Only visible when the corresponding PAC selectInput is not "—". Pre-fill type based on `suggest_column_mapping()` PAC type detection (if "gshp" matched -> pre-select GSHP).
- [x] T009 [US3] Wire PAC config from mapping into params_r() in R/mod_sidebar.R — read pac1_type, pac1_mode, cop_nominal, p_pac_th_kw from the mapping config controls. If PAC 2 is mapped, set pac2_active=TRUE and read pac2_type, pac2_mode, cop2_nominal, p_pac2_kw from PAC 2 config controls.

**Checkpoint**: Map two PAC columns, configure each, simulate — DualOptimizer uses correct params per PAC.

---

## Phase 5: User Story 4 — Explorer les colonnes reelles du CSV (Priority: P2)

**Goal**: Data explorer dropdowns show actual CSV column names.

**Independent Test**: Import a CSV with 13 columns, open Comparaison tab, see all 13 numeric columns in dropdowns.

### Implementation

- [x] T010 [US4] Add reactive CSV columns to mod_comparaison.R — create a reactive that stores the numeric column names from the imported CSV. When data_source == "csv", prepend these as a "CSV Import" group in the vars list. When data_source == "demo", use hardcoded vars as before.
- [x] T011 [US4] Update `vars_baseline` and `vars_optimised` dynamically in R/mod_comparaison.R — after simulation, merge CSV column names + simulation-generated columns (sim_offtake, sim_t_ballon, etc.) into the dropdown choices. Use `shiny::updateSelectInput()` to refresh.

**Checkpoint**: Import CSV, simulate, open explorer — see both CSV columns and simulation columns in dropdowns.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T012 Verify backward compatibility: import a CSV in old format (timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh), verify mapping auto-collapses and simulation works identically to before
- [x] T013 Verify dual PAC flow: import bq_k0001_dual_pac.csv, verify gshp_kwh -> PAC 1 (GSHP), ashp_kwh -> PAC 2 (ASHP), DualOptimizer activates automatically
- [x] T014 Test edge case: import CSV with unknown column names (col_A, col_B), verify no pre-suggestion, user can map manually
- [x] T015 Test edge case: import new CSV mid-session, verify mapping resets and re-suggests

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 2 (Foundation)**: No dependencies — start immediately
- **Phase 3 (US1+2 Mapping)**: Depends on Phase 2 (needs `fct_csv_mapping.R`)
- **Phase 4 (US3 PAC Config)**: Depends on Phase 3 (needs mapping UI)
- **Phase 5 (US4 Explorer)**: Depends on Phase 3 (needs CSV column list). Can run in parallel with Phase 4.
- **Phase 6 (Polish)**: Depends on all phases

### User Story Dependencies

```
Phase 2 (Foundation: fct_csv_mapping.R)
  └─> Phase 3 (US1+2: Mapping UI + pre-suggestion)
        ├─> Phase 4 (US3: PAC config per mapping)  ─┐
        └─> Phase 5 (US4: Explorer dynamic)  ────────┤
                                                      └─> Phase 6 (Polish)
```

### Parallel Opportunities

- **Phase 4 + Phase 5** can run in parallel (different files: mod_sidebar vs mod_comparaison)

---

## Implementation Strategy

### MVP First (US1+2)

1. Phase 2: Foundation (`fct_csv_mapping.R`)
2. Phase 3: Mapping UI + pre-suggestion
3. **STOP and VALIDATE**: Import bq_k0001_dual_pac.csv → auto-mapped → simulate

### Full Feature

4. Phase 4: PAC config per mapping
5. Phase 5: Explorer dynamic columns
6. Phase 6: Polish + edge cases

---

## Notes

- All matching logic in `fct_csv_mapping.R` (pure function, testable without Shiny — Constitution XI)
- No new R packages needed (Constitution X)
- Demo mode completely unchanged (FR-009)
- Existing mod_sidebar.R CSV handling refactored, not rewritten from scratch
