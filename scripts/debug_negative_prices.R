# =============================================================================
# DEBUG: Pourquoi l'optimiseur ne reagit pas aux prix negatifs ?
# =============================================================================
# Reproduit le pipeline Shiny: CSV -> inject_belpex -> prepare_df -> baseline
# -> optimizer LP, puis inspecte les resultats pour les jours a prix negatifs.
# =============================================================================

library(dplyr)
library(lubridate)

# Charger le package (toutes les fonctions R6 + helpers)
devtools::load_all(".")

# Supprimer les conflits de masquage
if (exists("calc_cop", envir = .GlobalEnv)) rm("calc_cop", envir = .GlobalEnv)
if (exists("auto_aggregate", envir = .GlobalEnv)) rm("auto_aggregate", envir = .GlobalEnv)

# --- 1. Charger le CSV comme le fait l'app ---
csv_path <- "data/bq_k0001_elia.csv"
df <- readr::read_csv(csv_path, show_col_types = FALSE)
# Le CSV a des timestamps format "2025-11-20 00:00:00" — ymd_hms les parse en UTC
if (!inherits(df$timestamp, "POSIXct")) {
  df$timestamp <- lubridate::ymd_hms(df$timestamp, quiet = TRUE)
}
if ("feedin_kwh" %in% names(df) && !"intake_kwh" %in% names(df)) {
  df <- rename(df, intake_kwh = feedin_kwh)
}
message(sprintf("CSV: %d lignes, %s -> %s, tz=%s",
  nrow(df), format(min(df$timestamp)), format(max(df$timestamp)),
  attr(df$timestamp, "tzone")))
message(sprintf("  Colonnes: %s", paste(names(df), collapse=", ")))

# --- 1b. Ajouter t_ext depuis Open-Meteo (comme le fait mod_sidebar) ---
if (!"t_ext" %in% names(df)) {
  message("[t_ext] Absent du CSV, recuperation via Open-Meteo...")
  dp <- DataProvider$new()
  t_ext_meteo <- tryCatch({
    df_temp <- dp$get_temperature(min(as.Date(df$timestamp)), max(as.Date(df$timestamp)))
    if (!is.null(df_temp) && nrow(df_temp) > 0) {
      dp$interpolate_temperature(df_temp, df$timestamp)
    } else NULL
  }, error = function(e) { message(sprintf("  Erreur: %s", e$message)); NULL })
  if (!is.null(t_ext_meteo)) {
    df$t_ext <- t_ext_meteo
    message(sprintf("  -> %d valeurs t_ext recuperees", sum(!is.na(df$t_ext))))
  } else {
    df$t_ext <- 10
    message("  -> Fallback t_ext = 10C")
  }
}

# --- 2. Injecter les prix Belpex (comme mod_sidebar ligne 652) ---
api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
df <- inject_belpex_prices(df, api_key = api_key, data_dir = "data")

# Verifier les prix pour le 26 avril
prix_apr26 <- df %>%
  filter(as.Date(timestamp, tz = "UTC") == as.Date("2026-04-26")) %>%
  select(timestamp, prix_eur_kwh)
message(sprintf("\n=== Prix 26 avril: %d points, min=%.1f, max=%.1f EUR/MWh ===",
  nrow(prix_apr26),
  min(prix_apr26$prix_eur_kwh * 1000, na.rm = TRUE),
  max(prix_apr26$prix_eur_kwh * 1000, na.rm = TRUE)))
message(sprintf("  NAs: %d / %d", sum(is.na(prix_apr26$prix_eur_kwh)), nrow(prix_apr26)))

# Verifier le 25 avril
prix_apr25 <- df %>%
  filter(as.Date(timestamp, tz = "UTC") == as.Date("2026-04-25")) %>%
  select(timestamp, prix_eur_kwh)
message(sprintf("\n=== Prix 25 avril: %d points, min=%.1f, max=%.1f EUR/MWh ===",
  nrow(prix_apr25),
  min(prix_apr25$prix_eur_kwh * 1000, na.rm = TRUE),
  max(prix_apr25$prix_eur_kwh * 1000, na.rm = TRUE)))
message(sprintf("  NAs: %d / %d", sum(is.na(prix_apr25$prix_eur_kwh)), nrow(prix_apr25)))

