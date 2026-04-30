# =============================================================================
# SCRIPT — Export donnees PAC reelles BigQuery -> CSV pour Shiny app
# =============================================================================
# Recupere les donnees de l'installation k0001 depuis BigQuery (projet
# karno-410708, dataset wise) et genere un CSV au format attendu par l'app :
#   timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh, t_ballon
#
# Deux versions sont produites selon la source PV :
#   - data/bq_k0001_elia.csv   : PV scalee depuis Elia Solar (region Namur)
#   - data/bq_k0001_fusion.csv : PV reelle FusionSolar (3 onduleurs)
#
# Exclut les jours incomplets (avec NA sur pac_kwh ou offtake_kwh) et
# affiche un rapport de coherence du bilan energetique.
#
# Prerequis :
#   - gcloud auth login (authentification BigQuery)
#   - Lancer depuis la racine du projet : Rscript scripts/fetch_bigquery_pac.R
#
# Tables BigQuery utilisees :
#   - wise.k0001      : PAC 5-min (Elec_consumption, T_tankUp, COP, ...)
#   - wise.k0001_ores : Compteur ORES 5-min (index cumulatifs soutirage/injection)
#
# Donnees PV :
#   - Elia : API ODS032/ODS087 via fetch_solar_elia() du package
#   - FusionSolar : CSV locaux data/fusionsolar_5min_*.csv
# =============================================================================

library(dplyr)
library(lubridate)
library(readr)

# --- Configuration ---
BQ_PROJECT <- "karno-410708"
BQ_DATASET <- "wise"
DATA_DIR   <- "data"
TMP_DIR    <- tempdir()

# PV capacity for Elia scaling (kWc de l'installation Profondeville)
# Calibre a 65 kWc pour minimiser les incoherences de bilan energetique
# (offtake + pv < feedin). A 30 kWc: 12% incoherents, a 65 kWc: <1%.
PV_KWC <- 65

# Periode : depuis le debut des donnees PV BQ (k0001_pv) + ORES 15-min
DATE_START <- "2025-11-20"
DATE_END   <- format(Sys.Date(), "%Y-%m-%d")

message("=== Fetch BigQuery PAC data ===")
message(sprintf("Periode : %s -> %s", DATE_START, DATE_END))

# =============================================================================
# Helper : query BQ via CLI (utilise gcloud auth deja configuree)
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
# 1. QUERY BIGQUERY
# =============================================================================

