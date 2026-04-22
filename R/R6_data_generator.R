# =============================================================================
# R6 Class: DataGenerator
# =============================================================================
# Encapsulates synthetic demo data generation (generer_demo) and data
# preparation (prepare_df). Contains copies of the logic from app.R since
# those functions are defined inside the monolith and cannot be imported.
# =============================================================================

#' @title Data Generator
#' @description R6 class for generating synthetic demo data and preparing
#'   dataframes for simulation. Contains the full logic from generer_demo()
#'   and prepare_df() in app.R.
#' @export
DataGenerator <- R6::R6Class("DataGenerator",
  public = list(
    #' @description Create a new DataGenerator.
    #' @param data_provider Optional DataProvider R6 instance for Belpex/temperature
    initialize = function(data_provider = NULL) {
      if (!is.null(data_provider)) {
        private$data_provider <- data_provider
      } else {
        private$data_provider <- DataProvider$new()
      }
    },

    #' @description Generate synthetic demo input data.
    #'   Produces quarter-hourly data with PV production, external temperature,
    #'   electricity prices (from real Belpex data when available), base
    #'   consumption, and ECS (hot water) draws.
    #' @param date_start Start date (Date, default 2025-02-01)
    #' @param date_end End date (Date, default 2025-07-31)
    #' @param p_pac_kw PAC electrical power in kW (default 2)
    #' @param volume_ballon_l Tank volume in liters (default 200)
    #' @param pv_kwc PV capacity in kWc (default 6)
    #' @param ecs_kwh_jour Daily hot water consumption in kWh (NULL = auto)
    #' @param building_type Building type: "passif", "standard", or "ancien"
    #' @return tibble with columns: timestamp, pv_kwh, t_ext, prix_eur_kwh,
    #'   conso_base_kwh, soutirage_ecs_kwh
    generate_demo = function(date_start = as.Date("2025-02-01"),
                             date_end = as.Date("2025-07-31"),
                             p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6,
                             ecs_kwh_jour = NULL, building_type = "standard") {

      ts_start <- as.POSIXct(paste0(date_start, " 00:00:00"), tz = "Europe/Brussels")
      ts_end   <- as.POSIXct(paste0(as.Date(date_end) + 1, " 00:00:00"), tz = "Europe/Brussels") - 900
      ts <- seq(ts_start, ts_end, by = "15 min")
      n <- length(ts)
      set.seed(42)
      h <- lubridate::hour(ts) + lubridate::minute(ts) / 60
      doy <- lubridate::yday(ts)
      jour <- as.Date(ts, tz = "Europe/Brussels")

      # --- Load real Belpex prices ---
      belpex <- private$data_provider$get_belpex(
        date_start = ts_start,
        date_end = ts_end + 3600
      )

      has_belpex <- !is.null(belpex$data) && nrow(belpex$data) > 0

      if (has_belpex) {
        belpex_h <- belpex$data %>%
          dplyr::mutate(
            datetime_bxl = lubridate::with_tz(datetime, tzone = "Europe/Brussels"),
            heure_join = lubridate::floor_date(datetime_bxl, unit = "hour"),
            prix_belpex = price_eur_mwh / 1000
          ) %>%
          dplyr::distinct(heure_join, .keep_all = TRUE) %>%
          dplyr::select(heure_join, prix_belpex)

        df_ts <- dplyr::tibble(timestamp = ts) %>%
          dplyr::mutate(heure_join = lubridate::floor_date(timestamp, unit = "hour")) %>%
          dplyr::left_join(belpex_h, by = "heure_join")

        prix <- df_ts$prix_belpex
        prix[is.na(prix)] <- stats::median(prix, na.rm = TRUE)

        # Sunshine score derived from Belpex daytime prices
        df_score <- dplyr::tibble(timestamp = ts, prix = prix, jour = jour, h = h) %>%
          dplyr::filter(h >= 10, h <= 16) %>%
          dplyr::group_by(jour) %>%
          dplyr::summarise(prix_moy_jour = mean(prix, na.rm = TRUE), .groups = "drop") %>%
          dplyr::mutate(score_soleil = 1 - dplyr::percent_rank(prix_moy_jour))

        score_par_qt <- dplyr::tibble(jour = jour) %>%
          dplyr::left_join(df_score, by = "jour") %>%
          dplyr::pull(score_soleil)
        score_par_qt[is.na(score_par_qt)] <- 0.5

        couverture <- 0.3 + 0.6 * score_par_qt + stats::runif(n, -0.1, 0.1)
        couverture <- pmax(0.1, pmin(1.0, couverture))
      } else {
        couverture <- 0.6 + 0.4 * stats::runif(n)
        bp <- 0.05 + 0.03 * sin(2 * pi * (doy - 30) / 365)
        prix <- bp + 0.04 * sin(pi * (h - 8) / 12) + stats::rnorm(n, 0, 0.015)
        prix <- ifelse(doy > 120 & doy < 250 & h > 11 & h < 15 & stats::runif(n) < 0.15,
                       -abs(stats::rnorm(n, 0.02, 0.01)), prix)
      }

      # --- PV production ---
      env <- 0.5 + 0.5 * sin(2 * pi * (doy - 80) / 365)
      pv_kw <- pv_kwc * 0.8 * pmax(0, sin(pi * (h - 6) / 14)) * env * couverture
      pv_kwh <- pv_kw * 0.25

      # --- External temperature (real from Open-Meteo or synthetic fallback) ---
      t_ext_meteo <- tryCatch({
        df_temp <- private$data_provider$get_temperature(date_start, date_end)
        if (!is.null(df_temp) && nrow(df_temp) > 0) {
          private$data_provider$interpolate_temperature(df_temp, ts)
        } else {
          NULL
        }
      }, error = function(e) {
        warning(sprintf("[Open-Meteo] Erreur: %s -- fallback synthetique", e$message))
        NULL
      })

      if (!is.null(t_ext_meteo)) {
        t_ext <- t_ext_meteo
        message("[Open-Meteo] Temperatures reelles utilisees")
      } else {
        message("[Open-Meteo] Fallback sur temperatures synthetiques")
        bonus_soleil <- if (has_belpex) (score_par_qt - 0.5) * 4 else 0
        t_ext <- 10 + 10 * sin(2 * pi * (doy - 80) / 365) +
                  4 * sin(pi * (h - 6) / 18) +
                  bonus_soleil +
                  stats::rnorm(n, 0, 1.5)
      }

      # --- Base consumption (non-PAC) ---
      conso_base_kw <- 0.3 +
        0.2 * exp(-0.5 * ((h - 8) / 1.5)^2) +
        0.35 * exp(-0.5 * ((h - 19) / 2)^2) +
        stats::runif(n, 0, 0.1)

      # --- ECS (hot water) draws ---
      if (!is.null(ecs_kwh_jour) && !is.na(ecs_kwh_jour)) {
        facteur_ecs <- ecs_kwh_jour / 6
      } else {
        facteur_ecs <- p_pac_kw / 2
      }
      ecs_kwh <- numeric(n)
      for (i in seq_len(n)) {
        if (h[i] > 6.5 & h[i] < 8.5) {
          if (stats::runif(1) < 0.6) ecs_kwh[i] <- stats::runif(1, 1.0, 3.0) * facteur_ecs
        } else if (h[i] > 12 & h[i] < 13.5) {
          if (stats::runif(1) < 0.3) ecs_kwh[i] <- stats::runif(1, 0.3, 1.0) * facteur_ecs
        } else if (h[i] > 18.5 & h[i] < 21) {
          if (stats::runif(1) < 0.6) ecs_kwh[i] <- stats::runif(1, 1.5, 4.0) * facteur_ecs
        } else if (h[i] > 8 & h[i] < 22) {
          if (stats::runif(1) < 0.05) ecs_kwh[i] <- stats::runif(1, 0.2, 0.5) * facteur_ecs
        }
      }

      # --- Space heating for large PACs (> 10 kW) ---
      if (p_pac_kw > 10) {
        t_seuil_chauffage <- 15
        g_factor <- switch(building_type,
          passif = 0.4,
          standard = 1.0,
          ancien = 1.8,
          1.0)
        g_batiment_kw_par_k <- p_pac_kw * 3.5 / (t_seuil_chauffage - (-5)) * g_factor
        chauffage_kwh <- pmax(0, t_seuil_chauffage - t_ext) * g_batiment_kw_par_k * 0.25
        ecs_kwh <- ecs_kwh + chauffage_kwh
        message(sprintf("[Demo] Chauffage ambiance: G=%.1f kW/K, charge moy=%.1f kWh/j",
          g_batiment_kw_par_k, mean(chauffage_kwh) * 96))
      }

      dplyr::tibble(
        timestamp = ts,
        pv_kwh = round(pv_kwh, 4),
        t_ext = round(t_ext, 1),
        prix_eur_kwh = round(prix, 4),
        conso_base_kwh = round(conso_base_kw * 0.25, 4),
        soutirage_ecs_kwh = round(ecs_kwh, 4)
      )
    },

    #' @description Prepare a raw dataframe for simulation.
    #'   Applies PV scaling, price calculation, and ECS estimation.
    #' @param df Raw dataframe (from generate_demo or CSV import)
    #' @param params A list of parameters (or SimulationParams$as_list())
    #' @return A list with $df (prepared dataframe) and $params (potentially
    #'   updated params, e.g. perte_kwh_par_qt)
    prepare_df = function(df, params) {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }

      pq <- params$p_pac_kw * params$dt_h

      # Scale PV production
      ratio_pv <- params$pv_kwc / params$pv_kwc_ref
      has_conso_base <- "conso_base_kwh" %in% names(df)
      has_t_ballon   <- "t_ballon" %in% names(df)

      df <- df %>% dplyr::mutate(
        pv_kwh_original = pv_kwh,
        pv_kwh = pv_kwh * ratio_pv,
        cop_reel = calc_cop(t_ext, params$cop_nominal, params$t_ref_cop)
      )

      if (has_conso_base) {
        df <- df %>% dplyr::mutate(conso_hors_pac = conso_base_kwh)
      } else {
        df <- df %>% dplyr::mutate(
          delta_t_mesure = t_ballon - dplyr::lag(t_ballon),
          pac_on_reel = as.integer(offtake_kwh > pq * 0.5),
          conso_hors_pac = pmax(0, offtake_kwh - pac_on_reel * pq)
        )
      }

      # Apply prices based on contract type
      if (params$type_contrat == "fixe") {
        df <- df %>% dplyr::mutate(
          prix_offtake   = params$prix_fixe_offtake,
          prix_injection = params$prix_fixe_injection
        )
      } else {
        df <- df %>% dplyr::mutate(
          prix_offtake   = prix_eur_kwh + params$taxe_transport_eur_kwh,
          prix_injection = prix_eur_kwh * params$coeff_injection
        )
      }

      if ("soutirage_ecs_kwh" %in% names(df)) {
        params$perte_kwh_par_qt <- 0.004 * (params$t_consigne - 20) * params$dt_h
        df <- df %>% dplyr::mutate(soutirage_estime_kwh = soutirage_ecs_kwh)
      } else {
        pm <- df %>%
          dplyr::filter(offtake_kwh < 0.05, delta_t_mesure < 0) %>%
          dplyr::summarise(p = stats::median(delta_t_mesure, na.rm = TRUE)) %>%
          dplyr::pull(p)
        if (is.na(pm) || pm >= 0) pm <- -0.2
        params$perte_kwh_par_qt <- abs(pm) * params$capacite_kwh_par_degre
        df <- df %>% dplyr::mutate(soutirage_estime_kwh = dplyr::case_when(
          offtake_kwh < 0.05 & delta_t_mesure < pm ~
            (abs(delta_t_mesure) - abs(pm)) * params$capacite_kwh_par_degre,
          TRUE ~ 0))
      }

      list(df = df, params = params)
    }
  ),

  private = list(
    data_provider = NULL
  )
)
