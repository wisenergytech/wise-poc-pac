# =============================================================================
# Script: Capture reference values from the current app.R implementation
# =============================================================================
setwd("/home/pokyah/wise/wise-poc-pac")

# Load required packages
library(dplyr)
library(readr)
library(lubridate)
library(tidyr)
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

# Source helper modules (same as app.R does)
source("R/belpex.R", local = TRUE)
source("R/optimizer_lp.R", local = TRUE)
source("R/openmeteo.R", local = TRUE)

# Define calc_cop (same as in app.R)
calc_cop <- function(t_ext, cop_nominal = 3.5, t_ref = 7, t_ballon = NULL, t_ballon_ref = 50) {
  cop <- cop_nominal + 0.1 * (t_ext - t_ref)
  if (!is.null(t_ballon)) {
    cop <- cop * (1 - 0.01 * (t_ballon - t_ballon_ref))
  }
  pmax(1.5, pmin(5.5, cop))
}

# Define generer_demo (extracted from app.R lines 314-498)
generer_demo <- function(date_start = as.Date("2025-02-01"), date_end = as.Date("2025-07-31"),
                         p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6,
                         ecs_kwh_jour = NULL, building_type = "standard") {
  ts_start <- as.POSIXct(paste0(date_start, " 00:00:00"), tz = "Europe/Brussels")
  ts_end   <- as.POSIXct(paste0(date_end + 1, " 00:00:00"), tz = "Europe/Brussels") - 900
  ts <- seq(ts_start, ts_end, by = "15 min")
  n <- length(ts)
  set.seed(42)
  h <- hour(ts) + minute(ts) / 60
  doy <- yday(ts)
  jour <- as.Date(ts, tz = "Europe/Brussels")

  api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
  belpex <- load_belpex_prices(start_date = ts_start, end_date = ts_end + 3600,
                               api_key = api_key, data_dir = "data")
  has_belpex <- !is.null(belpex$data) && nrow(belpex$data) > 0

  if (has_belpex) {
    belpex_h <- belpex$data %>%
      mutate(datetime_bxl = with_tz(datetime, tzone = "Europe/Brussels"),
             heure_join = floor_date(datetime_bxl, unit = "hour"),
             prix_belpex = price_eur_mwh / 1000) %>%
      distinct(heure_join, .keep_all = TRUE) %>%
      select(heure_join, prix_belpex)
    df_ts <- tibble(timestamp = ts) %>%
      mutate(heure_join = floor_date(timestamp, unit = "hour")) %>%
      left_join(belpex_h, by = "heure_join")
    prix <- df_ts$prix_belpex
    prix[is.na(prix)] <- median(prix, na.rm = TRUE)
    df_score <- tibble(timestamp = ts, prix = prix, jour = jour, h = h) %>%
      filter(h >= 10, h <= 16) %>%
      group_by(jour) %>%
      summarise(prix_moy_jour = mean(prix, na.rm = TRUE), .groups = "drop") %>%
      mutate(score_soleil = 1 - percent_rank(prix_moy_jour))
    score_par_qt <- tibble(jour = jour) %>%
      left_join(df_score, by = "jour") %>%
      pull(score_soleil)
    score_par_qt[is.na(score_par_qt)] <- 0.5
    couverture <- 0.3 + 0.6 * score_par_qt + runif(n, -0.1, 0.1)
    couverture <- pmax(0.1, pmin(1.0, couverture))
  } else {
    couverture <- 0.6 + 0.4 * runif(n)
    bp <- 0.05 + 0.03 * sin(2 * pi * (doy - 30) / 365)
    prix <- bp + 0.04 * sin(pi * (h - 8) / 12) + rnorm(n, 0, 0.015)
    prix <- ifelse(doy > 120 & doy < 250 & h > 11 & h < 15 & runif(n) < 0.15,
                   -abs(rnorm(n, 0.02, 0.01)), prix)
  }

  env <- 0.5 + 0.5 * sin(2 * pi * (doy - 80) / 365)
  pv_kw <- pv_kwc * 0.8 * pmax(0, sin(pi * (h - 6) / 14)) * env * couverture
  pv_kwh <- pv_kw * 0.25

  t_ext_meteo <- tryCatch({
    df_temp <- load_openmeteo_temperature(date_start, date_end)
    if (!is.null(df_temp) && nrow(df_temp) > 0) {
      interpolate_temperature_15min(df_temp, ts)
    } else NULL
  }, error = function(e) { warning(e$message); NULL })

  if (!is.null(t_ext_meteo)) {
    t_ext <- t_ext_meteo
    message("[Open-Meteo] Temperatures reelles utilisees")
  } else {
    message("[Open-Meteo] Fallback sur temperatures synthetiques")
    bonus_soleil <- if (has_belpex) (score_par_qt - 0.5) * 4 else 0
    t_ext <- 10 + 10 * sin(2 * pi * (doy - 80) / 365) +
              4 * sin(pi * (h - 6) / 18) + bonus_soleil + rnorm(n, 0, 1.5)
  }

  conso_base_kw <- 0.3 + 0.2 * exp(-0.5 * ((h - 8) / 1.5)^2) +
    0.35 * exp(-0.5 * ((h - 19) / 2)^2) + runif(n, 0, 0.1)

  if (!is.null(ecs_kwh_jour) && !is.na(ecs_kwh_jour)) {
    facteur_ecs <- ecs_kwh_jour / 6
  } else {
    facteur_ecs <- p_pac_kw / 2
  }
  ecs_kwh <- numeric(n)
  for (i in seq_len(n)) {
    if (h[i] > 6.5 & h[i] < 8.5) {
      if (runif(1) < 0.6) ecs_kwh[i] <- runif(1, 1.0, 3.0) * facteur_ecs
    } else if (h[i] > 12 & h[i] < 13.5) {
      if (runif(1) < 0.3) ecs_kwh[i] <- runif(1, 0.3, 1.0) * facteur_ecs
    } else if (h[i] > 18.5 & h[i] < 21) {
      if (runif(1) < 0.6) ecs_kwh[i] <- runif(1, 1.5, 4.0) * facteur_ecs
    } else if (h[i] > 8 & h[i] < 22) {
      if (runif(1) < 0.05) ecs_kwh[i] <- runif(1, 0.2, 0.5) * facteur_ecs
    }
  }

  if (p_pac_kw > 10) {
    t_seuil_chauffage <- 15
    g_factor <- switch(building_type, passif = 0.4, standard = 1.0, ancien = 1.8, 1.0)
    g_batiment_kw_par_k <- p_pac_kw * 3.5 / (t_seuil_chauffage - (-5)) * g_factor
    chauffage_kwh <- pmax(0, t_seuil_chauffage - t_ext) * g_batiment_kw_par_k * 0.25
    ecs_kwh <- ecs_kwh + chauffage_kwh
    message(sprintf("[Demo] Chauffage ambiance: G=%.1f kW/K, charge moy=%.1f kWh/j",
      g_batiment_kw_par_k, mean(chauffage_kwh) * 96))
  }

  tibble(timestamp = ts, pv_kwh = round(pv_kwh, 4), t_ext = round(t_ext, 1),
         prix_eur_kwh = round(prix, 4), conso_base_kwh = round(conso_base_kw * 0.25, 4),
         soutirage_ecs_kwh = round(ecs_kwh, 4))
}

