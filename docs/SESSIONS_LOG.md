# Sessions Log

Historical record of work sessions. Most recent session at the top.

---

## Session 1 — 2026-04-14

**Focus**: Full project bootstrap + MILP optimizer feature start

**Accomplishments**

- Analyzed Claude AI research conversation on PAC (heat pump) optimization algorithms
- Created complete R Shiny app (`app.R`) with dark theme, Plotly interactive charts, and four simulation modes (Thermostat, Règle, Smart, Optimiseur)
- Set up R project structure: `renv`, `DESCRIPTION`, `renv.lock`
- Added pedagogical tooltips, in-app explainers, and a 10-section documentation modal
- Integrated real Belpex electricity prices from ENTSO-E (local CSV + API fallback via `R/belpex.R`)
- Fixed timezone parsing bugs in Belpex CSV (created `scripts/correct_belpex_csv.R`)
- Built realistic demo scenario: thermostat baseline vs optimized modes
- Fixed multiple bugs in rule-based algorithm: thermal model calibration, decision logic, pertes calibration
- Added Smart mode (value-based decisions using Belpex price signal)
- Added Insights tab with heatmap, load shifting, and waterfall charts
- Created Mermaid business logic diagrams (`docs/business-logic-diagram.md`)
- Ran full speckit workflow for MILP feature: spec, plan, tasks, ADRs
- Created `R/optimizer.R` with ompr + GLPK integration and day-by-day resolution
- Added two-level UI: Rule-based tab vs Optimiseur tab
- Fixed critical bug: ompr returns `"success"` string, not integer `0`
- Added proportional heat loss model and soft temperature constraints

**Major decisions**
- R Shiny over Streamlit (justified deviation)
- Belpex always injected (no toggle)
- Day-by-day MILP resolution
- Soft temperature constraints to handle ECS infeasibility
- Demo starts Feb 2025 to match CSV coverage

**Commits**
- `08167dc` — feat: initial PAC optimizer Shiny app with multi-mode simulation
- `9b14eaf` — docs: add Mermaid business logic diagrams
- `da5cd41` — feat(001): add MILP optimizer mode using ompr + GLPK
- `0aaabfe` — fix(001): fix optimizer status check and thermal model

**Next steps identified**
1. Fix GLPK performance: try CBC solver or 4-hour block formulation
2. Validate optimizer gains >= smart mode
3. Update Mermaid diagrams with optimizer flow
4. Merge `001-milp-optimizer` to `main` once optimizer works

---

*Log started: 2026-04-14*
