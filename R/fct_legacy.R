#' Legacy Standalone Functions (from app.R)
#'
#' These functions are direct copies from app.R, preserved here for the
#' Golem app_server.R to use during the transition (Phase 5-6).
#' They will be replaced by R6 class method calls in Phase 7+.
#'
#' Functions: decider, run_simulation, generer_demo, run_baseline, prepare_df
#' @noRd

# =============================================================================
# DECIDER — Rule-based decision engine (smart mode)
# =============================================================================

#' @noRd
decider <- function(mode, params, t_actuelle, surplus_now, cop_now,
                    pac_conso_qt, chaleur_pac,
                    pv_futur, conso_hp_fut, t_ext_futur, sout_futur,
                    prix_injection_now, prix_offtake_now,
                    prix_injection_fut, prix_offtake_fut,
                    poids_cout = 0.5) {

  # Meme relaxation T_min que les optimiseurs et la baseline pendant gros ECS
  # (sout_futur[1] = tirage ECS du qt courant)
  ecs_now <- if (length(sout_futur) > 0) sout_futur[1] else 0
  t_min_eff <- if (ecs_now > chaleur_pac) params$t_min - 10 else params$t_min

  if (t_actuelle < t_min_eff) return(list(pac_on = 1L, raison = "urgence_confort"))
  if (t_actuelle >= params$t_max) return(list(pac_on = 0L, raison = "ballon_plein"))

  surplus_futur <- pv_futur - conso_hp_fut
  cop_futur     <- calc_cop(t_ext_futur, params$cop_nominal, params$t_ref_cop)

  # Prediction de T future avec le meme modele proportionnel que baseline/optimiseurs
  k_perte_d <- 0.004 * params$dt_h
  t_amb_d <- 20
  cap_d <- params$capacite_kwh_par_degre
  t_simul <- t_actuelle
  qt_avant_t_min <- length(sout_futur)
  for (j in seq_along(sout_futur)) {
    chaleur_j <- pac_conso_qt * cop_futur[j]
    t_min_j <- if (sout_futur[j] > chaleur_j) params$t_min - 10 else params$t_min
    t_simul <- (t_simul * (cap_d - k_perte_d) + k_perte_d * t_amb_d - sout_futur[j]) / cap_d
    if (t_simul < t_min_j) { qt_avant_t_min <- j; break }
  }

  if (mode == "smart") {
    # ================================================================
    # Mode SMART -- Decision basee sur la valeur nette
    # A chaque qt, compare le cout de chauffer MAINTENANT vs PLUS TARD
    # Principe : ne chauffer que si ca fait economiser de l'argent net
    # ================================================================

    # Cout electrique de chauffer maintenant
    if (surplus_now >= pac_conso_qt) {
      # PV couvre tout : on perd juste le revenu d'injection
      cout_now <- pac_conso_qt * prix_injection_now
    } else if (surplus_now > 0) {
      # PV couvre une partie : perte injection + soutirage du reste
      cout_now <- surplus_now * prix_injection_now + (pac_conso_qt - surplus_now) * prix_offtake_now
    } else {
      # Pas de PV : tout vient du reseau
      cout_now <- pac_conso_qt * prix_offtake_now
    }
    cout_par_kwh_th_now <- cout_now / chaleur_pac  # EUR par kWh thermique

    # Estimer le cout moyen de chauffer PLUS TARD (sur l'horizon)
    # Moyenne ponderee : les moments proches de t_min comptent plus
    cout_futur_par_kwh_th <- numeric(length(surplus_futur))
    for (j in seq_along(surplus_futur)) {
      s <- surplus_futur[j]; cj <- cop_futur[j]; kj <- pac_conso_qt * cj
      if (s >= pac_conso_qt) cf <- pac_conso_qt * prix_injection_fut[j]
      else if (s > 0) cf <- s * prix_injection_fut[j] + (pac_conso_qt - s) * prix_offtake_fut[j]
      else cf <- pac_conso_qt * prix_offtake_fut[j]
      cout_futur_par_kwh_th[j] <- cf / kj
    }
    cout_moyen_futur <- median(cout_futur_par_kwh_th, na.rm = TRUE)

    # ---------------------------------------------------------------
    # PRIORITE 1 : Maintenir le confort (T >= T_min en permanence)
    # ---------------------------------------------------------------

    # Marge de securite : combien de degres au-dessus de T_min effectif
    marge <- t_actuelle - t_min_eff

    # Si deja sous T_min ou juste au-dessus : chauffer immediatement
    if (marge <= 2)
      return(list(pac_on = 1L, raison = "smart_urgence"))

    # Si T descend sous T_min dans les 8 prochains qt (2h) : prechauffer
    if (qt_avant_t_min <= 8)
      return(list(pac_on = 1L, raison = "smart_prechauffage"))

    # Prix negatif a l'injection : toujours autoconsommer
    if (prix_injection_now < 0 & surplus_now > 0 & t_actuelle < params$t_max)
      return(list(pac_on = 1L, raison = "smart_eviter_inj_neg"))

    # ---------------------------------------------------------------
    # PRIORITE 2 : Optimiser le cout (une fois le confort assure)
    # ---------------------------------------------------------------

    # Le ballon va-t-il avoir besoin de chaleur dans l'horizon ?
    needs_heat <- t_actuelle < params$t_consigne | qt_avant_t_min <= params$horizon_qt

    if (!needs_heat)
      return(list(pac_on = 0L, raison = "smart_ballon_ok"))

    # Surplus PV total -- chauffer est quasi-gratuit
    if (surplus_now >= pac_conso_qt) {
      if (cout_par_kwh_th_now < cout_moyen_futur * 1.5)
        return(list(pac_on = 1L, raison = "smart_surplus_gratuit"))
      return(list(pac_on = 0L, raison = "smart_injection_rentable"))
    }

    # Pas de surplus -- chauffer sur reseau si prix favorable
    if (cout_par_kwh_th_now < cout_moyen_futur * 0.7) {
      if (t_actuelle < params$t_consigne)
        return(list(pac_on = 1L, raison = "smart_prix_favorable"))
    }

    # Attendre du surplus PV futur si le ballon peut tenir
    h_avant <- which(surplus_futur >= pac_conso_qt)
    if (length(h_avant) > 0 & qt_avant_t_min > min(h_avant) + 4)
      return(list(pac_on = 0L, raison = "smart_attente_surplus"))

    # Pas de surplus a venir et besoin de chaleur : chauffer sur reseau
    if (t_actuelle < params$t_consigne)
      return(list(pac_on = 1L, raison = "smart_maintien_confort"))

    return(list(pac_on = 0L, raison = "smart_attente"))
  }
}

