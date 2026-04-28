# =============================================================================
# Batch simulation Karno Profondeville — Extract all KPIs
# =============================================================================
# Reproduces the exact same simulation as the Shiny app status bar:
#   LP, 159j, Baseline=Mesuree, Source=bq_k0001_elia.csv
#   PV=64 kWc, PAC=60 kW, COP=3.5, Ballon=32000L [45..55] consigne=50
#   Contrat=spot (taxe=0.150, coeff_inj=1.00), TOU=on
# =============================================================================

# Source all R6 classes and helpers
suppressMessages({
  library(dplyr)
  library(lubridate)
  library(readr)
  library(ROI)
  library(ROI.plugin.glpk)
})

# Source all R files (like golem would)
r_files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
# Exclude shiny UI/server modules (mod_*, app_*)
r_files <- r_files[!grepl("^R/(mod_|app_|run_)", r_files)]
for (f in r_files) {
  tryCatch(source(f, local = TRUE), error = function(e) {
    message(sprintf("[SKIP] %s: %s", f, e$message))
  })
}

# --- Parameters matching the app run ---
params <- SimulationParams$new(
  t_consigne = 50,
  t_tolerance = 5,
  p_pac_kw = 60,
  cop_nominal = 3.5,
  volume_ballon_l = 32000,
  pv_kwc = 64,
  pv_kwc_ref = 64,
  type_contrat = "dynamique",
  taxe_transport_eur_kwh = 0.150,
  coeff_injection = 1.00,
  baseline_mode = "measured",
  optim_bloc_h = 24
)

# --- Load and enrich CSV (same as mod_sidebar.R does) ---
message("=== Loading and enriching data ===")

df_raw <- read_csv("data/bq_k0001_elia.csv", show_col_types = FALSE)
df_raw$timestamp <- as.POSIXct(df_raw$timestamp, tz = "Europe/Brussels")

# Add t_ext from Open-Meteo (or fallback to 10C)
dp <- DataProvider$new()
t_ext_meteo <- tryCatch({
  df_temp <- dp$get_temperature(min(as.Date(df_raw$timestamp)), max(as.Date(df_raw$timestamp)))
  if (!is.null(df_temp) && nrow(df_temp) > 0) {
    dp$interpolate_temperature(df_temp, df_raw$timestamp)
  } else NULL
}, error = function(e) { message("[WARN] Open-Meteo failed: ", e$message); NULL })

if (!is.null(t_ext_meteo)) {
  df_raw$t_ext <- t_ext_meteo
  message("[OK] t_ext from Open-Meteo")
} else {
  df_raw$t_ext <- 10
  message("[WARN] t_ext fallback = 10C")
}

# Inject Belpex spot prices
df_raw <- inject_belpex_prices(df_raw, api_key = "", data_dir = "data")
message(sprintf("[OK] Belpex prices: %d/%d matched",
  sum(!is.na(df_raw$prix_eur_kwh) & df_raw$prix_eur_kwh != 0), nrow(df_raw)))

# --- Run simulation ---
message("=== Starting batch simulation ===")

sim <- Simulation$new(params)
sim$load_raw_dataframe(df_raw, data_provider = dp)
message("[OK] Data loaded")

sim$run_baseline(mode = "measured")
message("[OK] Baseline done")

sim$run_optimization(mode = "lp")
message("[OK] Optimization done")

# --- Extract KPIs ---
kpis <- sim$get_kpi()

cat("\n================================================================\n")
cat("  ALL KPIs — KARNO PROFONDEVILLE\n")
cat("================================================================\n\n")

for (nm in names(kpis)) {
  val <- kpis[[nm]]
  if (is.numeric(val)) {
    cat(sprintf("  %-30s : %12.2f\n", nm, val))
  } else {
    cat(sprintf("  %-30s : %s\n", nm, as.character(val)))
  }
}

# --- Detailed energy comparison ---
cat("\n================================================================\n")
cat("  COMPARAISON ENERGIE BASELINE vs OPTIMISE\n")
cat("================================================================\n\n")

n_days <- kpis$n_days

cat(sprintf("                          BASELINE     OPTIMISE       DELTA        DELTA %%\n"))
cat(sprintf("  Soutirage (kWh)    :  %8.0f     %8.0f     %+8.0f     %+.1f%%\n",
  kpis$soutirage_baseline, kpis$soutirage_opti,
  kpis$soutirage_opti - kpis$soutirage_baseline,
  (kpis$soutirage_opti - kpis$soutirage_baseline) / kpis$soutirage_baseline * 100))

cat(sprintf("  Injection (kWh)    :  %8.0f     %8.0f     %+8.0f     %+.1f%%\n",
  kpis$injection_baseline, kpis$injection_opti,
  kpis$injection_opti - kpis$injection_baseline,
  (kpis$injection_opti - kpis$injection_baseline) / kpis$injection_baseline * 100))

cat(sprintf("  Autoconsommation   :  %7.1f%%     %7.1f%%     %+7.1f pts\n",
  kpis$ac_baseline, kpis$ac_opti, kpis$ac_opti - kpis$ac_baseline))

cat(sprintf("  Autosuffisance     :  %7.1f%%     %7.1f%%     %+7.1f pts\n",
  kpis$as_baseline, kpis$as_opti, kpis$as_opti - kpis$as_baseline))

cat(sprintf("  Conso PAC (kWh)    :  %8.0f     %8.0f     %+8.0f     %+.1f%%\n",
  kpis$conso_pac_baseline, kpis$conso_pac_opti,
  kpis$conso_pac_opti - kpis$conso_pac_baseline,
  (kpis$conso_pac_opti - kpis$conso_pac_baseline) / kpis$conso_pac_baseline * 100))

cat(sprintf("\n"))
cat(sprintf("  Facture nette (EUR):  %8.0f     %8.0f     %+8.0f     -%.0f%%\n",
  kpis$facture_baseline, kpis$facture_opti,
  kpis$facture_opti - kpis$facture_baseline, kpis$gain_pct))

cat(sprintf("  Gain EUR/jour      :  %8.1f\n", kpis$gain_eur_per_day))
cat(sprintf("  Gain EUR/an        :  %8.0f\n", kpis$gain_eur_per_year))

cat(sprintf("\n"))
cat(sprintf("  Cout soutirage     :  %8.0f     %8.0f     %+8.0f\n",
  kpis$cout_soutirage_baseline, kpis$cout_soutirage_opti,
  kpis$cout_soutirage_opti - kpis$cout_soutirage_baseline))
cat(sprintf("  Rev. injection     :  %8.0f     %8.0f     %+8.0f\n",
  kpis$rev_injection_baseline, kpis$rev_injection_opti,
  kpis$rev_injection_opti - kpis$rev_injection_baseline))

cat(sprintf("\n"))
cat(sprintf("  Conformite (%%[45-55]):  %5.1f%%       %5.1f%%\n",
  kpis$conformite_baseline, kpis$conformite_opti))

cat(sprintf("  PV total (kWh)     :  %8.0f\n", kpis$pv_total))
cat(sprintf("  Periode (jours)    :  %8.1f\n", n_days))

message("\n=== Done ===")
