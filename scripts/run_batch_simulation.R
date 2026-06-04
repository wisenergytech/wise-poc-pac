#!/usr/bin/env Rscript
# =============================================================================
# Batch simulation script — runs optimization outside of Shiny
# =============================================================================
# Usage:
#   Rscript scripts/run_batch_simulation.R
#   Rscript scripts/run_batch_simulation.R --output results/my_run.rds
#   Rscript scripts/run_batch_simulation.R --bloc 6
#
# The output RDS is importable directly in the Shiny app (Importer RDS).
# Run multiple instances in parallel with different parameters.
# =============================================================================

# ---- Load the app package ----
devtools::load_all(".")

# =============================================================================
# PARAMETERS — Edit these to configure your simulation
# =============================================================================

# -- Data source --
csv_path <- "data/bq_k0001_dual_pac_full.csv"

# -- Ballon thermique --
t_consigne   <- 35    # Consigne temperature (C)
t_tolerance  <- 5     # +/- tolerance (C) -> T_min=30, T_max=40
volume_ballon_l <- 2500  # Volume ballon (L)

# -- PAC 1 (GSHP) --
pac1_th_kw   <- 40    # Puissance thermique (kWth)
cop1_nominal <- 4.0   # COP nominal
pac1_type    <- "gshp" # "gshp" or "ashp"
pac1_mode    <- "onoff" # "onoff" or "inverter"

# -- PAC 2 (ASHP) --
pac2_active  <- TRUE
pac2_th_kw   <- 24    # Puissance thermique (kWth)
cop2_nominal <- 3.0   # COP nominal
pac2_type    <- "ashp"
pac2_mode    <- "onoff"
ramp_max     <- 0.3   # Rampe max (only for inverter)

# -- Contrat --
type_contrat <- "dynamique"  # "dynamique", "fixe", or "belix"
prix_fixe_offtake   <- 0.30  # EUR/kWh (only for fixe)
prix_fixe_injection <- 0.03  # EUR/kWh (only for fixe)

# -- Optimisation --
optim_bloc_h   <- 6     # Block duration: 6, 12, or 24 (hours)
slack_penalty  <- 2.5   # EUR/degre sous T_min
min_cycle_min  <- 45    # Duree min cycle on/off (minutes, 0=disabled)
tou_active     <- TRUE  # Time-of-Use optimization

# -- PV --
pv_kwc_ref <- 42  # Puissance PV (kWc)

# -- Batterie (optional) --
batterie_active <- FALSE
batt_kwh        <- 0
batt_kw         <- 0
batt_rendement  <- 90   # %
batt_soc_min    <- 10   # %
batt_soc_max    <- 90   # %

# -- Curtailment (optional) --
curtailment_active <- FALSE
curtail_kw         <- 0

# -- Output --
output_path <- NULL  # NULL = auto-generated filename

# =============================================================================
# CLI argument override (optional)
# =============================================================================
args <- commandArgs(trailingOnly = TRUE)
i <- 1
while (i <= length(args)) {
  switch(args[i],
    "--csv"       = { csv_path <- args[i + 1]; i <- i + 1 },
    "--output"    = { output_path <- args[i + 1]; i <- i + 1 },
    "--bloc"      = { optim_bloc_h <- as.numeric(args[i + 1]); i <- i + 1 },
    "--t_consigne" = { t_consigne <- as.numeric(args[i + 1]); i <- i + 1 },
    "--t_tolerance" = { t_tolerance <- as.numeric(args[i + 1]); i <- i + 1 },
    "--pac1_kw"   = { pac1_th_kw <- as.numeric(args[i + 1]); i <- i + 1 },
    "--pac2_kw"   = { pac2_th_kw <- as.numeric(args[i + 1]); i <- i + 1 },
    "--cop1"      = { cop1_nominal <- as.numeric(args[i + 1]); i <- i + 1 },
    "--cop2"      = { cop2_nominal <- as.numeric(args[i + 1]); i <- i + 1 },
    "--slack"     = { slack_penalty <- as.numeric(args[i + 1]); i <- i + 1 },
    "--min_cycle" = { min_cycle_min <- as.numeric(args[i + 1]); i <- i + 1 },
    "--no_pac2"   = { pac2_active <- FALSE },
    "--no_tou"    = { tou_active <- FALSE },
    message(sprintf("Unknown argument: %s", args[i]))
  )
  i <- i + 1
}

