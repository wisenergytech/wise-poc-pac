# Quickstart: Dual PAC Optimizer

**Feature**: `009-dual-pac-optimizer`
**Date**: 2026-05-21

## Prerequisites

No new R packages required. The existing stack (ompr, ompr.roi, ROI.plugin.highs, R6) handles everything.

## Running the dual optimizer standalone (for testing)

```r
# Source required files
source("R/fct_helpers.R")         # calc_cop, calc_cop_gshp
source("R/optimizer_dual.R")      # solve_block_dual
source("R/R6_optimizer.R")        # DualOptimizer class
source("R/R6_thermal_model.R")    # ThermalModel

# Prepare params (extend existing params with PAC 2)
params <- list(
  # PAC 1 (existing)
  p_pac_kw = 20,
  cop_nominal = 4.5,
  t_ref_cop = 10,
  pac1_type = "gshp",
  pac1_mode = "onoff",

  # PAC 2 (new)
  pac2_active = TRUE,
  p_pac2_kw = 40,
  cop2_nominal = 3.5,
  t_ref_cop2 = 7,
  pac2_type = "ashp",
  pac2_mode = "inverter",
  ramp_max = 0.3,

  # Thermal
  volume_ballon_l = 2500,
  capacite_kwh_par_degre = 2500 * 0.001163,
  t_min = 45, t_max = 65, t_consigne = 55,
  dt_h = 0.25,
  optim_bloc_h = 4,

  # Battery (optional)
  batterie_active = FALSE,

  # T_sol
  t_sol_method = "constant",
  t_sol_constant = 10
)

# Load or generate data (must have t_ext, pv_kwh, conso_hors_pac, prix_offtake, etc.)
df <- readRDS("data/demo_data.rds")

# Run dual optimizer
optimizer <- DualOptimizer$new(params, df)
results <- optimizer$solve()
results <- optimizer$guard_baseline(df)

# Check PAC dispatch
summary(results$sim_pac1_on)    # PAC 1: binary 0/1
summary(results$sim_pac2_load)  # PAC 2: continuous 0-1
sum(results$sim_pac1_kwh)       # Total kWh PAC 1
sum(results$sim_pac2_kwh)       # Total kWh PAC 2
```

## Running via Shiny app

1. Launch the app: `golem::run_app()`
2. In the sidebar, toggle "PAC 2" to ON
3. Configure PAC 2 parameters (type, power, mode)
4. Select solver = "Dual" in the optimizer dropdown
5. Click "Simuler"
6. Check the Comparaison tab for PAC 1/PAC 2 ventilation

## Key files to read

| File | What to understand |
|------|--------------------|
| `R/optimizer_milp.R` | Existing MILP pattern (binary + battery) — the dual extends this |
| `R/R6_optimizer.R` | BaseOptimizer block loop + COP iterative — DualOptimizer inherits this |
| `R/fct_helpers.R:14-23` | Existing `calc_cop()` — model for `calc_cop_gshp()` |
| `docs/knowledge/coupled-ashp-gshp-optimization.md` | Literature review and MILP formulation |