# --- 3. Params (memes que l'app) ---
params <- list(
  t_consigne = 50, t_tolerance = 5,
  t_min = 45, t_max = 55,
  p_pac_kw = 60, cop_nominal = 3.5, t_ref_cop = 7,
  volume_ballon_l = 30000,
  capacite_kwh_par_degre = 30000 * 0.001163,
  dt_h = 0.25,
  type_contrat = "dynamique",
  taxe_transport_eur_kwh = 0.15,
  coeff_injection = 1.0,
  prix_fixe_offtake = 0.30,
  prix_fixe_injection = 0.03,
  pv_kwc = 64, pv_kwc_ref = 64,
  batterie_active = FALSE,
  batt_kwh = 0, batt_kw = 0, batt_rendement = 0.9,
  batt_soc_min = 0.1, batt_soc_max = 0.9,
  slack_penalty = 2.5,
  optim_bloc_h = 24,
  curtailment_active = FALSE,
  curtail_kwh_per_qt = Inf,
  poids_cout = 0.5,
  horizon_qt = 16,
  seuil_surplus_pct = 0.3,
  perte_kwh_par_qt = 0.05
)

# --- 4. prepare_df ---
gen <- DataGenerator$new()
result <- gen$prepare_df(df, params)
df_prep <- result$df
params <- result$params

message(sprintf("\n=== prepare_df: %d lignes ===", nrow(df_prep)))
message(sprintf("  prix_offtake range: %.4f .. %.4f EUR/kWh",
  min(df_prep$prix_offtake, na.rm = TRUE),
  max(df_prep$prix_offtake, na.rm = TRUE)))
message(sprintf("  prix_injection range: %.4f .. %.4f EUR/kWh",
  min(df_prep$prix_injection, na.rm = TRUE),
  max(df_prep$prix_injection, na.rm = TRUE)))
message(sprintf("  prix_offtake NAs: %d / %d", sum(is.na(df_prep$prix_offtake)), nrow(df_prep)))
message(sprintf("  prix_injection NAs: %d / %d", sum(is.na(df_prep$prix_injection)), nrow(df_prep)))

# Detail 26 avril
apr26 <- df_prep %>%
  filter(as.Date(timestamp, tz = "UTC") == as.Date("2026-04-26"),
         hour(timestamp) >= 7, hour(timestamp) <= 16)
if (nrow(apr26) > 0) {
  message(sprintf("\n=== 26 avril 07-16h UTC (09-18h Brussels) ==="))
  message(sprintf("  prix_offtake: min=%.4f max=%.4f EUR/kWh",
    min(apr26$prix_offtake, na.rm = TRUE), max(apr26$prix_offtake, na.rm = TRUE)))
  message(sprintf("  prix_offtake NAs: %d", sum(is.na(apr26$prix_offtake))))
  message(sprintf("  pv_kwh: min=%.1f max=%.1f", min(apr26$pv_kwh), max(apr26$pv_kwh)))
  message(sprintf("  conso_hors_pac: min=%.2f max=%.2f", min(apr26$conso_hors_pac), max(apr26$conso_hors_pac)))
  message(sprintf("  soutirage_estime_kwh: min=%.3f max=%.3f mean=%.3f",
    min(apr26$soutirage_estime_kwh), max(apr26$soutirage_estime_kwh),
    mean(apr26$soutirage_estime_kwh)))
}

# --- 5. Baseline mesure ---
tm <- ThermalModel$new(params)
bl <- Baseline$new(tm)
df_bl <- bl$run(df_prep, params, mode = "measured")
message(sprintf("\n=== Baseline mesuree: %d lignes ===", nrow(df_bl)))

# --- 6. Optimiseur LP ---
message("\n=== Lancement optimiseur LP (bloc 24h) ===")
t_start <- Sys.time()
opt <- LPOptimizer$new(params, df_bl)
df_opt <- opt$solve()
t_end <- Sys.time()
message(sprintf("  Duree: %.1f secondes", as.numeric(t_end - t_start)))

# Guard baseline
opt$guard_baseline(df_bl)
df_opt <- opt$get_results()

message(sprintf("=== Optimiseur termine: %d lignes ===", nrow(df_opt)))