# =============================================================================
# EXECUTION — Don't edit below unless you know what you're doing
# =============================================================================

cat(sprintf("=== Batch Simulation ===\n"))
cat(sprintf("CSV:          %s\n", csv_path))
cat(sprintf("PAC1:         %s %s %.0f kWth, COP %.1f\n", pac1_type, pac1_mode, pac1_th_kw, cop1_nominal))
if (pac2_active) {
  cat(sprintf("PAC2:         %s %s %.0f kWth, COP %.1f\n", pac2_type, pac2_mode, pac2_th_kw, cop2_nominal))
} else {
  cat("PAC2:         disabled\n")
}
cat(sprintf("Ballon:       %d L, consigne %d C +/- %d C\n", volume_ballon_l, t_consigne, t_tolerance))
cat(sprintf("Bloc:         %dh | Cycle min: %d min | Slack: %.1f\n", optim_bloc_h, min_cycle_min, slack_penalty))
cat(sprintf("Contrat:      %s | TOU: %s\n", type_contrat, tou_active))
cat("========================\n\n")

# ---- Read and map CSV ----
cat("[1/4] Loading CSV...\n")
raw_df <- readr::read_csv(csv_path, show_col_types = FALSE)
mapping_result <- suggest_column_mapping(names(raw_df))
df <- apply_column_mapping(as.data.frame(raw_df), mapping_result$mapping)

# Compute pac_kwh if dual PAC columns present
if (all(c("pac1_kwh", "pac2_kwh") %in% names(df)) && !"pac_kwh" %in% names(df)) {
  df$pac_kwh <- df$pac1_kwh + df$pac2_kwh
}

# Parse timestamp
if (!inherits(df$timestamp, "POSIXct")) {
  df$timestamp <- lubridate::ymd_hms(df$timestamp, quiet = TRUE)
}
df$timestamp <- lubridate::with_tz(df$timestamp, "Europe/Brussels")
cat(sprintf("   %d rows, %s -> %s\n", nrow(df),
    format(min(df$timestamp), "%Y-%m-%d"), format(max(df$timestamp), "%Y-%m-%d")))

# ---- Build params ----
cat("[2/4] Building parameters...\n")
pac1_elec_kw <- pac1_th_kw / cop1_nominal
pac2_elec_kw <- if (pac2_active) pac2_th_kw / cop2_nominal else 0

params <- list(
  dt_h = 0.25,
  t_consigne = t_consigne,
  t_tolerance = t_tolerance,
  t_min = t_consigne - t_tolerance,
  t_max = t_consigne + t_tolerance,
  p_pac_kw = pac1_elec_kw,
  p_pac_th_kw = pac1_th_kw,
  cop_nominal = cop1_nominal,
  t_ref_cop = 7,
  volume_ballon_l = volume_ballon_l,
  capacite_kwh_par_degre = volume_ballon_l * 0.001163,
  pv_kwc = pv_kwc_ref,
  pv_kwc_ref = pv_kwc_ref,
  type_contrat = type_contrat,
  prix_fixe_offtake = prix_fixe_offtake,
  prix_fixe_injection = prix_fixe_injection,
  taxe_transport_eur_kwh = 0.10,
  coeff_injection = 0.95,
  tou_active = tou_active,
  optim_bloc_h = optim_bloc_h,
  slack_penalty = slack_penalty,
  min_cycle_min = min_cycle_min,
  min_cycle_qt = ceiling(min_cycle_min / 15),
  pac1_type = pac1_type,
  pac1_mode = pac1_mode,
  pac2_active = pac2_active,
  pac2_type = pac2_type,
  pac2_mode = pac2_mode,
  p_pac2_kw = pac2_elec_kw,
  p_pac2_th_kw = pac2_th_kw,
  cop2_nominal = cop2_nominal,
  t_ref_cop2 = 7,
  ramp_max = ramp_max,
  t_sol_method = "annual_mean",
  t_sol_constant = 9,
  batterie_active = batterie_active,
  batt_kwh = batt_kwh,
  batt_kw = batt_kw,
  batt_rendement = batt_rendement / 100,
  batt_soc_min = batt_soc_min / 100,
  batt_soc_max = batt_soc_max / 100,
  curtailment_active = curtailment_active,
  curtail_kwh_per_qt = if (curtailment_active) curtail_kw * 0.25 else Inf,
  poids_cout = 0.5,
  autoconso_cible = 35
)

