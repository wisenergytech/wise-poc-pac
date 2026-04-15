# Session Context

## Current Objective

Finalize the MILP optimizer (branch `001-milp-optimizer`) and make it production-viable: solve each day in < 0.5s, validate it produces gains >= smart mode, then merge to `main`.

---

## Branch & Git Status

- **Active branch**: `001-milp-optimizer`
- **Base branch**: `main`
- **Last commit**: `0aaabfe` — fix(001): fix optimizer status check and thermal model (2026-04-14)
- **Remote**: branch pushed to `origin/001-milp-optimizer`

---

## Modified Files (this session)

| File | Status | Description |
|---|---|---|
| `app.R` | Created | Full R Shiny app — dark theme, Plotly, multi-mode simulation, two-level UI |
| `R/belpex.R` | Created | Loads Belpex prices from local CSV or ENTSO-E API |
| `R/optimizer.R` | Created + modified | MILP optimizer using ompr + GLPK; soft constraints; proportional heat loss |
| `scripts/correct_belpex_csv.R` | Created | Fixes timezone parsing issues in raw Belpex CSV |
| `docs/business-logic-diagram.md` | Created | Mermaid diagrams for rule-based and smart mode business logic |
| `specs/001-milp-optimizer/` | Created | Speckit artifacts: spec, plan, tasks, data model, research |

---

## Test Status

| Area | Status | Notes |
|---|---|---|
| App launch (Shiny) | Completed | App runs, all tabs visible |
| Belpex CSV loading | Completed | Timezone parsing fixed, Feb 2025 start confirmed |
| Rule-based algorithm | Completed | Thermal model, decision logic, pertes calibration all fixed |
| Smart mode | Completed | Value-based decisions working |
| Insights tab | Completed | Heatmap, load shifting, waterfall charts render |
| MILP optimizer — correctness | In progress | Status bug fixed (string "success" not int 0); soft constraints added |
| MILP optimizer — performance | Blocked | ~90s/day with GLPK + soft constraints; target < 0.5s |
| MILP optimizer — validation | Pending | Need to confirm gains >= smart mode |

---

## Decisions Made This Session

### 1. R Shiny over Streamlit
- **Context**: Wise standards mandate Streamlit for data apps, but the project requires advanced interactive charts and R-native optimization libraries (ompr, GLPK).
- **Decision**: Justified deviation — R Shiny with dark theme, Plotly charts.
- **Impact**: `app.R`, `R/`, `renv.lock`, `DESCRIPTION` — full R project structure.

### 2. Belpex prices always injected (not optional)
- **Context**: Initial design allowed toggling Belpex prices on/off. Using real prices is essential for the demo to be credible.
- **Decision**: Prices are always loaded from local CSV (data/belpex.csv) with API fallback.
- **Impact**: `R/belpex.R`, `app.R` UI simplified (no toggle).

### 3. Demo starts February 2025
- **Context**: The local Belpex CSV coverage starts in early 2025. Starting the demo earlier would produce missing-data errors.
- **Decision**: Default date range set to Feb 2025 to match CSV coverage.
- **Impact**: `app.R` default date inputs.

### 4. Day-by-day MILP resolution (not monolithic)
- **Context**: A single MILP over the full simulation horizon (weeks) would be computationally intractable.
- **Decision**: Solve one LP per day, carry terminal temperature as initial condition for next day.
- **Impact**: `R/optimizer.R` loop structure.

### 5. Soft temperature constraints (penalty-based)
- **Context**: ECS (hot water) spikes in the thermal model caused hard temperature constraints to be infeasible for GLPK, resulting in 100% fallback to smart mode.
- **Decision**: Replace hard bounds on temperature with a penalty term in the objective (large coefficient * slack variable).
- **Impact**: `R/optimizer.R` — added slack variables, modified objective function.

### 6. ompr status is string "success" not integer 0
- **Context**: Critical bug: the optimizer always fell back to smart mode. Root cause was checking `result$status == 0` instead of `result$status == "success"`.
- **Decision**: Fix status check; documented in commit message as known gotcha.
- **Impact**: `R/optimizer.R` line ~85.

---

## Completed Tasks

- [x] Analyze Claude AI conversation on PAC optimization algorithms
- [x] Create full R Shiny app (app.R) with dark theme, Plotly, multiple optimization modes
- [x] Set up renv, project structure, constitution for R Shiny
- [x] Add pedagogical tooltips, explainers, and documentation modal (10 sections)
- [x] Integrate real Belpex prices from ENTSO-E (local CSV + API)
- [x] Fix CSV timezone parsing issues (scripts/correct_belpex_csv.R)
- [x] Create realistic demo scenario (thermostat baseline vs optimized)
- [x] Fix bugs in rule-based algorithms (thermal model, decision logic, pertes calibration)
- [x] Add Smart mode (value-based decisions)
- [x] Add Insights tab (heatmap, load shifting, waterfall)
- [x] Create Mermaid business logic diagrams (docs/business-logic-diagram.md)
- [x] Start MILP optimizer feature (001-milp-optimizer) via speckit workflow
- [x] Create R/optimizer.R with ompr + GLPK integration
- [x] Add two-level UI (Rule-based vs Optimiseur)
- [x] Fix ompr status check bug ("success" string)
- [x] Add proportional heat loss model (k * (T - T_amb))
- [x] Add soft temperature constraints with penalty to avoid infeasibility