# Define prepare_df (from app.R)
prepare_df <- function(df, params) {
  pq <- params$p_pac_kw * params$dt_h
  ratio_pv <- params$pv_kwc / params$pv_kwc_ref
  has_conso_base <- "conso_base_kwh" %in% names(df)
  df <- df %>% mutate(pv_kwh_original = pv_kwh, pv_kwh = pv_kwh * ratio_pv,
                      cop_reel = calc_cop(t_ext, params$cop_nominal, params$t_ref_cop))
  if (has_conso_base) {
    df <- df %>% mutate(conso_hors_pac = conso_base_kwh)
  } else {
    df <- df %>% mutate(delta_t_mesure = t_ballon - lag(t_ballon),
                        pac_on_reel = as.integer(offtake_kwh > pq * 0.5),
                        conso_hors_pac = pmax(0, offtake_kwh - pac_on_reel * pq))
  }
  if (params$type_contrat == "fixe") {
    df <- df %>% mutate(prix_offtake = params$prix_fixe_offtake,
                        prix_injection = params$prix_fixe_injection)
  } else {
    df <- df %>% mutate(prix_offtake = prix_eur_kwh + params$taxe_transport_eur_kwh,
                        prix_injection = prix_eur_kwh * params$coeff_injection)
  }
  if ("soutirage_ecs_kwh" %in% names(df)) {
    params$perte_kwh_par_qt <- 0.004 * (params$t_consigne - 20) * params$dt_h
    df <- df %>% mutate(soutirage_estime_kwh = soutirage_ecs_kwh)
  } else {
    pm <- df %>% filter(offtake_kwh < 0.05, delta_t_mesure < 0) %>%
      summarise(p = median(delta_t_mesure, na.rm = TRUE)) %>% pull(p)
    if (is.na(pm) || pm >= 0) pm <- -0.2
    params$perte_kwh_par_qt <- abs(pm) * params$capacite_kwh_par_degre
    df <- df %>% mutate(soutirage_estime_kwh = case_when(
      offtake_kwh < 0.05 & delta_t_mesure < pm ~
        (abs(delta_t_mesure) - abs(pm)) * params$capacite_kwh_par_degre,
      TRUE ~ 0))
  }
  list(df = df, params = params)
}