# --- 1a. k0001 : PAC (5-min) ---
message("[BQ] Fetching k0001 (PAC)...")
sql_pac <- sprintf("
  SELECT
    time,
    Elec_consumption,
    T_tankUp,
    COP
  FROM `%s.%s.k0001`
  WHERE time >= '%s'
    AND time <= '%s 23:59:59'
  ORDER BY time
", BQ_PROJECT, BQ_DATASET, DATE_START, DATE_END)

df_pac <- bq_query_csv(sql_pac, "pac")
df_pac$time <- ymd_hms(df_pac$time, quiet = TRUE)
message(sprintf("  -> %d lignes PAC", nrow(df_pac)))

# --- 1b. k0001_ores : Compteur ORES (5-min, index cumulatifs) ---
message("[BQ] Fetching k0001_ores (compteur)...")
sql_ores <- sprintf("
  SELECT
    time,
    Consumption_index_kWh,
    Injection_index_kWh
  FROM `%s.%s.k0001_ores`
  WHERE time >= '%s'
    AND time <= '%s 23:59:59'
  ORDER BY time
", BQ_PROJECT, BQ_DATASET, DATE_START, DATE_END)

df_ores <- bq_query_csv(sql_ores, "ores")
df_ores$time <- ymd_hms(df_ores$time, quiet = TRUE)
message(sprintf("  -> %d lignes ORES", nrow(df_ores)))

# =============================================================================
# 2. AGGREGATION 15-MIN
# =============================================================================
message("[Aggregation] 5-min -> 15-min...")

# --- 2a. PAC : somme elec_consumption, moyenne T_tankUp par quart d'heure ---
df_pac_15 <- df_pac %>%
  mutate(qt = floor_date(time, unit = "15 minutes")) %>%
  group_by(qt) %>%
  summarise(
    pac_kwh = sum(Elec_consumption, na.rm = TRUE),
    t_ballon = mean(T_tankUp, na.rm = TRUE),
    cop_mean = mean(COP, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(
    t_ballon = ifelse(is.nan(t_ballon), NA_real_, t_ballon),
    cop_mean = ifelse(is.nan(cop_mean), NA_real_, cop_mean)
  )

# --- 2b. ORES : difference d'index par quart d'heure ---
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
    offtake_kwh = cons_idx - lag(cons_idx),
    feedin_kwh  = inj_idx - lag(inj_idx)
  ) %>%
  mutate(
    offtake_kwh = pmax(offtake_kwh, 0, na.rm = TRUE),
    feedin_kwh  = pmax(feedin_kwh, 0, na.rm = TRUE)
  ) %>%
  select(qt, offtake_kwh, feedin_kwh)

# --- 2c. Jointure PAC + ORES ---
df_base <- df_ores_15 %>%
  left_join(df_pac_15, by = "qt") %>%
  rename(timestamp = qt) %>%
  filter(!is.na(timestamp)) %>%
  arrange(timestamp)

message(sprintf("  -> %d quarts d'heure (%s -> %s)", nrow(df_base),
  format(min(df_base$timestamp), "%Y-%m-%d"),
  format(max(df_base$timestamp), "%Y-%m-%d")))

# =============================================================================
# 3. PV VERSION A : ELIA SOLAR (scalee)
# =============================================================================
message("[PV Elia] Fetching & scaling...")

source("R/data_elia_solar.R")

elia <- fetch_solar_elia(DATE_START, DATE_END, region = "Namur")

if (!is.null(elia$df) && nrow(elia$df) > 0) {
  scaled <- scale_solar_to_local(elia$df, PV_KWC)
  scaled$timestamp <- with_tz(scaled$datetime, "Europe/Brussels")
  scaled <- scaled %>% select(timestamp, pv_kwh_elia = pv_kwh)

  df_elia <- df_base %>%
    left_join(scaled, by = "timestamp") %>%
    mutate(pv_kwh = coalesce(pv_kwh_elia, 0)) %>%
    select(timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh, t_ballon, cop = cop_mean) %>%
    filter(!is.na(timestamp))

  # Exclure les jours incomplets (avec NA)
  days_with_na <- df_elia %>%
    mutate(date = as.Date(timestamp)) %>%
    group_by(date) %>%
    summarise(has_na = any(is.na(pac_kwh) | is.na(offtake_kwh)), .groups = "drop") %>%
    filter(has_na) %>% pull(date)
  if (length(days_with_na) > 0) {
    message(sprintf("[Filter] %d jour(s) exclus (donnees incompletes) : %s",
      length(days_with_na), paste(days_with_na, collapse = ", ")))
    df_elia <- filter(df_elia, !(as.Date(timestamp) %in% days_with_na))
  }

  # Rapport de coherence
  n_bad <- sum(
    (df_elia$feedin_kwh > df_elia$offtake_kwh + df_elia$pv_kwh) & !is.na(df_elia$feedin_kwh),
    na.rm = TRUE
  )
  message(sprintf("[Balance] %d incoherents / %d (%.1f%%)",
    n_bad, nrow(df_elia), 100 * n_bad / nrow(df_elia)))

  out_elia <- file.path(DATA_DIR, "bq_k0001_elia.csv")
  message(sprintf("[OK] %s : %d lignes, %s -> %s",
    out_elia, nrow(df_elia),
    format(min(df_elia$timestamp), "%Y-%m-%d"),
    format(max(df_elia$timestamp), "%Y-%m-%d")))
  df_elia$timestamp <- format(df_elia$timestamp, "%Y-%m-%d %H:%M:%S")
  write_csv(df_elia, out_elia)
} else {
  message("[WARN] Pas de donnees Elia Solar, fichier elia non genere")
}

# =============================================================================
# 4. PV VERSION B : FUSIONSOLAR (reel, 3 onduleurs)
# =============================================================================
message("[PV FusionSolar] Loading local CSVs...")

fusion_files <- list.files(DATA_DIR, pattern = "^fusionsolar_5min_\\d{4}\\.csv$",
                           full.names = TRUE)

if (length(fusion_files) > 0) {
  df_fusion_raw <- bind_rows(lapply(fusion_files, read_csv, show_col_types = FALSE))

  df_fusion_pv <- df_fusion_raw %>%
    mutate(
      ts_bxl = with_tz(ymd_hms(timestamp, quiet = TRUE), "Europe/Brussels"),
      qt = floor_date(ts_bxl, unit = "15 minutes")
    ) %>%
    group_by(qt) %>%
    summarise(
      pv_kwh_fusion = sum(active_power_kw * (5 / 60), na.rm = TRUE),
      .groups = "drop"
    ) %>%
    filter(qt >= ymd(DATE_START), qt <= ymd(DATE_END) + days(1))

  df_fusion <- df_base %>%
    left_join(df_fusion_pv, by = c("timestamp" = "qt")) %>%
    mutate(pv_kwh = coalesce(pv_kwh_fusion, 0)) %>%
    select(timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh, t_ballon, cop = cop_mean) %>%
    filter(!is.na(timestamp))

  # Exclure les jours incomplets (avec NA)
  days_na_f <- df_fusion %>%
    mutate(date = as.Date(timestamp)) %>%
    group_by(date) %>%
    summarise(has_na = any(is.na(pac_kwh) | is.na(offtake_kwh)), .groups = "drop") %>%
    filter(has_na) %>% pull(date)
  if (length(days_na_f) > 0) {
    df_fusion <- filter(df_fusion, !(as.Date(timestamp) %in% days_na_f))
  }

  n_pv_pts <- sum(df_fusion$pv_kwh > 0, na.rm = TRUE)
  pv_coverage <- round(n_pv_pts / nrow(df_fusion) * 100, 1)
  out_fusion <- file.path(DATA_DIR, "bq_k0001_fusion.csv")
  message(sprintf("[OK] %s : %d lignes, %s -> %s",
    out_fusion, nrow(df_fusion),
    format(min(df_fusion$timestamp), "%Y-%m-%d"),
    format(max(df_fusion$timestamp), "%Y-%m-%d")))
  df_fusion$timestamp <- format(df_fusion$timestamp, "%Y-%m-%d %H:%M:%S")
  write_csv(df_fusion, out_fusion)
  if (pv_coverage < 50) {
    message(sprintf("[WARN] FusionSolar PV ne couvre que %.1f%% des quarts d'heure.", pv_coverage))
    message("  Les donnees 5-min locales sont limitees. Lancer scripts/fetch_fusionsolar.R pour completer.")
  }
} else {
  message("[WARN] Pas de fichiers fusionsolar_5min_*.csv trouves")
}

# =============================================================================
# 5. RESUME
# =============================================================================
message("\n=== Resume ===")
if (exists("df_elia")) {
  message(sprintf("Elia  : %d qt, %s -> %s, PAC=%.0f kWh, offtake=%.0f kWh, feedin=%.0f kWh, PV=%.0f kWh (scaled %d kWc)",
    nrow(df_elia),
    sub(" .*", "", df_elia$timestamp[1]),
    sub(" .*", "", df_elia$timestamp[nrow(df_elia)]),
    sum(as.numeric(df_elia$pac_kwh), na.rm = TRUE),
    sum(as.numeric(df_elia$offtake_kwh), na.rm = TRUE),
    sum(as.numeric(df_elia$feedin_kwh), na.rm = TRUE),
    sum(as.numeric(df_elia$pv_kwh), na.rm = TRUE),
    PV_KWC))
}
if (exists("df_fusion")) {
  message(sprintf("Fusion: %d qt, PV=%.0f kWh (couverture %.1f%%)",
    nrow(df_fusion),
    sum(as.numeric(df_fusion$pv_kwh), na.rm = TRUE),
    pv_coverage))
}
message("Done.")
