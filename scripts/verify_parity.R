# =============================================================================
# Script: Verify R6 parity with reference values (T023-T024)
# =============================================================================
# Runs the R6 Simulation class with the same parameters as the reference
# capture, then compares results. Reports pass/fail for each KPI.
# =============================================================================

setwd("/home/pokyah/wise/wise-poc-pac")

library(dplyr)
library(readr)
library(lubridate)
library(tidyr)
library(R6)
library(httr)
library(xml2)
library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)

# Load .env
if (file.exists(".env")) {
  env_lines <- readLines(".env", warn = FALSE)
  for (line in env_lines) {
    line <- trimws(line)
    if (nchar(line) == 0 || startsWith(line, "#")) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      val <- trimws(paste(parts[-1], collapse = "="))
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

# Source R6 classes and dependencies
source("R/fct_helpers.R")
source("R/belpex.R")
source("R/openmeteo.R")
source("R/optimizer_lp.R")
tryCatch(source("R/optimizer_milp.R"), error = function(e) message("[skip] optimizer_milp.R: ", e$message))
source("R/optimizer_qp.R")
source("R/R6_data_provider.R")
source("R/R6_data_generator.R")
source("R/R6_thermal_model.R")
source("R/R6_baseline.R")
source("R/R6_optimizer.R")
source("R/R6_kpi.R")
source("R/R6_simulation.R")

# Load reference values
ref_path <- "tests/testthat/fixtures/reference_values.rds"
if (!file.exists(ref_path)) {
  stop("Reference values not found. Run scripts/capture_reference.R first.")
}
ref <- readRDS(ref_path)

cat("=== Reference Values ===\n")
str(ref)

# Run R6 Simulation with same parameters
params <- list(
  t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
  p_pac_kw = 60, cop_nominal = 3.5, t_ref_cop = 7,
  volume_ballon_l = 36100, capacite_kwh_par_degre = 36100 * 0.001163,
  horizon_qt = 16, seuil_surplus_pct = 0.3, dt_h = 0.25,
  type_contrat = "dynamique", taxe_transport_eur_kwh = 0.15, coeff_injection = 1.0,
  prix_fixe_offtake = 0.30, prix_fixe_injection = 0.03,
  perte_kwh_par_qt = 0.05, pv_kwc = 33, pv_kwc_ref = 33,
  batterie_active = FALSE, batt_kwh = 0, batt_kw = 0, batt_rendement = 0.9,
  batt_soc_min = 0.1, batt_soc_max = 0.9,
  poids_cout = 0.5, slack_penalty = 2.5, optim_bloc_h = 24,
  curtailment_active = FALSE, curtail_kwh_per_qt = Inf
)

cat("\n=== Running R6 Simulation ===\n")
cat("Creating Simulation...\n")
sim <- Simulation$new(params)

cat("Loading demo data (June-Aug 2025)...\n")
sim$load_data(
  source = "demo",
  date_start = as.Date("2025-06-01"),
  date_end = as.Date("2025-08-31"),
  p_pac_kw = 60, volume_ballon_l = 36100, pv_kwc = 33
)

cat("Running baseline (ingenieur)...\n")
sim$run_baseline(mode = "ingenieur")

cat("Running LP optimization...\n")
t0 <- Sys.time()
sim$run_optimization(mode = "lp")
elapsed <- difftime(Sys.time(), t0, units = "secs")
cat(sprintf("  Done in %.1f seconds\n", as.numeric(elapsed)))

cat("\nComputing KPIs...\n")
kpis <- sim$get_kpi()

cat("\n=== R6 KPI Values ===\n")
cat(sprintf("  facture_baseline: %.2f\n", kpis$facture_baseline))
cat(sprintf("  facture_opti:     %.2f\n", kpis$facture_opti))
cat(sprintf("  gain_eur:         %.2f\n", kpis$gain_eur))
cat(sprintf("  ac_baseline:      %.1f%%\n", kpis$ac_baseline))
cat(sprintf("  ac_opti:          %.1f%%\n", kpis$ac_opti))
cat(sprintf("  pv_total:         %.1f kWh\n", kpis$pv_total))

# Compare with reference
cat("\n=== Parity Check (tolerance: 0.1%) ===\n")
tol <- 0.001
all_pass <- TRUE

check <- function(name, actual, expected, tolerance_abs = NULL) {
  if (is.null(tolerance_abs)) {
    tolerance_abs <- abs(expected) * tol + 0.01
  }
  diff <- abs(actual - expected)
  pass <- diff <= tolerance_abs
  status <- if (pass) "PASS" else "FAIL"
  cat(sprintf("  [%s] %s: R6=%.4f, ref=%.4f, diff=%.4f (tol=%.4f)\n",
    status, name, actual, expected, diff, tolerance_abs))
  if (!pass) all_pass <<- FALSE
  pass
}

check("facture_baseline", kpis$facture_baseline, ref$facture_baseline)
check("facture_opti", kpis$facture_opti, ref$facture_opti)
check("gain_eur", kpis$gain_eur, ref$gain_eur)
check("ac_baseline", kpis$ac_baseline, ref$ac_baseline, tolerance_abs = 0.2)
check("ac_opti", kpis$ac_opti, ref$ac_opti, tolerance_abs = 0.2)
check("pv_total", kpis$pv_total, ref$pv_total)

cat("\n")
if (all_pass) {
  cat("=== ALL CHECKS PASSED ===\n")
} else {
  cat("=== SOME CHECKS FAILED ===\n")
  quit(status = 1)
}