# ---- Select mode and run ----
mode <- if (pac2_active) "dual" else if (pac1_mode == "onoff") "milp" else "lp"
cat(sprintf("[3/4] Running %s optimization (%dh blocks)...\n", toupper(mode), optim_bloc_h))

t0 <- Sys.time()
result <- run_simulation(df, params, mode = mode, baseline_mode = "measured")
elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

cat(sprintf("   Done in %.1f seconds (%d blocks)\n", elapsed,
    ceiling(nrow(df) / (optim_bloc_h * 4))))

# ---- Compute KPIs ----
sim <- result$sim
if (!is.null(sim)) {
  facture_bl <- sum(sim$offtake_kwh * sim$prix_offtake - sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
  facture_op <- sum(sim$sim_offtake * sim$prix_offtake - sim$sim_intake * sim$prix_injection, na.rm = TRUE)
  gain <- facture_bl - facture_op
  cat(sprintf("\n--- Results ---\n"))
  cat(sprintf("Facture baseline:  %.0f EUR\n", facture_bl))
  cat(sprintf("Facture optimisee: %.0f EUR\n", facture_op))
  cat(sprintf("Gain:              %.0f EUR (%.1f%%)\n", gain, gain / facture_bl * 100))
  cat(sprintf("Soutirage BL:      %.0f kWh\n", sum(sim$offtake_kwh, na.rm = TRUE)))
  cat(sprintf("Soutirage OP:      %.0f kWh\n", sum(sim$sim_offtake, na.rm = TRUE)))
}

# ---- Save RDS (app-compatible) ----
if (is.null(output_path)) {
  dir.create("results", showWarnings = FALSE)
  output_path <- sprintf("results/sim_%s_bloc%dh_%s.rds",
    mode, optim_bloc_h, format(Sys.time(), "%Y%m%d_%H%M%S"))
}

# Build same bundle structure as the Shiny app export
bundle <- list(
  sim_result = list(
    sim = result$sim,
    df = result$df,
    params = result$params,
    mode = result$mode
  ),
  raw_data = df,
  csv_original_columns = names(raw_df),
  csv_mapping_result = mapping_result,
  sidebar_inputs = list(
    t_consigne = t_consigne,
    t_tolerance = t_tolerance,
    volume_auto = FALSE,
    volume_ballon_manual = volume_ballon_l,
    p_pac_th_kw = pac1_th_kw,
    cop_nominal = cop1_nominal,
    pac1_type = pac1_type,
    pac1_mode = pac1_mode,
    pac2_active = pac2_active,
    p_pac2_th_kw = pac2_th_kw,
    cop2_nominal = cop2_nominal,
    pac2_type = pac2_type,
    pac2_mode = pac2_mode,
    ramp_max = ramp_max,
    type_contrat = type_contrat,
    prix_fixe_offtake = prix_fixe_offtake,
    prix_fixe_injection = prix_fixe_injection,
    pv_kwc_ref = pv_kwc_ref,
    slack_penalty = slack_penalty,
    min_cycle_min = min_cycle_min,
    optim_bloc_h = optim_bloc_h,
    tou_active = tou_active,
    batterie_active = batterie_active
  ),
  metadata = list(
    exported_at = Sys.time(),
    app_version = as.character(utils::packageVersion("wisepocpac")),
    data_source = basename(csv_path),
    elapsed_seconds = elapsed,
    script = "run_batch_simulation.R"
  )
)

saveRDS(bundle, output_path)
cat(sprintf("\nRDS saved: %s (%.1f MB)\n", output_path,
    file.size(output_path) / 1e6))
cat("Import this file in the Shiny app via 'Importer RDS'.\n")
