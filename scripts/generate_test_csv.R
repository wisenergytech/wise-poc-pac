#!/usr/bin/env Rscript
# =============================================================================
# Generate a "complete" CSV test file for CSV upload mode
# =============================================================================
# Simulates what a real user CSV would look like: pv_kwh, pac_kwh,
# offtake_kwh, feedin_kwh, t_ballon, t_ext — all derived from a baseline
# simulation using default app parameters.
#
# Usage:
#   Rscript scripts/generate_test_csv.R [output_path]
#   Default output: data/test_csv_complet.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(lubridate)
})

# Source all R6 classes and helpers
devtools::load_all(".", quiet = TRUE)

# --- Default parameters (matching sidebar defaults) --------------------------

p_pac_kw       <- 60
cop_nominal    <- 3.5
t_consigne     <- 50
t_tolerance    <- 5
t_min          <- t_consigne - t_tolerance
t_max          <- t_consigne + t_tolerance
pv_kwc         <- 33
volume_ballon_l <- calculate_ballon_volume_auto(p_pac_kw, cop_nominal, t_tolerance)
dt_h           <- 0.25
date_start     <- as.Date("2026-02-25")
date_end       <- as.Date("2026-04-22")

cat(sprintf("=== Generating test CSV ===\n"))
cat(sprintf("PAC: %s kW, COP: %s\n", p_pac_kw, cop_nominal))
cat(sprintf("Ballon: %s L, [%s..%s]C consigne=%s\n", volume_ballon_l, t_min, t_max, t_consigne))
cat(sprintf("PV: %s kWc\n", pv_kwc))
cat(sprintf("Period: %s -> %s\n", date_start, date_end))

# --- Generate demo data (same as app default) --------------------------------

gen <- DataGenerator$new()
df_raw <- gen$generate_demo(
  date_start = date_start,
  date_end   = date_end,
  p_pac_kw   = p_pac_kw,
  volume_ballon_l = volume_ballon_l,
  pv_kwc     = pv_kwc,
  building_type = "standard",
  pv_data_source = "real_elia",
  solar_region = "Namur"
)

cat(sprintf("Raw data: %d rows (%s -> %s)\n", nrow(df_raw),
  min(df_raw$timestamp), max(df_raw$timestamp)))

# --- Prepare data and run baseline (thermostat) ------------------------------

params <- list(
  p_pac_kw = p_pac_kw, cop_nominal = cop_nominal, t_ref_cop = 7,
  t_consigne = t_consigne, t_tolerance = t_tolerance,
  t_min = t_min, t_max = t_max,
  volume_ballon_l = volume_ballon_l,
  capacite_kwh_par_degre = volume_ballon_l * 0.001163,
  pv_kwc = pv_kwc, pv_kwc_ref = pv_kwc,
  dt_h = dt_h,
  perte_kwh_par_qt = 0.05,
  type_contrat = "dynamique",
  taxe_transport_eur_kwh = 0.15,
  coeff_injection = 1.0,
  prix_fixe_offtake = 0.30,
  prix_fixe_injection = 0.03,
  ecs_kwh_jour = NULL
)

# Prepare (adds prices, conso_hors_pac, ECS, COP)
result <- gen$prepare_df(df_raw, params)
df_prep <- result$df
params  <- result$params

# Run baseline thermostat to get realistic pac_on, t_ballon, offtake, injection
tm <- ThermalModel$new(params)
bl <- Baseline$new(tm)
df_bl <- bl$run(df_prep, params, mode = "thermostat")

cat(sprintf("Baseline done: %d rows\n", nrow(df_bl)))

# --- Build CSV with "measured" columns ---------------------------------------
# Mimic what a real user CSV would contain from their monitoring system

pac_qt <- p_pac_kw * dt_h  # kWh per quarter-hour at full power

df_csv <- df_bl %>%
  transmute(
    timestamp   = format(timestamp, "%Y-%m-%d %H:%M:%S"),
    pv_kwh      = round(pv_kwh, 4),
    pac_kwh     = round(ifelse(is.na(offtake_kwh), 0,
                    # Baseline pac_on is 0/1 for thermostat; pac_kwh = pac_on * pac_qt
                    # Reconstruct from energy balance: pac = offtake + pv - injection - conso_hors_pac
                    pmax(0, offtake_kwh + pv_kwh - intake_kwh - conso_hors_pac)), 4),
    offtake_kwh = round(offtake_kwh, 4),
    feedin_kwh  = round(intake_kwh, 4),
    t_ballon    = round(t_ballon, 2),
    t_ext       = round(t_ext, 1)
  )

# --- Sanity checks -----------------------------------------------------------

cat(sprintf("\n=== Sanity checks ===\n"))
cat(sprintf("Columns: %s\n", paste(names(df_csv), collapse = ", ")))
cat(sprintf("Rows: %d (%.1f days)\n", nrow(df_csv), nrow(df_csv) / 96))
cat(sprintf("PV total: %.0f kWh\n", sum(as.numeric(df_csv$pv_kwh), na.rm = TRUE)))
cat(sprintf("PAC total: %.0f kWh\n", sum(as.numeric(df_csv$pac_kwh), na.rm = TRUE)))
cat(sprintf("Offtake total: %.0f kWh\n", sum(as.numeric(df_csv$offtake_kwh), na.rm = TRUE)))
cat(sprintf("Feedin total: %.0f kWh\n", sum(as.numeric(df_csv$feedin_kwh), na.rm = TRUE)))
cat(sprintf("T_ballon range: [%.1f, %.1f] C\n",
  min(as.numeric(df_csv$t_ballon), na.rm = TRUE),
  max(as.numeric(df_csv$t_ballon), na.rm = TRUE)))
cat(sprintf("NAs per column: %s\n",
  paste(sapply(df_csv, function(x) sum(is.na(x))), collapse = ", ")))

ac <- (sum(as.numeric(df_csv$pv_kwh)) - sum(as.numeric(df_csv$feedin_kwh))) /
       sum(as.numeric(df_csv$pv_kwh)) * 100
cat(sprintf("Autoconsommation: %.1f%%\n", ac))

# --- Write CSV ---------------------------------------------------------------

output_path <- if (length(commandArgs(trailingOnly = TRUE)) > 0) {
  commandArgs(trailingOnly = TRUE)[1]
} else {
  "data/test_csv_complet.csv"
}

readr::write_csv(df_csv, output_path)
cat(sprintf("\nCSV written: %s (%s)\n", output_path,
  format(file.size(output_path), big.mark = " ")))

# --- Also generate a partial CSV (no pac_kwh, no t_ballon) for testing -------

output_partial <- sub("\\.csv$", "_partial.csv", output_path)
df_csv %>%
  select(-pac_kwh, -t_ballon) %>%
  readr::write_csv(output_partial)
cat(sprintf("Partial CSV written: %s (sans pac_kwh, sans t_ballon)\n", output_partial))

cat("\nDone. Upload these files in CSV mode to test.\n")