# --- 7. Comparer baseline vs opti ---
compare_day <- function(df_opt, df_bl, target_date, label) {
  opt_day <- df_opt %>%
    filter(as.Date(timestamp, tz = "UTC") == as.Date(target_date))
  bl_day <- df_bl %>%
    filter(as.Date(timestamp, tz = "UTC") == as.Date(target_date))

  if (nrow(opt_day) == 0 || nrow(bl_day) == 0) {
    message(sprintf("\n=== %s: PAS DE DONNEES ===", label))
    return()
  }

  # Facture jour
  fact_bl <- sum(bl_day$offtake_kwh * bl_day$prix_offtake, na.rm = TRUE) -
    sum(bl_day$intake_kwh * bl_day$prix_injection, na.rm = TRUE)
  fact_opt <- sum(opt_day$sim_offtake * opt_day$prix_offtake, na.rm = TRUE) -
    sum(opt_day$sim_intake * opt_day$prix_injection, na.rm = TRUE)

  message(sprintf("\n=== %s ===", label))
  message(sprintf("  Baseline:  offtake=%.1f kWh, injection=%.1f kWh, facture=%.2f EUR",
    sum(bl_day$offtake_kwh), sum(bl_day$intake_kwh), fact_bl))
  message(sprintf("  Optimise:  offtake=%.1f kWh, injection=%.1f kWh, facture=%.2f EUR",
    sum(opt_day$sim_offtake, na.rm = TRUE), sum(opt_day$sim_intake, na.rm = TRUE), fact_opt))
  message(sprintf("  Gain: %.2f EUR (%.1f%%)",
    fact_bl - fact_opt,
    if (abs(fact_bl) > 0.01) (fact_bl - fact_opt) / abs(fact_bl) * 100 else 0))

  # Detail heures negatives
  neg_hours <- opt_day %>%
    filter(prix_offtake < 0)

  if (nrow(neg_hours) > 0) {
    message(sprintf("  --- %d QH a prix offtake negatifs ---", nrow(neg_hours)))
    message(sprintf("  Baseline: offtake=%.1f kWh, injection=%.1f kWh pendant prix neg",
      sum(neg_hours$offtake_kwh), sum(neg_hours$intake_kwh)))
    message(sprintf("  Opti:     offtake=%.1f kWh, injection=%.1f kWh pendant prix neg",
      sum(neg_hours$sim_offtake), sum(neg_hours$sim_intake)))
    message(sprintf("  Opti pac_on: min=%.2f max=%.2f mean=%.2f",
      min(neg_hours$sim_pac_on), max(neg_hours$sim_pac_on), mean(neg_hours$sim_pac_on)))
    message(sprintf("  Opti t_ballon: min=%.1f max=%.1f",
      min(neg_hours$sim_t_ballon), max(neg_hours$sim_t_ballon)))
    message(sprintf("  decision_raison: %s", paste(unique(neg_hours$decision_raison), collapse=", ")))

    # Print sample
    message("\n  Echantillon:")
    samp <- neg_hours %>% head(10) %>%
      mutate(ts = format(timestamp, "%H:%M"),
             px_off = round(prix_offtake * 1000, 0),
             px_inj = round(prix_injection * 1000, 0),
             bl_off = round(offtake_kwh, 2),
             bl_inj = round(intake_kwh, 2),
             op_off = round(sim_offtake, 2),
             op_inj = round(sim_intake, 2),
             pac = round(sim_pac_on, 3),
             tbal = round(sim_t_ballon, 1)) %>%
      select(ts, px_off, px_inj, bl_off, bl_inj, op_off, op_inj, pac, tbal)
    print(as.data.frame(samp))
  } else {
    message("  Aucun QH a prix offtake negatifs ce jour")
  }
}

compare_day(df_opt, df_bl, "2026-04-25", "25 AVRIL (prix neg: -201 EUR/MWh)")
compare_day(df_opt, df_bl, "2026-04-26", "26 AVRIL (prix ultra-neg: -479 EUR/MWh)")

# --- 8. Check global ---
fact_bl_total <- sum(df_bl$offtake_kwh * df_bl$prix_offtake, na.rm = TRUE) -
  sum(df_bl$intake_kwh * df_bl$prix_injection, na.rm = TRUE)
fact_opt_total <- sum(df_opt$sim_offtake * df_opt$prix_offtake, na.rm = TRUE) -
  sum(df_opt$sim_intake * df_opt$prix_injection, na.rm = TRUE)
message(sprintf("\n=== GLOBAL ==="))
message(sprintf("  Facture baseline: %.2f EUR", fact_bl_total))
message(sprintf("  Facture optimisee: %.2f EUR", fact_opt_total))
message(sprintf("  Gain: %.2f EUR (%.1f%%)", fact_bl_total - fact_opt_total,
  (fact_bl_total - fact_opt_total) / abs(fact_bl_total) * 100))
