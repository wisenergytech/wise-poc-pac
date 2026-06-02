#!/usr/bin/env Rscript
# =============================================================================
# SCRIPT — Export donnees dual PAC (GSHP+ASHP) BigQuery -> CSV
# =============================================================================
# Recupere les donnees separees GSHP (PAC 3.01) et ASHP (PAC 5.01) depuis
# BigQuery (raw.k0001) + compteur ORES (wise.k0001_ores) + PV Elia proxy
# + temperature Open-Meteo pour la periode 5-20 mai 2026.
#
# Produit un CSV au format attendu par le dual optimizer :
#   timestamp, pv_kwh, gshp_kwh, ashp_kwh, pac_kwh, offtake_kwh, feedin_kwh,
#   t_ballon, t_sol, t_ext, cop_gshp_max, cop_ashp_max
#
# Sources BigQuery :
#   - raw.k0001 : PAC 301 (GSHP Carrier 61WG035), PAC 501 (ASHP Hoval Belaria Pro)
#     Compteurs elec installes depuis debut mai 2026 (Lucia, 19/05/2026)
#   - wise.k0001_ores : Compteur ORES (index cumulatifs soutirage/injection)
#
# Sources externes :
#   - Elia ODS032 : PV proxy regional (Namur, 65 kWc)
#   - Open-Meteo Archive : Temperature exterieure (Profondeville)
#
# Prerequis :
#   - gcloud auth login
#   - Lancer depuis la racine du projet : Rscript data-raw/fetch_bq_dual_pac.R
# =============================================================================

library(dplyr)
library(lubridate)
library(readr)
library(httr)

# --- Configuration ---
BQ_PROJECT <- "karno-410708"
DATA_DIR   <- "data"
TMP_DIR    <- tempdir()

# EM_PAC compteurs only available from 2026-05-12 12:48 (Lucia confirmed install)
# Use 2026-05-13 for clean full days, fetch up to yesterday
DATE_START <- "2026-05-13"
DATE_END   <- format(Sys.Date() - 1, "%Y-%m-%d")

PV_KWC <- 65  # Elia scaling (calibre a 65 kWc)

# Profondeville coordinates (for Open-Meteo)
LAT <- 50.38
LON <- 4.86

message("=== Fetch BigQuery dual PAC data ===")
message(sprintf("Periode : %s -> %s", DATE_START, DATE_END))

# =============================================================================
# Helper : query BQ via CLI
# =============================================================================
bq_query_csv <- function(sql, label = "query") {
  tmp_file <- file.path(TMP_DIR, paste0("bq_", label, ".csv"))
  sql_file <- file.path(TMP_DIR, paste0("bq_", label, ".sql"))
  writeLines(sql, sql_file)
  cmd <- sprintf(
    'bq query --use_legacy_sql=false --format=csv --max_rows=1000000 --project_id=%s < "%s" > "%s"',
    BQ_PROJECT, sql_file, tmp_file
  )
  status <- system(cmd, intern = FALSE)
  if (status != 0) stop(sprintf("bq query failed for %s (exit %d)", label, status))
  read_csv(tmp_file, show_col_types = FALSE)
}

# =============================================================================
# 1. QUERY raw.k0001 : PAC data (5-min)
# =============================================================================
message("[BQ] Fetching raw.k0001 (dual PAC + temperatures)...")