# =============================================================================
# RUN_SIMULATION — Smart rule-based simulation
# =============================================================================

#' @noRd
run_simulation <- function(df, params, mode, poids_cout = 0.5) {
  n <- nrow(df)
  pac_conso_qt_nom <- params$p_pac_kw * params$dt_h

  sim_t <- rep(NA_real_, n); sim_on <- rep(NA_integer_, n)
  sim_off <- rep(NA_real_, n); sim_inj <- rep(NA_real_, n)
  sim_cop <- rep(NA_real_, n); sim_raison <- rep(NA_character_, n)
  sim_batt_soc <- rep(NA_real_, n); sim_batt_flux <- rep(NA_real_, n)

  # Meme point de depart que la baseline et les optimiseurs
  sim_t[1] <- params$t_consigne; sim_on[1] <- 0L
  sim_cop[1] <- calc_cop(df$t_ext[1], params$cop_nominal, params$t_ref_cop, t_ballon = sim_t[1])
  sim_raison[1] <- "init"

  # Batterie : etat initial a 50% de la capacite utile
  if (params$batterie_active) {
    batt_cap <- params$batt_kwh
    batt_soc_min_kwh <- params$batt_soc_min * batt_cap
    batt_soc_max_kwh <- params$batt_soc_max * batt_cap
    batt_pw <- params$batt_kw * params$dt_h  # energie max par qt
    batt_eff <- sqrt(params$batt_rendement)  # rendement par trajet (charge et decharge)
    batt_soc <- (batt_soc_min_kwh + batt_soc_max_kwh) / 2
    sim_batt_soc[1] <- batt_soc / batt_cap
  } else {
    batt_soc <- 0
    sim_batt_soc[1] <- 0
  }
  sim_batt_flux[1] <- 0

  # Qt 1 : bilan electrique (PAC OFF, meme que baseline)
  surplus_1 <- df$pv_kwh[1] - df$conso_hors_pac[1]
  if (surplus_1 >= 0) {
    sim_off[1] <- 0; sim_inj[1] <- surplus_1
  } else {
    sim_off[1] <- abs(surplus_1); sim_inj[1] <- 0
  }

  for (i in 2:n) {
    t_act <- sim_t[i - 1]
    cop_n <- calc_cop(df$t_ext[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_act)
    ch_pac <- pac_conso_qt_nom * cop_n
    sur <- df$pv_kwh[i] - df$conso_hors_pac[i]
    fin_h <- min(i + params$horizon_qt, n); idx <- i:fin_h

    d <- decider(mode = mode, params = params, t_actuelle = t_act,
      surplus_now = sur, cop_now = cop_n, pac_conso_qt = pac_conso_qt_nom, chaleur_pac = ch_pac,
      pv_futur = df$pv_kwh[idx], conso_hp_fut = df$conso_hors_pac[idx],
      t_ext_futur = df$t_ext[idx], sout_futur = df$soutirage_estime_kwh[idx],
      prix_injection_now = df$prix_injection[i], prix_offtake_now = df$prix_offtake[i],
      prix_injection_fut = df$prix_injection[idx], prix_offtake_fut = df$prix_offtake[idx],
      poids_cout = poids_cout)

    sim_on[i] <- d$pac_on; sim_cop[i] <- cop_n; sim_raison[i] <- d$raison

    # Meme modele thermique proportionnel que baseline et optimiseurs
    k_perte <- 0.004 * params$dt_h
    t_amb <- 20
    ecs_i <- df$soutirage_estime_kwh[i]
    t_min_i <- if (ecs_i > ch_pac) params$t_min - 10 else params$t_min

    # Memes checks proactifs que la baseline (garantit T >= T_min et T <= T_max)
    if (sim_on[i] == 0L) {
      t_sans_pac <- (t_act * (params$capacite_kwh_par_degre - k_perte) + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
      if (t_sans_pac < t_min_i) { sim_on[i] <- 1L; sim_raison[i] <- "smart_contrainte_tmin" }
    }
    if (sim_on[i] == 1L) {
      t_avec_pac <- (t_act * (params$capacite_kwh_par_degre - k_perte) + ch_pac + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
      if (t_avec_pac > params$t_max) { sim_on[i] <- 0L; sim_raison[i] <- "smart_contrainte_tmax" }
    }

    apport <- sim_on[i] * ch_pac
    sim_t[i] <- (t_act * (params$capacite_kwh_par_degre - k_perte) + apport + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
    sim_t[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, sim_t[i]))

    # Bilan electrique avant batterie
    ct <- df$conso_hors_pac[i] + d$pac_on * pac_conso_qt_nom
    surplus_elec <- df$pv_kwh[i] - ct   # positif = surplus, negatif = deficit

    batt_flux_qt <- 0  # positif = charge, negatif = decharge

    if (params$batterie_active) {
      if (surplus_elec > 0) {
        # Surplus : charger la batterie
        charge_possible <- min(
          surplus_elec,
          batt_pw,
          (batt_soc_max_kwh - batt_soc) / batt_eff  # espace dispo corrige rendement
        )
        charge_possible <- max(0, charge_possible)
        batt_soc <- batt_soc + charge_possible * batt_eff
        batt_flux_qt <- charge_possible
        surplus_elec <- surplus_elec - charge_possible
      } else if (surplus_elec < 0) {
        # Deficit : decharger la batterie
        deficit <- abs(surplus_elec)
        decharge_possible <- min(
          deficit,
          batt_pw,
          (batt_soc - batt_soc_min_kwh) * batt_eff  # energie dispo corrigee rendement
        )
        decharge_possible <- max(0, decharge_possible)
        batt_soc <- batt_soc - decharge_possible / batt_eff
        batt_flux_qt <- -decharge_possible
        surplus_elec <- surplus_elec + decharge_possible
      }
      sim_batt_soc[i] <- batt_soc / batt_cap
    } else {
      sim_batt_soc[i] <- 0
    }

    sim_batt_flux[i] <- batt_flux_qt

    # Bilan reseau apres batterie
    if (surplus_elec >= 0) {
      sim_off[i] <- 0
      sim_inj[i] <- min(surplus_elec, if (!is.null(params$curtail_kwh_per_qt)) params$curtail_kwh_per_qt else Inf)
    } else {
      sim_off[i] <- abs(surplus_elec); sim_inj[i] <- 0
    }
  }
  df %>% dplyr::mutate(sim_t_ballon = sim_t, sim_pac_on = sim_on, sim_offtake = sim_off,
                sim_intake = sim_inj, sim_cop = sim_cop, decision_raison = sim_raison,
                batt_soc = sim_batt_soc, batt_flux = sim_batt_flux)
}

# =============================================================================
# GENERER_DEMO — Synthetic demo data generation
# =============================================================================

#' @noRd
generer_demo <- function(date_start = as.Date("2025-02-01"), date_end = as.Date("2025-07-31"),
                         p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6,
                         ecs_kwh_jour = NULL, building_type = "standard") {
  ts_start <- as.POSIXct(paste0(date_start, " 00:00:00"), tz = "Europe/Brussels")
  ts_end   <- as.POSIXct(paste0(date_end + 1, " 00:00:00"), tz = "Europe/Brussels") - 900
  ts <- seq(ts_start, ts_end, by = "15 min")
  n <- length(ts)
  set.seed(42)
  h <- lubridate::hour(ts) + lubridate::minute(ts) / 60
  doy <- lubridate::yday(ts)
  jour <- as.Date(ts, tz = "Europe/Brussels")

  # --- Charger les vrais prix Belpex ---
  api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
  belpex <- load_belpex_prices(
    start_date = ts_start, end_date = ts_end + 3600,
    api_key = api_key, data_dir = "data"
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

    df_ts <- tibble::tibble(timestamp = ts) %>%
      dplyr::mutate(heure_join = lubridate::floor_date(timestamp, unit = "hour")) %>%
      dplyr::left_join(belpex_h, by = "heure_join")

    prix <- df_ts$prix_belpex
    prix[is.na(prix)] <- median(prix, na.rm = TRUE)

    df_score <- tibble::tibble(timestamp = ts, prix = prix, jour = jour, h = h) %>%
      dplyr::filter(h >= 10, h <= 16) %>%
      dplyr::group_by(jour) %>%
      dplyr::summarise(prix_moy_jour = mean(prix, na.rm = TRUE), .groups = "drop")

    df_score <- df_score %>%
      dplyr::mutate(score_soleil = 1 - dplyr::percent_rank(prix_moy_jour))

    score_par_qt <- tibble::tibble(jour = jour) %>%
      dplyr::left_join(df_score, by = "jour") %>%
      dplyr::pull(score_soleil)
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

  # --- Production PV ---
  env <- 0.5 + 0.5 * sin(2 * pi * (doy - 80) / 365)
  pv_kw <- pv_kwc * 0.8 * pmax(0, sin(pi * (h - 6) / 14)) * env * couverture
  pv_kwh <- pv_kw * 0.25

  # --- Temperature exterieure (donnees reelles Open-Meteo) ---
  t_ext_meteo <- tryCatch({
    df_temp <- load_openmeteo_temperature(date_start, date_end)
    if (!is.null(df_temp) && nrow(df_temp) > 0) {
      interpolate_temperature_15min(df_temp, ts)
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
    if (has_belpex) {
      bonus_soleil <- (score_par_qt - 0.5) * 4
    } else {
      bonus_soleil <- 0
    }
    t_ext <- 10 + 10 * sin(2 * pi * (doy - 80) / 365) +
              4 * sin(pi * (h - 6) / 18) +
              bonus_soleil +
              rnorm(n, 0, 1.5)
  }

  # --- Consommation de base (hors PAC) ---
  conso_base_kw <- 0.3 +
    0.2 * exp(-0.5 * ((h - 8) / 1.5)^2) +
    0.35 * exp(-0.5 * ((h - 19) / 2)^2) +
    runif(n, 0, 0.1)

  # --- Soutirage ECS ---
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

  # --- Chauffage d'ambiance (grosses PAC > 10 kW) ---
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

  tibble::tibble(
    timestamp = ts,
    pv_kwh = round(pv_kwh, 4),
    t_ext = round(t_ext, 1),
    prix_eur_kwh = round(prix, 4),
    conso_base_kwh = round(conso_base_kw * 0.25, 4),
    soutirage_ecs_kwh = round(ecs_kwh, 4)
  )
}

# =============================================================================
# RUN_BASELINE — Reference simulation (same thermal model as optimizers)
# =============================================================================

#' @noRd
run_baseline <- function(df, params, mode = "reactif") {
  n <- nrow(df)
  pac_qt <- params$p_pac_kw * params$dt_h
  cap <- params$capacite_kwh_par_degre
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  t_consigne_bas  <- params$t_min
  t_consigne_haut <- params$t_consigne

  pv    <- df$pv_kwh
  conso <- df$conso_hors_pac
  ecs   <- df$soutirage_estime_kwh
  t_ext_v <- df$t_ext

  h <- if ("timestamp" %in% names(df)) lubridate::hour(df$timestamp) + lubridate::minute(df$timestamp) / 60 else rep(12, n)
  surplus_pv_qt <- pv - conso

  # COP moyen sur la periode (pour le mode ingenieur)
  cop_moyen <- mean(calc_cop(t_ext_v, params$cop_nominal, params$t_ref_cop), na.rm = TRUE)

  t_bal  <- rep(NA_real_, n)
  pac_on <- rep(0, n)  # numerique [0,1] pour supporter la modulation (ingenieur)
  t_bal[1] <- params$t_consigne

  for (i in seq_len(n)) {
    t_prev <- if (i == 1) params$t_consigne else t_bal[i - 1]
    cop_i <- calc_cop(t_ext_v[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_prev)
    surplus_i <- surplus_pv_qt[i]

    # T projetee sans chauffage (pour modes proactif/ingenieur)
    t_sans_pac <- (t_prev * (cap - k_perte) + k_perte * t_amb - ecs[i]) / cap

    # --- Decision selon le mode ---
    if (mode == "programmateur") {
      if (h[i] >= 11 & h[i] < 15 & t_prev < params$t_max) {
        pac_on[i] <- 1
      } else if (t_prev < t_consigne_bas) {
        pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) {
        pac_on[i] <- 0
      } else {
        pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
      }

    } else if (mode == "surplus_pv") {
      seuil_surplus <- 0.5 * params$dt_h
      if (surplus_i > seuil_surplus & t_prev < params$t_max) {
        pac_on[i] <- 1
      } else if (t_prev < t_consigne_bas) {
        pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) {
        pac_on[i] <- 0
      } else {
        pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
      }

    } else if (mode == "ingenieur") {
      if (t_prev < t_consigne_bas) {
        pac_on[i] <- 1
      } else if (t_prev >= params$t_max) {
        pac_on[i] <- 0
      } else if (surplus_i > 0 & t_prev < params$t_max) {
        pac_on[i] <- min(1, max(0.1, surplus_i / pac_qt))
      } else if (t_sans_pac < t_consigne_bas) {
        pac_on[i] <- 1
      } else if (t_prev < params$t_consigne & cop_i > cop_moyen * 1.05) {
        pac_on[i] <- 0.3
      } else {
        pac_on[i] <- 0
      }

    } else {
      # Reactif ou proactif : thermostat pur avec hysteresis
      if (t_prev < t_consigne_bas) {
        pac_on[i] <- 1
      } else if (t_prev > t_consigne_haut) {
        pac_on[i] <- 0
      } else {
        pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
      }
    }

    # Contraintes proactives (mode proactif uniquement)
    if (mode == "proactif") {
      chaleur_pac_i <- pac_qt * cop_i
      t_min_i <- if (ecs[i] > chaleur_pac_i) params$t_min - 10 else params$t_min
      if (pac_on[i] == 0) {
        if (t_sans_pac < t_min_i) pac_on[i] <- 1
      }
      if (pac_on[i] == 1) {
        t_avec_pac <- (t_prev * (cap - k_perte) + pac_qt * cop_i + k_perte * t_amb - ecs[i]) / cap
        if (t_avec_pac > params$t_max) pac_on[i] <- 0
      }
    }

    # Equation thermique (identique pour tous les modes)
    chaleur <- pac_on[i] * pac_qt * cop_i
    t_bal[i] <- (t_prev * (cap - k_perte) + chaleur + k_perte * t_amb - ecs[i]) / cap
    t_bal[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, t_bal[i]))
  }

  # Bilan electrique
  conso_totale <- conso + pac_on * pac_qt
  surplus  <- pv - conso_totale
  offtake  <- pmax(0, -surplus)
  intake   <- pmax(0, surplus)

  df %>% dplyr::mutate(
    t_ballon    = t_bal,
    offtake_kwh = offtake,
    intake_kwh  = intake
  )
}

# =============================================================================
# PREPARE_DF — Data preparation (pricing, PV scaling, ECS estimation)
# =============================================================================

#' @noRd
prepare_df <- function(df, params) {
  pq <- params$p_pac_kw * params$dt_h

  # Rescaler la production PV selon le dimensionnement choisi
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

  # Appliquer les prix selon le type de contrat
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
    pm <- df %>% dplyr::filter(offtake_kwh < 0.05, delta_t_mesure < 0) %>%
      dplyr::summarise(p = median(delta_t_mesure, na.rm = TRUE)) %>% dplyr::pull(p)
    if (is.na(pm) || pm >= 0) pm <- -0.2
    params$perte_kwh_par_qt <- abs(pm) * params$capacite_kwh_par_degre
    df <- df %>% dplyr::mutate(soutirage_estime_kwh = dplyr::case_when(
      offtake_kwh < 0.05 & delta_t_mesure < pm ~
        (abs(delta_t_mesure) - abs(pm)) * params$capacite_kwh_par_degre,
      TRUE ~ 0))
  }

  list(df = df, params = params)
}