# Define run_baseline (from app.R)
run_baseline <- function(df, params, mode = "reactif") {
  n <- nrow(df)
  pac_qt <- params$p_pac_kw * params$dt_h
  cap <- params$capacite_kwh_par_degre
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20
  t_consigne_bas <- params$t_min
  t_consigne_haut <- params$t_consigne
  pv <- df$pv_kwh; conso <- df$conso_hors_pac
  ecs <- df$soutirage_estime_kwh; t_ext_v <- df$t_ext
  h <- if ("timestamp" %in% names(df)) hour(df$timestamp) + minute(df$timestamp) / 60 else rep(12, n)
  surplus_pv_qt <- pv - conso
  cop_moyen <- mean(calc_cop(t_ext_v, params$cop_nominal, params$t_ref_cop), na.rm = TRUE)
  t_bal <- rep(NA_real_, n); pac_on <- rep(0, n)
  t_bal[1] <- params$t_consigne
  for (i in seq_len(n)) {
    t_prev <- if (i == 1) params$t_consigne else t_bal[i - 1]
    cop_i <- calc_cop(t_ext_v[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_prev)
    surplus_i <- surplus_pv_qt[i]
    t_sans_pac <- (t_prev * (cap - k_perte) + k_perte * t_amb - ecs[i]) / cap
    if (mode == "programmateur") {
      if (h[i] >= 11 & h[i] < 15 & t_prev < params$t_max) { pac_on[i] <- 1
      } else if (t_prev < t_consigne_bas) { pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) { pac_on[i] <- 0
      } else { pac_on[i] <- if (i > 1) pac_on[i - 1] else 0 }
    } else if (mode == "surplus_pv") {
      seuil_surplus <- 0.5 * params$dt_h
      if (surplus_i > seuil_surplus & t_prev < params$t_max) { pac_on[i] <- 1
      } else if (t_prev < t_consigne_bas) { pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) { pac_on[i] <- 0
      } else { pac_on[i] <- if (i > 1) pac_on[i - 1] else 0 }
    } else if (mode == "ingenieur") {
      if (t_prev < t_consigne_bas) { pac_on[i] <- 1
      } else if (t_prev >= params$t_max) { pac_on[i] <- 0
      } else if (surplus_i > 0 & t_prev < params$t_max) { pac_on[i] <- min(1, max(0.1, surplus_i / pac_qt))
      } else if (t_sans_pac < t_consigne_bas) { pac_on[i] <- 1
      } else if (t_prev < params$t_consigne & cop_i > cop_moyen * 1.05) { pac_on[i] <- 0.3
      } else { pac_on[i] <- 0 }
    } else {
      if (t_prev < t_consigne_bas) { pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) { pac_on[i] <- 0
      } else { pac_on[i] <- if (i > 1) pac_on[i - 1] else 0 }
    }
    if (mode == "proactif") {
      chaleur_pac_i <- pac_qt * cop_i
      t_min_i <- if (ecs[i] > chaleur_pac_i) params$t_min - 10 else params$t_min
      if (pac_on[i] == 0) { if (t_sans_pac < t_min_i) pac_on[i] <- 1 }
      if (pac_on[i] == 1) {
        t_avec_pac <- (t_prev * (cap - k_perte) + pac_qt * cop_i + k_perte * t_amb - ecs[i]) / cap
        if (t_avec_pac > params$t_max) pac_on[i] <- 0
      }
    }
    chaleur <- pac_on[i] * pac_qt * cop_i
    t_bal[i] <- (t_prev * (cap - k_perte) + chaleur + k_perte * t_amb - ecs[i]) / cap
    t_bal[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, t_bal[i]))
  }
  conso_totale <- conso + pac_on * pac_qt
  surplus <- pv - conso_totale
  offtake <- pmax(0, -surplus)
  intake <- pmax(0, surplus)
  df %>% mutate(t_ballon = t_bal, offtake_kwh = offtake, intake_kwh = intake)
}