---

## In Progress

- [ ] **MILP optimizer performance** — GLPK too slow (~90s/day vs target < 0.5s)
  - 17% of days currently solved by optimizer; rest fall back to smart mode
  - Root cause: soft constraints add many extra variables; GLPK is not fast enough

---

## Priority TODOs

### High

- [ ] **Fix GLPK performance** — try one or more of:
  1. Switch solver: install `ROI.plugin.cbc` (CBC is typically 10-100x faster than GLPK)
  2. Reduce model size: solve 4-hour blocks instead of full 24h days
  3. Compact formulation: eliminate redundant constraints or reformulate soft constraints
  - File: `R/optimizer.R`
  - Acceptance: < 0.5s per day, > 50% days solved by optimizer (not fallback)

- [ ] **Validate optimizer gains** — confirm optimizer mode produces cost savings >= smart mode across the full demo period
  - Add a summary metrics table or assertion in the Insights tab

- [ ] **Merge 001-milp-optimizer to main** — once optimizer works and is validated
  - Run: `git checkout main && git merge 001-milp-optimizer`

### Medium

- [ ] **Update Mermaid diagrams** — add optimizer flow to `docs/business-logic-diagram.md`
  - Show day-by-day loop, soft constraints, fallback logic

- [ ] **Add optimizer explanation** to documentation modal in `app.R` (section 11)

- [ ] **Write unit tests** for `R/optimizer.R` — at minimum test one day of known input/output

### Backlog

- [ ] **Cloud Run deployment** — run `make deploy` once app is stable
- [ ] **API mode for Belpex** — validate ENTSO-E API key works end-to-end (currently using CSV only)
- [ ] **Performance profiling** — add timing logs per optimizer call to monitor solver duration in production

---

## Known Issues & Blockers

| Issue | Severity | Notes |
|---|---|---|
| GLPK too slow with soft constraints | Blocker | ~90s/day; makes optimizer unusable in demo |
| 17% optimizer solve rate | Blocker (consequence) | Demo falls back to smart mode for 83% of days |
| CBC solver not yet installed | Dependency | Need `ROI.plugin.cbc` R package + system `coinor-cbc` |

---

## Technical Notes

- **Thermal model**: proportional heat loss `k * (T - T_amb)`, calibrated to match demo pertes values.
- **ompr version note**: `result$status` returns `"success"` (character), not `0` (integer). Do not regress on this.
- **Soft constraint pattern** in ompr: add slack variable `s_t >= 0`, add `T_t <= T_max + s_t` (hard), add `M * s_t` to objective (penalty). M should be large relative to energy cost (try M = 1000).
- **Day-by-day loop**: `T_init` for day d+1 = last `T_t` of day d from optimizer solution (or smart mode fallback).
- **Belpex CSV**: located at `data/belpex.csv`; UTC timestamps; preprocessed by `scripts/correct_belpex_csv.R`.

## Useful Commands

```bash
# Launch app locally
make run

# Check env vars
make check-env

# Sync standards from wise-standards
make sync-standards

# Run CBC solver install (attempt)
Rscript -e "install.packages('ROI.plugin.cbc')"

# Run app in non-interactive R for profiling
Rscript -e "source('R/optimizer.R'); run_optimizer_day(day_data)"
```

---

## External Dependencies

| Dependency | Status | Notes |
|---|---|---|
| ENTSO-E API key | Available | Loaded from `.env`; currently bypassed by local CSV |
| coinor-cbc (system) | Not installed | Required for `ROI.plugin.cbc` |
| ompr / ompr.roi | Installed | In `renv.lock` |
| ROI.plugin.glpk | Installed | Too slow for production use |

---

## Relevant Files

- `app.R` — main Shiny application
- `R/optimizer.R` — MILP optimizer (day-by-day, ompr + GLPK)
- `R/belpex.R` — Belpex price loader
- `scripts/correct_belpex_csv.R` — CSV timezone fix
- `docs/business-logic-diagram.md` — Mermaid diagrams
- `specs/001-milp-optimizer/spec.md` — feature specification
- `specs/001-milp-optimizer/tasks.md` — task list
- `docs/SESSION_CONTEXT.md` — this file
- `docs/DECISIONS.md` — decision archive
- `docs/SESSIONS_LOG.md` — session history
