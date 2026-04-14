# Decision Archive

This file is the authoritative record of all significant technical decisions made during the project.
Each entry captures the full context so the reasoning can be understood and revisited later.

---

## [2026-04-14] R Shiny over Streamlit

**Context**
Wise standards mandate Streamlit for interactive data applications. However, the PAC optimizer requires:
- Native R optimization libraries (ompr, ROI, GLPK/CBC) that have no Python equivalents of the same maturity
- Advanced Plotly interactivity (linked charts, custom hovertext) easier to control from R
- R-native thermal modelling code from the original research conversation

**Options considered**

| Option | Pros | Cons |
|---|---|---|
| Streamlit (standard) | Follows Wise standards; Python ecosystem | No ompr/ROI equivalent; rewriting thermal model in Python adds risk |
| R Shiny (chosen) | Native ompr/GLPK; R thermal model; rich Plotly support | Deviation from standards; different deployment pattern |
| Plumber API + Streamlit | Follows standards for UI; R for compute | Added complexity; two services to deploy and maintain |

**Decision**: R Shiny with documented justification (deviation from Wise standards).

**Impact**
- `app.R`, `R/`, `renv.lock`, `DESCRIPTION` — full R project structure
- Deployment uses same Cloud Run target but with R-based Docker image
- Documented in `docs/adr/` and this file

**Reference**: Initial session, commit `08167dc`

---

## [2026-04-14] Belpex Prices Always Injected

**Context**
An early design had a UI toggle to enable/disable real Belpex electricity prices. The toggle added complexity and the demo is only credible when using real market prices (showing actual price arbitrage).

**Options considered**

| Option | Pros | Cons |
|---|---|---|
| Optional toggle | Flexible demo | Confusing UX; flat-price mode not useful for PAC optimization story |
| Always inject (chosen) | Simpler code; demo always credible | Less flexibility |

**Decision**: Belpex prices always loaded from `data/belpex.csv` with ENTSO-E API as fallback. No UI toggle.

**Impact**: `R/belpex.R`, `app.R` UI simplified.

**Reference**: Session 1, commit `08167dc`

---

## [2026-04-14] Demo Date Range Starts February 2025

**Context**
The local Belpex CSV downloaded from ENTSO-E starts in early 2025. Starting the demo before that date produces missing-data errors and breaks the simulation.

**Decision**: Default date range hardcoded to start February 2025 in `app.R` date inputs.

**Impact**: `app.R` default values for date range pickers.

**Reference**: Session 1 — CSV timezone debugging

---

## [2026-04-14] Day-by-Day MILP Resolution

**Context**
A monolithic MILP over the full simulation horizon (several weeks, ~2000+ time steps at 15-minute resolution) would be computationally intractable and would not finish in interactive demo time.

**Options considered**

| Option | Pros | Cons |
|---|---|---|
| Monolithic LP | Globally optimal | Intractable (>10min solve) |
| Day-by-day (chosen) | Fast per-day; manageable model size | Sub-optimal across day boundaries |
| 4-hour rolling blocks | Even faster | More boundary effects; harder to implement |

**Decision**: Solve one LP per day. Terminal temperature of day d is used as `T_init` for day d+1.

**Impact**: `R/optimizer.R` loop structure.

**Reference**: `specs/001-milp-optimizer/spec.md`, commit `da5cd41`

---

## [2026-04-14] Soft Temperature Constraints (Penalty-Based)

**Context**
Hard temperature bounds `T_min <= T_t <= T_max` caused infeasibility when ECS (hot water) events create sudden thermal spikes that the optimizer cannot avoid within a single time step. GLPK returned infeasible status, triggering 100% fallback to smart mode.

**Options considered**

| Option | Pros | Cons |
|---|---|---|
| Hard constraints | Clean formulation | Infeasible on ECS spike days; 100% fallback |
| Wider hard bounds [20, 80] | Simple fix | Physical meaninglessness; may allow unrealistic solutions |
| Soft constraints with penalty (chosen) | Always feasible; penalizes violations | More variables; slower solve |
| Pre-processing ECS events out of thermal model | Cleaner model | Complex; hides real dynamics |

**Decision**: Soft constraints — add slack variable `s_t >= 0` per time step, constraint `T_t <= T_max + s_t`, add `M * sum(s_t)` to objective with large penalty M.

**Impact**: `R/optimizer.R` — added slack variables and penalty term; model now always feasible but slower.

**Reference**: Commit `0aaabfe`, known issue: GLPK performance degraded by extra variables.

---

## [2026-04-14] ompr Status is String "success" not Integer 0

**Context**
Critical bug found during integration testing: after implementing the optimizer, 100% of days fell back to smart mode. Root cause was checking `result$status == 0` (integer comparison, copied from a code example) when ompr actually returns `result$status == "success"` (string).

**Decision**: Fix status check to `result$status == "success"`. Document as a known gotcha to prevent regression.

**Impact**: `R/optimizer.R` ~line 85. No architectural change.

**Reference**: Commit `0aaabfe` message explicitly notes this gotcha.

---

*Last updated: 2026-04-14*