sql_pac <- sprintf("
  SELECT
    UTC_DateTime,
    -- Temperatures
    TT_601,                                -- T ballon haut
    TT_602,                                -- T ballon bas
    EC_201_T_flow,                         -- T sol (sortie forage = source GSHP)
    EC_201_T_return,                       -- T sol (retour forage)
    TT_Text,                               -- T exterieure (sonde site)
    -- GSHP (PAC 3.01 = Carrier 61WG035, 40-44 kWth)
    EM_PAC_301_ENER_P_IMP_T12_PERIOD,      -- Index energie cumulatif (Wh) — Lucia 19/05
    EM_PAC_301_ENER_P_IMP_PERIOD,          -- Puissance instantanee (W) — Lucia 19/05
    PAC_301_COP_MAX,
    PAC_301_PUISSANCE,
    PAC_301_T_OUT_CONDENSEUR,
    PAC_301_T_IN_EAU_ECHANGEUR,
    -- ASHP (PAC 5.01 = Hoval Belaria Pro 24, 22-24 kWth)
    EM_PAC_501_ENER_P_IMP_T12_PERIOD,      -- Index energie cumulatif (Wh) — Lucia 19/05
    EM_PAC_501_ENER_P_IMP_PERIOD,          -- Puissance instantanee (W) — Lucia 19/05
    PAC_501_COP_MAX,
    PAC_501_PUISSANCE,
    PAC_501_T_OUT_CONDENSEUR,
    PAC_501_T_EXT
  FROM `%s.raw.k0001`
  WHERE UTC_DateTime >= '%s'
    AND UTC_DateTime <= '%s 23:59:59'
  ORDER BY UTC_DateTime
", BQ_PROJECT, DATE_START, DATE_END)

df_pac <- bq_query_csv(sql_pac, "dual_pac")
df_pac$UTC_DateTime <- ymd_hms(df_pac$UTC_DateTime, quiet = TRUE)
message(sprintf("  -> %d lignes PAC (5-min)", nrow(df_pac)))

# =============================================================================
# 2. QUERY wise.k0001_ores : Compteur ORES (5-min, index cumulatifs)
# =============================================================================
message("[BQ] Fetching wise.k0001_ores (compteur reseau)...")

sql_ores <- sprintf("
  SELECT
    time,
    Consumption_index_kWh,
    Injection_index_kWh
  FROM `%s.wise.k0001_ores`
  WHERE time >= '%s'
    AND time <= '%s 23:59:59'
  ORDER BY time
", BQ_PROJECT, DATE_START, DATE_END)

df_ores <- bq_query_csv(sql_ores, "ores")
df_ores$time <- ymd_hms(df_ores$time, quiet = TRUE)
message(sprintf("  -> %d lignes ORES", nrow(df_ores)))

# =============================================================================
# 3. AGGREGATION 5-min -> 15-min
# =============================================================================
message("[Aggregation] 5-min -> 15-min...")

# --- 3a. PAC : agreger par quart d'heure ---
# CORRECTED (2026-06-02): use T12 index (Wh cumulative) for energy, not PERIOD
# Lucia (19/05): ENER_P_IMP_T12_PERIOD = energy index (Wh cumulative)
#                ENER_P_IMP_PERIOD = power (W instantaneous)
df_pac_15 <- df_pac %>%
  mutate(qt = floor_date(UTC_DateTime, unit = "15 minutes")) %>%
  group_by(qt) %>%
  summarise(
    # Temperatures : moyenne
    t_ballon = mean(TT_601, na.rm = TRUE),
    t_ballon_bas = mean(TT_602, na.rm = TRUE),
    t_sol = mean(EC_201_T_flow, na.rm = TRUE),
    t_sol_return = mean(EC_201_T_return, na.rm = TRUE),
    t_ext_site = mean(TT_Text, na.rm = TRUE),
    # GSHP energy: last T12 index in the quarter (for delta calculation)
    gshp_idx = last(na.omit(EM_PAC_301_ENER_P_IMP_T12_PERIOD)),
    # GSHP power (W): median of instantaneous power, for diagnostics
    gshp_w_mean = median(EM_PAC_301_ENER_P_IMP_PERIOD, na.rm = TRUE),
    gshp_cop_max = mean(PAC_301_COP_MAX, na.rm = TRUE),
    gshp_puissance_th = mean(PAC_301_PUISSANCE, na.rm = TRUE),
    gshp_t_condenseur = mean(PAC_301_T_OUT_CONDENSEUR, na.rm = TRUE),
    gshp_t_evaporateur = mean(PAC_301_T_IN_EAU_ECHANGEUR, na.rm = TRUE),
    # ASHP energy: last T12 index
    ashp_idx = last(na.omit(EM_PAC_501_ENER_P_IMP_T12_PERIOD)),
    # ASHP power (W): median
    ashp_w_mean = median(EM_PAC_501_ENER_P_IMP_PERIOD, na.rm = TRUE),
    ashp_cop_max = mean(PAC_501_COP_MAX, na.rm = TRUE),
    ashp_puissance_th = mean(PAC_501_PUISSANCE, na.rm = TRUE),
    ashp_t_condenseur = mean(PAC_501_T_OUT_CONDENSEUR, na.rm = TRUE),
    ashp_t_ext = mean(PAC_501_T_EXT, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(across(where(is.numeric), ~ifelse(is.nan(.), NA_real_, .))) %>%
  arrange(qt) %>%
  mutate(
    # Energy per quarter = delta of T12 index (Wh) / 1000 -> kWh
    gshp_kwh = pmax(0, (gshp_idx - dplyr::lag(gshp_idx)) / 1000),
    ashp_kwh = pmax(0, (ashp_idx - dplyr::lag(ashp_idx)) / 1000),
    # Replace NA (first row) with 0
    gshp_kwh = ifelse(is.na(gshp_kwh), 0, gshp_kwh),
    ashp_kwh = ifelse(is.na(ashp_kwh), 0, ashp_kwh),
    # Power in kW (from W)
    gshp_kw_mean = gshp_w_mean / 1000,
    ashp_kw_mean = ashp_w_mean / 1000,
    # Cap energy spikes: GSHP max ~11 kW elec -> max 2.75 kWh/qt, ASHP max ~7 kW -> 1.75 kWh/qt
    gshp_kwh = ifelse(gshp_kwh > 5, 0, gshp_kwh),
    ashp_kwh = ifelse(ashp_kwh > 3, 0, ashp_kwh)
  )

# Cross-check with ORES
gshp_daily <- sum(df_pac_15$gshp_kwh, na.rm = TRUE)
ashp_daily <- sum(df_pac_15$ashp_kwh, na.rm = TRUE)
n_days <- as.numeric(difftime(max(df_pac_15$qt), min(df_pac_15$qt), units = "days"))
message(sprintf("[Energy check] GSHP: %.1f kWh (%.1f/day), ASHP: %.1f kWh (%.1f/day), Total: %.1f kWh",
  gshp_daily, gshp_daily / max(1, n_days),
  ashp_daily, ashp_daily / max(1, n_days),
  gshp_daily + ashp_daily))

# --- 3b. ORES : difference d'index par quart d'heure ---
df_ores_15 <- df_ores %>%
  filter(!is.na(Consumption_index_kWh)) %>%
  mutate(qt = floor_date(time, unit = "15 minutes")) %>%
  group_by(qt) %>%
  summarise(
    cons_idx = last(Consumption_index_kWh),
    inj_idx  = last(Injection_index_kWh),
    .groups = "drop"
  ) %>%
  arrange(qt) %>%
  mutate(
    offtake_kwh = pmax(cons_idx - lag(cons_idx), 0, na.rm = TRUE),
    feedin_kwh  = pmax(inj_idx - lag(inj_idx), 0, na.rm = TRUE)
  ) %>%
  select(qt, offtake_kwh, feedin_kwh)

# --- 3c. Jointure PAC + ORES ---
df_base <- df_ores_15 %>%
  left_join(df_pac_15, by = "qt") %>%
  rename(timestamp = qt) %>%
  filter(!is.na(timestamp)) %>%
  arrange(timestamp)

message(sprintf("  -> %d quarts d'heure (%s -> %s)", nrow(df_base),
  format(min(df_base$timestamp), "%Y-%m-%d"),
  format(max(df_base$timestamp), "%Y-%m-%d")))

# =============================================================================
# 4. PV : Elia proxy (Namur, 65 kWc)
# =============================================================================
message("[PV Elia] Fetching & scaling...")

source("R/data_elia_solar.R")

elia <- fetch_solar_elia(DATE_START, DATE_END, region = "Namur")

if (!is.null(elia$df) && nrow(elia$df) > 0) {
  scaled <- scale_solar_to_local(elia$df, PV_KWC)
  scaled$timestamp <- with_tz(scaled$datetime, "Europe/Brussels")
  scaled <- scaled %>% select(timestamp, pv_kwh_elia = pv_kwh)

  df_base <- df_base %>%
    left_join(scaled, by = "timestamp") %>%
    mutate(pv_kwh = coalesce(pv_kwh_elia, 0)) %>%
    select(-pv_kwh_elia)
  message(sprintf("  -> PV Elia jointure OK (%d non-zero)", sum(df_base$pv_kwh > 0, na.rm = TRUE)))
} else {
  message("[WARN] Pas de donnees Elia Solar")
  df_base$pv_kwh <- 0
}

# =============================================================================
# 5. TEMPERATURE : Open-Meteo (Profondeville)
# =============================================================================
message("[Open-Meteo] Fetching temperature...")

resp_meteo <- tryCatch(
  GET(
    "https://archive-api.open-meteo.com/v1/archive",
    query = list(
      latitude = LAT, longitude = LON,
      start_date = DATE_START, end_date = DATE_END,
      hourly = "temperature_2m",
      timezone = "Europe/Brussels"
    ),
    timeout(30)
  ),
  error = function(e) {
    message(sprintf("[Open-Meteo] Erreur : %s", e$message))
    NULL
  }
)

if (!is.null(resp_meteo) && status_code(resp_meteo) == 200) {
  data_meteo <- content(resp_meteo, as = "parsed", simplifyVector = TRUE)
  if (!is.null(data_meteo$hourly)) {
    df_meteo <- tibble(
      timestamp_h = as.POSIXct(data_meteo$hourly$time, format = "%Y-%m-%dT%H:%M", tz = "Europe/Brussels"),
      t_ext_openmeteo = as.numeric(data_meteo$hourly$temperature_2m)
    ) %>% filter(!is.na(timestamp_h), !is.na(t_ext_openmeteo))

    # Interpoler horaire -> 15-min
    x_hourly <- as.numeric(df_meteo$timestamp_h)
    y_hourly <- df_meteo$t_ext_openmeteo
    x_target <- as.numeric(df_base$timestamp)
    t_ext_interp <- approx(x_hourly, y_hourly, xout = x_target, rule = 2)$y

    df_base$t_ext_openmeteo <- round(t_ext_interp, 1)
    message(sprintf("  -> %d points Open-Meteo interpoles", sum(!is.na(df_base$t_ext_openmeteo))))
  }
} else {
  message("[WARN] Open-Meteo indisponible, t_ext_openmeteo non ajoute")
}

# =============================================================================
# 6. T_EXT : choisir la meilleure source
# =============================================================================
# Priorite : sonde site (TT_Text) > ASHP (PAC_501_T_EXT) > Open-Meteo
df_base <- df_base %>%
  mutate(
    t_ext = coalesce(t_ext_site, ashp_t_ext, t_ext_openmeteo)
  )

n_t_ext_site <- sum(!is.na(df_base$t_ext_site))
n_t_ext_ashp <- sum(!is.na(df_base$ashp_t_ext))
n_t_ext_om   <- sum(!is.na(df_base$t_ext_openmeteo))
message(sprintf("[T_ext] Sources : site=%d, ASHP=%d, Open-Meteo=%d", n_t_ext_site, n_t_ext_ashp, n_t_ext_om))

# =============================================================================
# 7. PAC combinee + nettoyage
# =============================================================================
df_base <- df_base %>%
  mutate(
    pac_kwh = gshp_kwh + ashp_kwh,
    # Remplacer NaN/Inf
    t_ballon = ifelse(is.finite(t_ballon), t_ballon, NA_real_),
    t_sol = ifelse(is.finite(t_sol), t_sol, NA_real_)
  )

# Exclure les jours incomplets (avec NA sur pac_kwh ou offtake_kwh)
days_with_na <- df_base %>%
  mutate(date = as.Date(timestamp)) %>%
  group_by(date) %>%
  summarise(has_na = any(is.na(offtake_kwh)), .groups = "drop") %>%
  filter(has_na) %>% pull(date)

if (length(days_with_na) > 0) {
  message(sprintf("[Filter] %d jour(s) exclus (donnees incompletes) : %s",
    length(days_with_na), paste(days_with_na, collapse = ", ")))
  df_base <- filter(df_base, !(as.Date(timestamp) %in% days_with_na))
}

# =============================================================================
# 7b. BELPEX prices (ENTSO-E)
# =============================================================================
# Recupere les prix day-ahead Belpex : CSV local -> API ENTSO-E -> fallback
# Necessaire pour l'optimiseur (prix_offtake, prix_injection)
# =============================================================================
message("[Belpex] Fetching prices...")

source("R/data_entsoe_prices.R")

# Load .env for ENTSO-E API key
if (file.exists(".env")) {
  env_lines <- readLines(".env", warn = FALSE)
  for (line in env_lines) {
    if (grepl("^[A-Za-z_]", line) && grepl("=", line)) {
      parts <- strsplit(line, "=", fixed = TRUE)[[1]]
      key <- parts[1]
      val <- paste(parts[-1], collapse = "=")
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))

belpex <- load_belpex_prices(
  start_date = as.POSIXct(paste0(DATE_START, " 00:00:00"), tz = "UTC"),
  end_date = as.POSIXct(paste0(DATE_END, " 23:59:59"), tz = "UTC"),
  api_key = if (nchar(api_key) > 0) api_key else NULL
)

if (!is.null(belpex$data) && nrow(belpex$data) > 0) {
  belpex_qt <- belpex$data %>%
    mutate(
      timestamp = with_tz(datetime, "Europe/Brussels"),
      timestamp = floor_date(timestamp, "15 minutes"),
      prix_eur_kwh = price_eur_mwh / 1000
    ) %>%
    distinct(timestamp, .keep_all = TRUE) %>%
    select(timestamp, prix_eur_kwh)

  df_base <- df_base %>%
    left_join(belpex_qt, by = "timestamp") %>%
    mutate(prix_eur_kwh = ifelse(is.na(prix_eur_kwh), median(belpex_qt$prix_eur_kwh, na.rm = TRUE), prix_eur_kwh))

  n_matched <- sum(!is.na(df_base$prix_eur_kwh))
  message(sprintf("  -> %d/%d quarts d'heure avec prix Belpex (source: %s)",
    n_matched, nrow(df_base), belpex$source))
} else {
  message("[WARN] Pas de prix Belpex disponibles — colonne prix_eur_kwh non ajoutee")
}

# =============================================================================
# 7c. COP estime (modele parametrique)
# =============================================================================
# Pas de COP mesure dans BQ — PAC_301_COP_MAX et PAC_501_COP_MAX sont des
# parametres machine, pas des mesures de fonctionnement.
#
# On utilise les fonctions calc_cop() et calc_cop_gshp() du package :
#   - GSHP (Carrier 61WG035) : calc_cop_gshp(t_sol, cop_nominal=4.5, t_ref=10, t_ballon)
#     Sensibilite +0.08/°C source, -1%/°C ballon au-dessus de 50°C, bornes [2.0, 6.0]
#   - ASHP (Hoval Belaria Pro) : calc_cop(t_ext, cop_nominal=3.5, t_ref=7, t_ballon)
#     Sensibilite +0.1/°C source, -1%/°C ballon au-dessus de 50°C, bornes [1.5, 5.5]
#
# Ces COP sont des estimations basees sur la physique (T_source, T_ballon).
# Le COP reel depend aussi de la charge partielle, du degivrage, etc.
# =============================================================================
message("[COP] Estimation parametrique...")

source("R/fct_helpers.R")

df_base <- df_base %>%
  mutate(
    cop_gshp = calc_cop_gshp(t_sol, cop_nominal = 4.5, t_ref = 10, t_ballon = t_ballon),
    cop_ashp = calc_cop(t_ext, cop_nominal = 3.5, t_ref = 7, t_ballon = t_ballon),
    # COP combine pondere par la conso electrique de chaque PAC
    cop = ifelse(pac_kwh > 0,
      (gshp_kwh * cop_gshp + ashp_kwh * cop_ashp) / pac_kwh,
      (cop_gshp + cop_ashp) / 2)
  )

message(sprintf("  COP GSHP : %.2f - %.2f (median %.2f)",
  min(df_base$cop_gshp, na.rm = TRUE), max(df_base$cop_gshp, na.rm = TRUE),
  median(df_base$cop_gshp, na.rm = TRUE)))
message(sprintf("  COP ASHP : %.2f - %.2f (median %.2f)",
  min(df_base$cop_ashp, na.rm = TRUE), max(df_base$cop_ashp, na.rm = TRUE),
  median(df_base$cop_ashp, na.rm = TRUE)))

# =============================================================================
# 8. EXPORT CSV
# =============================================================================

# --- 8a. Version complete (toutes colonnes, pour analyse) ---
out_full <- file.path(DATA_DIR, "bq_k0001_dual_pac_full.csv")
df_export_full <- df_base %>%
  select(
    timestamp, pv_kwh,
    gshp_kwh, ashp_kwh, pac_kwh,
    offtake_kwh, feedin_kwh,
    t_ballon, t_ballon_bas, t_sol, t_sol_return, t_ext,
    t_ext_site, t_ext_openmeteo,
    gshp_kw_mean, ashp_kw_mean,
    gshp_cop_max, ashp_cop_max,
    gshp_puissance_th, ashp_puissance_th,
    gshp_t_condenseur, ashp_t_condenseur,
    gshp_t_evaporateur,
    cop_gshp, cop_ashp, cop,
    any_of("prix_eur_kwh")
  ) %>%
  mutate(timestamp = format(timestamp, "%Y-%m-%d %H:%M:%S"))

write_csv(df_export_full, out_full)
message(sprintf("[OK] %s : %d lignes", out_full, nrow(df_export_full)))

# --- 8b. Version app (format compatible optimizer) ---
out_app <- file.path(DATA_DIR, "bq_k0001_dual_pac.csv")
df_export_app <- df_base %>%
  select(
    timestamp, pv_kwh,
    gshp_kwh, ashp_kwh,
    offtake_kwh, feedin_kwh,
    t_ballon, t_sol, t_ext,
    cop_gshp, cop_ashp,
    any_of("prix_eur_kwh")
  ) %>%
  mutate(timestamp = format(timestamp, "%Y-%m-%d %H:%M:%S"))

write_csv(df_export_app, out_app)
message(sprintf("[OK] %s : %d lignes", out_app, nrow(df_export_app)))

# =============================================================================
# 9. RAPPORT
# =============================================================================
message("\n=== Resume ===")
message(sprintf("Periode      : %s -> %s",
  sub(" .*", "", df_export_app$timestamp[1]),
  sub(" .*", "", df_export_app$timestamp[nrow(df_export_app)])))
message(sprintf("Quarts heure : %d", nrow(df_export_app)))
message(sprintf("GSHP elec    : %.1f kWh (Carrier 61WG035)", sum(df_base$gshp_kwh, na.rm = TRUE)))
message(sprintf("ASHP elec    : %.1f kWh (Hoval Belaria Pro)", sum(df_base$ashp_kwh, na.rm = TRUE)))
message(sprintf("PAC total    : %.1f kWh", sum(df_base$pac_kwh, na.rm = TRUE)))
message(sprintf("Offtake      : %.1f kWh", sum(df_base$offtake_kwh, na.rm = TRUE)))
message(sprintf("Feedin       : %.1f kWh", sum(df_base$feedin_kwh, na.rm = TRUE)))
message(sprintf("PV Elia      : %.1f kWh (proxy %d kWc)", sum(df_base$pv_kwh, na.rm = TRUE), PV_KWC))
message(sprintf("T_ballon     : %.1f - %.1f C (median %.1f)",
  min(df_base$t_ballon, na.rm = TRUE), max(df_base$t_ballon, na.rm = TRUE),
  median(df_base$t_ballon, na.rm = TRUE)))
message(sprintf("T_sol        : %.1f - %.1f C (median %.1f)",
  min(df_base$t_sol, na.rm = TRUE), max(df_base$t_sol, na.rm = TRUE),
  median(df_base$t_sol, na.rm = TRUE)))
message(sprintf("T_ext        : %.1f - %.1f C (median %.1f)",
  min(df_base$t_ext, na.rm = TRUE), max(df_base$t_ext, na.rm = TRUE),
  median(df_base$t_ext, na.rm = TRUE)))
message("Done.")
