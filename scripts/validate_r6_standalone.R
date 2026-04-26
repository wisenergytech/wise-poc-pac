#!/usr/bin/env Rscript
# =============================================================================
# Validate R6 classes work standalone (without Shiny)
# This script demonstrates that the business logic is fully independent.
# =============================================================================

cat("=== R6 Standalone Validation (no Shiny) ===\n\n")

# Load only R6 + dependencies (NOT shiny)
library(R6)
library(dplyr)
library(lubridate)
library(readr)
library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)

# Source R6 classes and helpers
source("R/fct_helpers.R")
source("R/R6_params.R")
source("R/R6_thermal_model.R")
source("R/R6_data_provider.R")
source("R/R6_data_generator.R")
source("R/R6_baseline.R")
source("R/data_entsoe_prices.R")
source("R/data_openmeteo_temperature.R")
source("R/R6_optimizer.R")
source("R/optimizer_lp.R")
source("R/R6_kpi.R")
source("R/R6_simulation.R")

cat("1. Libraries loaded (no shiny)\n")

# Create params
params <- SimulationParams$new(
  p_pac_kw = 60, cop_nominal = 3.5,
  volume_ballon_l = 36100,
  type_contrat = "dynamique",
  baseline_mode = "ingenieur",
  pv_kwc = 33, pv_kwc_ref = 33,
  optim_bloc_h = 24, slack_penalty = 2.5
)
cat("2. SimulationParams created\n")
cat(sprintf("   Volume: %d L | T range: [%d, %d]C\n",
  params$volume_ballon_l, params$t_min, params$t_max))

# Create simulation
sim <- Simulation$new(params)
cat("3. Simulation object created\n")

# Load demo data
sim$load_data("demo", date_start = as.Date("2025-06-01"), date_end = as.Date("2025-07-31"))
cat(sprintf("4. Demo data loaded: %d rows\n", nrow(sim$get_prepared_data())))

# Run baseline
sim$run_baseline()
cat("5. Baseline (ingenieur) computed\n")

# Run LP optimization
sim$run_optimization("lp")
cat("6. LP optimization completed\n")

# Get KPIs
kpi <- sim$get_kpi()
cat("\n=== RESULTS ===\n")
cat(sprintf("  Facture baseline : %.1f EUR\n", kpi$facture_baseline))
cat(sprintf("  Facture optimisee: %.1f EUR\n", kpi$facture_opti))
cat(sprintf("  Gain             : %.1f EUR (%.1f%%)\n", kpi$gain_eur, kpi$gain_pct))
cat(sprintf("  Autoconso base   : %.1f%%\n", kpi$ac_baseline))
cat(sprintf("  Autoconso opti   : %.1f%%\n", kpi$ac_opti))

# Verify two independent simulations don't share state
cat("\n=== ISOLATION TEST ===\n")
params2 <- SimulationParams$new(p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6, pv_kwc_ref = 6)
sim2 <- Simulation$new(params2)
sim2$load_data("demo", date_start = as.Date("2025-06-01"), date_end = as.Date("2025-07-31"))
sim2$run_baseline()
# Compare baseline factures (don't need optimization for isolation check)
fb1 <- kpi$facture_baseline
baseline2 <- sim2$get_baseline()
pv2 <- sum(sim2$get_prepared_data()$pv_kwh, na.rm = TRUE)
fb2 <- sum(baseline2$offtake_kwh * baseline2$prix_offtake - baseline2$intake_kwh * baseline2$prix_injection, na.rm = TRUE)
cat(sprintf("  Sim1 (60kW) facture baseline: %.1f EUR\n", fb1))
cat(sprintf("  Sim2 (2kW)  facture baseline: %.1f EUR\n", fb2))
stopifnot(abs(fb1 - fb2) > 10)
cat("  Isolation OK: different results, no shared state\n")

cat("\n=== ALL CHECKS PASSED ===\n")