# --- Main execution ---
p <- list(
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

cat("Generating demo data (June-Aug 2025)...\n")
df <- generer_demo(date_start = as.Date("2025-06-01"), date_end = as.Date("2025-08-31"),
                   p_pac_kw = 60, volume_ballon_l = 36100, pv_kwc = 33)
cat(sprintf("  Generated %d rows\n", nrow(df)))

cat("Preparing dataframe...\n")
prep <- prepare_df(df, p)
df_prep <- prep$df
p <- prep$params

cat("Running baseline (ingenieur mode)...\n")
df_prep <- run_baseline(df_prep, p, mode = "ingenieur")

cat("Running LP optimization (this may take several minutes)...\n")
t0 <- Sys.time()
sim <- run_optimization_lp(df_prep, p)
elapsed <- difftime(Sys.time(), t0, units = "secs")
cat(sprintf("  LP done in %.1f seconds, %d rows\n", as.numeric(elapsed), nrow(sim)))

# Compute KPIs
pv_tot <- sum(df_prep$pv_kwh, na.rm = TRUE)
fb <- sum(df_prep$offtake_kwh * df_prep$prix_offtake -
          df_prep$intake_kwh * df_prep$prix_injection, na.rm = TRUE)
fo <- sum(sim$sim_offtake * sim$prix_offtake -
          sim$sim_intake * sim$prix_injection, na.rm = TRUE)
inj_b <- sum(df_prep$intake_kwh, na.rm = TRUE)
inj_o <- sum(sim$sim_intake, na.rm = TRUE)
ac_b <- round((1 - inj_b / max(pv_tot, 1)) * 100, 1)
ac_o <- round((1 - inj_o / max(pv_tot, 1)) * 100, 1)

ref <- list(
  facture_baseline = fb,
  facture_opti = fo,
  gain_eur = fb - fo,
  ac_baseline = ac_b,
  ac_opti = ac_o,
  pv_total = pv_tot,
  n_rows = nrow(sim)
)

dir.create("tests/testthat/fixtures", recursive = TRUE, showWarnings = FALSE)
saveRDS(ref, "tests/testthat/fixtures/reference_values.rds")
cat("\nReference values saved to tests/testthat/fixtures/reference_values.rds\n")
cat("Values:\n")
str(ref)
