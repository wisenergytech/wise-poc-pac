# =============================================================================
# SHINY DASHBOARD — PILOTAGE PAC + PV
# =============================================================================
# Lancement : shiny::runApp("app.R")
# Packages requis : shiny, bslib, dplyr, readr, lubridate, plotly, DT
# =============================================================================

library(shiny)
library(bslib)
library(dplyr)
library(readr)
library(lubridate)
library(plotly)
library(DT)
library(tidyr)
library(httr)
library(xml2)
library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)
library(ROI.plugin.highs)

# Charger les modules
source("R/belpex.R", local = TRUE)
source("R/optimizer_milp.R", local = TRUE)
source("R/optimizer_lp.R", local = TRUE)
source("R/optimizer_qp.R", local = TRUE)
source("R/openmeteo.R", local = TRUE)
source("R/co2_elia.R", local = TRUE)

# Charger les variables d'environnement depuis .env
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

# =============================================================================
# FONCTIONS METIER (identiques au script batch)
# =============================================================================

calc_cop <- function(t_ext, cop_nominal = 3.5, t_ref = 7, t_ballon = NULL, t_ballon_ref = 50) {
  # COP depends on T_ext (source temperature): +0.1 per °C above reference
  cop <- cop_nominal + 0.1 * (t_ext - t_ref)
  # If T_ballon provided, COP also depends on condenser temperature:
  # -1% per °C above reference (higher T_ballon = harder to heat = lower COP)
  if (!is.null(t_ballon)) {
    cop <- cop * (1 - 0.01 * (t_ballon - t_ballon_ref))
  }
  pmax(1.5, pmin(5.5, cop))
}

prevoir_vec <- function(df, col, i, horizon) {
  fin <- min(i + horizon, nrow(df))
  df[[col]][i:fin]
}

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
    # Mode SMART — Decision basee sur la valeur nette
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

    # Surplus PV total — chauffer est quasi-gratuit
    if (surplus_now >= pac_conso_qt) {
      if (cout_par_kwh_th_now < cout_moyen_futur * 1.5)
        return(list(pac_on = 1L, raison = "smart_surplus_gratuit"))
      return(list(pac_on = 0L, raison = "smart_injection_rentable"))
    }

    # Pas de surplus — chauffer sur reseau si prix favorable
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

  # Batterie : état initial à 50% de la capacité utile
  if (params$batterie_active) {
    batt_cap <- params$batt_kwh
    batt_soc_min_kwh <- params$batt_soc_min * batt_cap
    batt_soc_max_kwh <- params$batt_soc_max * batt_cap
    batt_pw <- params$batt_kw * params$dt_h  # énergie max par qt
    batt_eff <- sqrt(params$batt_rendement)  # rendement par trajet (charge et décharge)
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
    
    # Bilan électrique avant batterie
    ct <- df$conso_hors_pac[i] + d$pac_on * pac_conso_qt_nom
    surplus_elec <- df$pv_kwh[i] - ct   # positif = surplus, négatif = déficit
    
    batt_flux_qt <- 0  # positif = charge, négatif = décharge
    
    if (params$batterie_active) {
      if (surplus_elec > 0) {
        # Surplus : charger la batterie
        charge_possible <- min(
          surplus_elec,
          batt_pw,
          (batt_soc_max_kwh - batt_soc) / batt_eff  # espace dispo corrigé rendement
        )
        charge_possible <- max(0, charge_possible)
        batt_soc <- batt_soc + charge_possible * batt_eff
        batt_flux_qt <- charge_possible
        surplus_elec <- surplus_elec - charge_possible
      } else if (surplus_elec < 0) {
        # Déficit : décharger la batterie
        deficit <- abs(surplus_elec)
        decharge_possible <- min(
          deficit,
          batt_pw,
          (batt_soc - batt_soc_min_kwh) * batt_eff  # énergie dispo corrigée rendement
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
    
    # Bilan réseau après batterie
    if (surplus_elec >= 0) {
      sim_off[i] <- 0; sim_inj[i] <- surplus_elec
    } else {
      sim_off[i] <- abs(surplus_elec); sim_inj[i] <- 0
    }
  }
  df %>% mutate(sim_t_ballon = sim_t, sim_pac_on = sim_on, sim_offtake = sim_off,
                sim_intake = sim_inj, sim_cop = sim_cop, decision_raison = sim_raison,
                batt_soc = sim_batt_soc, batt_flux = sim_batt_flux)
}

generer_demo <- function(date_start = as.Date("2025-02-01"), date_end = as.Date("2025-07-31"),
                         p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6,
                         ecs_kwh_jour = NULL, building_type = "standard") {
  # ---------------------------------------------------------------
  # Genere les DONNEES D'ENTREE :
  # - T_ext reelles (Open-Meteo) ou synthetiques (fallback)
  # - PV correle aux prix Belpex reels
  # - ECS synthetique (proportionnel au volume ballon)
  # - Chauffage d'ambiance pour grosses PAC (> 10 kW), base sur T_ext
  # ---------------------------------------------------------------
  ts_start <- as.POSIXct(paste0(date_start, " 00:00:00"), tz = "Europe/Brussels")
  ts_end   <- as.POSIXct(paste0(date_end + 1, " 00:00:00"), tz = "Europe/Brussels") - 900
  ts <- seq(ts_start, ts_end, by = "15 min")
  n <- length(ts)
  set.seed(42)
  h <- hour(ts) + minute(ts) / 60
  doy <- yday(ts)
  jour <- as.Date(ts, tz = "Europe/Brussels")

  # --- Charger les vrais prix Belpex ---
  api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
  belpex <- load_belpex_prices(
    start_date = ts_start, end_date = ts_end + 3600,
    api_key = api_key, data_dir = "data"
  )

  has_belpex <- !is.null(belpex$data) && nrow(belpex$data) > 0

  if (has_belpex) {
    # Joindre les prix Belpex par heure
    belpex_h <- belpex$data %>%
      mutate(
        datetime_bxl = with_tz(datetime, tzone = "Europe/Brussels"),
        heure_join = floor_date(datetime_bxl, unit = "hour"),
        prix_belpex = price_eur_mwh / 1000
      ) %>%
      distinct(heure_join, .keep_all = TRUE) %>%
      select(heure_join, prix_belpex)

    df_ts <- tibble(timestamp = ts) %>%
      mutate(heure_join = floor_date(timestamp, unit = "hour")) %>%
      left_join(belpex_h, by = "heure_join")

    prix <- df_ts$prix_belpex
    # Combler les trous avec un prix median
    prix[is.na(prix)] <- median(prix, na.rm = TRUE)

    # --- Score d'ensoleillement par jour derive des prix Belpex ---
    # Prix moyen en journee (10h-16h) par jour : proxy de la nebulosite
    df_score <- tibble(timestamp = ts, prix = prix, jour = jour, h = h) %>%
      filter(h >= 10, h <= 16) %>%
      group_by(jour) %>%
      summarise(prix_moy_jour = mean(prix, na.rm = TRUE), .groups = "drop")

    # Percentile inverse : jour pas cher = beau = score ensoleillement eleve
    # Score entre 0 (tres couvert) et 1 (grand soleil)
    df_score <- df_score %>%
      mutate(score_soleil = 1 - percent_rank(prix_moy_jour))

    # Joindre le score journalier aux qt
    score_par_qt <- tibble(jour = jour) %>%
      left_join(df_score, by = "jour") %>%
      pull(score_soleil)
    score_par_qt[is.na(score_par_qt)] <- 0.5  # fallback neutre

    # Couverture nuageuse derivee du score soleil + bruit intra-journalier
    # score_soleil=1 → couverture haute (0.8-1.0), score_soleil=0 → basse (0.2-0.5)
    couverture <- 0.3 + 0.6 * score_par_qt + runif(n, -0.1, 0.1)
    couverture <- pmax(0.1, pmin(1.0, couverture))
  } else {
    # Pas de Belpex → couverture aleatoire (ancien comportement)
    couverture <- 0.6 + 0.4 * runif(n)
    # Prix placeholder
    bp <- 0.05 + 0.03 * sin(2 * pi * (doy - 30) / 365)
    prix <- bp + 0.04 * sin(pi * (h - 8) / 12) + rnorm(n, 0, 0.015)
    prix <- ifelse(doy > 120 & doy < 250 & h > 11 & h < 15 & runif(n) < 0.15,
                   -abs(rnorm(n, 0.02, 0.01)), prix)
  }

  # --- Production PV (profil realiste, dimensionne au kWc demande) ---
  env <- 0.5 + 0.5 * sin(2 * pi * (doy - 80) / 365)  # enveloppe saisonniere
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
    warning(sprintf("[Open-Meteo] Erreur: %s — fallback synthetique", e$message))
    NULL
  })

  if (!is.null(t_ext_meteo)) {
    t_ext <- t_ext_meteo
    message("[Open-Meteo] Temperatures reelles utilisees")
  } else {
    # Fallback synthetique si API indisponible
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

  # --- Soutirage ECS (eau chaude sanitaire) ---
  # Proportionnel a la puissance PAC (reflet de la taille de l'installation)
  # Reference : 6 kWh_th/jour pour une PAC de 2 kW (residentiel)
  # ECS scaling: user-defined or estimated from PAC power
  if (!is.null(ecs_kwh_jour) && !is.na(ecs_kwh_jour)) {
    facteur_ecs <- ecs_kwh_jour / 6  # base: 6 kWh/jour
  } else {
    facteur_ecs <- p_pac_kw / 2  # auto: proportional to PAC power
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
  # Pour les PAC mixtes (chauffage + ECS), on ajoute une charge thermique
  # proportionnelle au deficit de temperature par rapport au seuil de chauffage.
  # Modele lineaire : Q_chauffage = G * max(0, T_seuil - T_ext) * dt_h
  # ou G (W/K) est le coefficient de deperdition du batiment.
  if (p_pac_kw > 10) {
    t_seuil_chauffage <- 15  # degres : en-dessous, le batiment chauffe
    # G estime : la PAC couvre le besoin a T_ext = -5 C (dimensionnement)
    # P_pac_thermique = G * (T_seuil - T_dim) → G = P_pac * COP / (T_seuil - T_dim)
    # On prend COP ~3.5 et T_dim = -5 C
    # G depends on building type
    g_factor <- switch(building_type,
      passif = 0.4,
      standard = 1.0,
      ancien = 1.8,
      1.0)
    g_batiment_kw_par_k <- p_pac_kw * 3.5 / (t_seuil_chauffage - (-5)) * g_factor  # kW/K
    chauffage_kwh <- pmax(0, t_seuil_chauffage - t_ext) * g_batiment_kw_par_k * 0.25  # kWh par qt
    # Ajouter au soutirage thermique total
    ecs_kwh <- ecs_kwh + chauffage_kwh
    message(sprintf("[Demo] Chauffage ambiance: G=%.1f kW/K, charge moy=%.1f kWh/j",
      g_batiment_kw_par_k, mean(chauffage_kwh) * 96))
  }

  tibble(
    timestamp = ts,
    pv_kwh = round(pv_kwh, 4),
    t_ext = round(t_ext, 1),
    prix_eur_kwh = round(prix, 4),
    conso_base_kwh = round(conso_base_kw * 0.25, 4),
    soutirage_ecs_kwh = round(ecs_kwh, 4)
  )
}

# =============================================================================
# BASELINE — Thermostat classique (meme modele thermique que les optimiseurs)
# =============================================================================
# Strategie : ON quand T < T_consigne - hysteresis, OFF quand T > T_consigne.
# Ne regarde ni le PV, ni les prix. Sert de reference pour calculer les economies.
# Utilise exactement les memes equations thermiques (cap, k_perte, COP) que les
# optimiseurs → l'economie est toujours >= 0 par construction.
# =============================================================================
run_baseline <- function(df, params, proactif = FALSE) {
  n <- nrow(df)
  pac_qt <- params$p_pac_kw * params$dt_h
  cap <- params$capacite_kwh_par_degre
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  # Seuils thermostat : hysteresis entre T_min et T_consigne
  t_consigne_bas  <- params$t_min
  t_consigne_haut <- params$t_consigne

  pv    <- df$pv_kwh
  conso <- df$conso_hors_pac
  ecs   <- df$soutirage_estime_kwh
  t_ext_v <- df$t_ext

  # Simulation sequentielle
  t_bal  <- rep(NA_real_, n)
  pac_on <- rep(0L, n)
  t_bal[1] <- params$t_consigne

  # Premier qt — COP depends on T_ballon (condenser temperature)
  cop_1 <- calc_cop(t_ext_v[1], params$cop_nominal, params$t_ref_cop, t_ballon = t_bal[1])
  if (t_bal[1] < t_consigne_bas) pac_on[1] <- 1L
  if (proactif) {
    chaleur_pac_1 <- pac_qt * cop_1
    t_min_1 <- if (ecs[1] > chaleur_pac_1) params$t_min - 10 else params$t_min
    t_sans_pac <- (params$t_consigne * (cap - k_perte) + k_perte * t_amb - ecs[1]) / cap
    if (t_sans_pac < t_min_1) pac_on[1] <- 1L
  }
  chaleur_1 <- pac_on[1] * pac_qt * cop_1
  t_bal[1] <- (params$t_consigne * (cap - k_perte) + chaleur_1 + k_perte * t_amb - ecs[1]) / cap
  t_bal[1] <- max(max(20, params$t_min - 10), min(params$t_max + 5, t_bal[1]))

  for (i in 2:n) {
    t_prev <- t_bal[i - 1]
    cop_i <- calc_cop(t_ext_v[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_prev)

    # Thermostat avec hysteresis
    if (t_prev < t_consigne_bas) {
      pac_on[i] <- 1L
    } else if (t_prev > t_consigne_haut) {
      pac_on[i] <- 0L
    } else {
      pac_on[i] <- pac_on[i - 1]
    }

    if (proactif) {
      # Contrainte proactive : anticipe les chutes de T pour forcer ON/OFF
      chaleur_pac_i <- pac_qt * cop_i
      t_min_i <- if (ecs[i] > chaleur_pac_i) params$t_min - 10 else params$t_min
      if (pac_on[i] == 0L) {
        t_sans_pac <- (t_prev * (cap - k_perte) + k_perte * t_amb - ecs[i]) / cap
        if (t_sans_pac < t_min_i) pac_on[i] <- 1L
      }
      if (pac_on[i] == 1L) {
        t_avec_pac <- (t_prev * (cap - k_perte) + pac_qt * cop_i + k_perte * t_amb - ecs[i]) / cap
        if (t_avec_pac > params$t_max) pac_on[i] <- 0L
      }
    }

    chaleur <- pac_on[i] * pac_qt * cop_i
    t_bal[i] <- (t_prev * (cap - k_perte) + chaleur + k_perte * t_amb - ecs[i]) / cap
    t_bal[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, t_bal[i]))
  }

  # Bilan electrique
  conso_totale <- conso + pac_on * pac_qt
  surplus  <- pv - conso_totale
  offtake  <- pmax(0, -surplus)
  intake   <- pmax(0, surplus)

  df %>% mutate(
    t_ballon    = t_bal,
    offtake_kwh = offtake,
    intake_kwh  = intake
  )
}

prepare_df <- function(df, params) {
  pq <- params$p_pac_kw * params$dt_h

  # Rescaler la production PV selon le dimensionnement choisi
  ratio_pv <- params$pv_kwc / params$pv_kwc_ref
  # Mode demo : conso_base_kwh + soutirage_ecs_kwh fournis, pas de t_ballon/offtake
  # Mode CSV  : offtake_kwh, intake_kwh, t_ballon fournis
  has_conso_base <- "conso_base_kwh" %in% names(df)
  has_t_ballon   <- "t_ballon" %in% names(df)

  df <- df %>% mutate(
    pv_kwh_original = pv_kwh,
    pv_kwh = pv_kwh * ratio_pv,
    cop_reel = calc_cop(t_ext, params$cop_nominal, params$t_ref_cop)
  )

  if (has_conso_base) {
    # Mode demo : conso_hors_pac est connue directement
    df <- df %>% mutate(conso_hors_pac = conso_base_kwh)
  } else {
    # Mode CSV : estimer par desagregation du grid meter
    df <- df %>% mutate(
      delta_t_mesure = t_ballon - lag(t_ballon),
      pac_on_reel = as.integer(offtake_kwh > pq * 0.5),
      conso_hors_pac = pmax(0, offtake_kwh - pac_on_reel * pq)
    )
  }

  # Appliquer les prix selon le type de contrat
  if (params$type_contrat == "fixe") {
    df <- df %>% mutate(
      prix_offtake   = params$prix_fixe_offtake,
      prix_injection = params$prix_fixe_injection
    )
  } else {
    df <- df %>% mutate(
      prix_offtake   = prix_eur_kwh + params$taxe_transport_eur_kwh,
      prix_injection = prix_eur_kwh * params$coeff_injection
    )
  }

  if ("soutirage_ecs_kwh" %in% names(df)) {
    # Mode demo : pertes calibrees sur la consigne (meme modele que optimiseurs)
    params$perte_kwh_par_qt <- 0.004 * (params$t_consigne - 20) * params$dt_h
    df <- df %>% mutate(soutirage_estime_kwh = soutirage_ecs_kwh)
  } else {
    # Mode CSV : calibrer les pertes sur les periodes PAC OFF sans ECS
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

# =============================================================================
# COULEURS ET THEME
# =============================================================================

cl <- list(
  bg_dark = "#0f1117", bg_card = "#1a1d27", bg_input = "#252833",
  accent = "#22d3ee", accent2 = "#f97316", accent3 = "#a78bfa",
  success = "#34d399", danger = "#f87171",
  text = "#e2e8f0", text_muted = "#94a3b8", grid = "#2d3348",
  reel = "#f97316", opti = "#22d3ee", pv = "#fbbf24", pac = "#34d399", prix = "#a78bfa"
)

pl_layout <- function(p, title = NULL, xlab = NULL, ylab = NULL) {
  p %>% layout(
    title = list(text = title, font = list(color = cl$text, size = 14, family = "JetBrains Mono, monospace")),
    paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
    font = list(color = cl$text_muted, family = "JetBrains Mono, monospace", size = 11),
    xaxis = list(title = xlab, gridcolor = cl$grid, zerolinecolor = cl$grid, tickfont = list(size = 10)),
    yaxis = list(title = ylab, gridcolor = cl$grid, zerolinecolor = cl$grid, tickfont = list(size = 10)),
    legend = list(orientation = "h", y = -0.3, yanchor = "top", x = 0.5, xanchor = "center",
      font = list(size = 10)),
    margin = list(t = 50, b = 100, l = 70, r = 70),
    hoverlabel = list(font = list(family = "JetBrains Mono", size = 11)))
}

# Auto-aggregate based on period length
# <= 1 day: 15 min | <= 3 days: hourly | <= 7 days: daily | > 7 days: weekly
auto_aggregate <- function(df, timestamp_col = "timestamp") {
  period_days <- as.numeric(difftime(max(df[[timestamp_col]], na.rm=TRUE), min(df[[timestamp_col]], na.rm=TRUE), units="days"))
  if (period_days <= 1) {
    list(data = df, level = "15 min", label = "15 min")
  } else if (period_days <= 3) {
    agg <- df %>% mutate(.h = floor_date(!!sym(timestamp_col), "hour")) %>%
      group_by(.h) %>%
      summarise(across(where(is.numeric), ~sum(.x, na.rm=TRUE)), .groups="drop") %>%
      rename(!!timestamp_col := .h)
    list(data = agg, level = "hour", label = "Horaire")
  } else if (period_days <= 7) {
    agg <- df %>% mutate(.d = floor_date(!!sym(timestamp_col), "day")) %>%
      group_by(.d) %>%
      summarise(across(where(is.numeric), ~sum(.x, na.rm=TRUE)), .groups="drop") %>%
      rename(!!timestamp_col := .d)
    list(data = agg, level = "day", label = "Journalier")
  } else {
    agg <- df %>% mutate(.w = floor_date(!!sym(timestamp_col), "week")) %>%
      group_by(.w) %>%
      summarise(across(where(is.numeric), ~sum(.x, na.rm=TRUE)), .groups="drop") %>%
      rename(!!timestamp_col := .w)
    list(data = agg, level = "week", label = "Hebdomadaire")
  }
}

# =============================================================================
# HELPERS PEDAGOGIQUES
# =============================================================================

# Infobulle inline : petit cercle "i" avec tooltip HTML natif
tip <- function(text) {
  tags$span(class = "info-tip", title = text, "i")
}

# KPI card avec valeur absolue, % relatif et gain, et info-bulle
kpi_card <- function(value, label, unit, color,
                     baseline_val = NULL, opti_val = NULL,
                     gain_val = NULL, gain_unit = NULL, gain_invert = FALSE,
                     tooltip = NULL) {
  val_div <- tags$div(class = "kpi-value", style = sprintf("color:%s;", color),
    value, tags$span(class = "kpi-unit", unit))

  label_div <- if (!is.null(tooltip)) {
    tags$div(class = "kpi-label", label, tip(tooltip))
  } else {
    tags$div(class = "kpi-label", label)
  }

  sub_divs <- list()

  # Ligne relative % vs baseline
  if (!is.null(baseline_val) && !is.null(opti_val) && abs(baseline_val) > 0.001) {
    pct <- (opti_val - baseline_val) / abs(baseline_val) * 100
    cls <- if (gain_invert) {
      if (pct <= 0) "positive" else "negative"
    } else {
      if (pct >= 0) "positive" else "negative"
    }
    sub_divs <- c(sub_divs, list(
      tags$div(class = "kpi-sub",
        sprintf("%s%.1f%% vs baseline", ifelse(pct >= 0, "+", ""), pct))
    ))
  }

  # Ligne gain/reduction
  if (!is.null(gain_val)) {
    gu <- if (!is.null(gain_unit)) gain_unit else unit
    cls <- if (gain_invert) {
      if (gain_val <= 0) "positive" else "negative"
    } else {
      if (gain_val >= 0) "positive" else "negative"
    }
    sub_divs <- c(sub_divs, list(
      tags$div(class = paste("kpi-gain", cls),
        sprintf("%s%s %s", ifelse(gain_val >= 0, "+", ""),
          formatC(round(gain_val), big.mark = " ", format = "d"), gu))
    ))
  }

  do.call(tags$div, c(list(class = "text-center"), list(val_div, label_div), sub_divs))
}

# Panneau explicatif depliable pour chaque onglet
explainer <- function(...) {
  tags$details(class = "tab-explainer", ...)
}

# =============================================================================
# UI
# =============================================================================

ui <- page_fillable(
  theme = bs_theme(version = 5, bg = cl$bg_dark, fg = cl$text, primary = cl$accent,
    secondary = cl$bg_card, success = cl$success, danger = cl$danger,
    base_font = font_google("IBM Plex Sans"), code_font = font_google("JetBrains Mono"),
    "input-bg" = cl$bg_input, "input-color" = cl$text, "input-border-color" = cl$grid,
    "card-bg" = cl$bg_card, "nav-tabs-link-active-bg" = cl$bg_card,
    "nav-tabs-link-active-color" = cl$accent),
  
  tags$head(tags$style(HTML(sprintf("
    body{background:%s} .card{border:1px solid %s;border-radius:12px}
    .card-header{background:transparent;border-bottom:1px solid %s;font-family:'JetBrains Mono',monospace;font-size:.8rem;text-transform:uppercase;letter-spacing:.1em;color:%s}
    .nav-tabs .nav-link{color:%s;border:none;font-family:'JetBrains Mono',monospace;font-size:.85rem;letter-spacing:.05em}
    .nav-tabs .nav-link.active{color:%s!important;border-bottom:2px solid %s}
    .kpi-value{font-family:'JetBrains Mono',monospace;font-size:1.8rem;font-weight:700;line-height:1}
    .kpi-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.1em;color:%s;margin-top:4px}
    .kpi-unit{font-size:.75rem;color:%s;margin-left:4px}
    .kpi-sub{font-size:.65rem;color:%s;margin-top:2px;font-family:'JetBrains Mono',monospace}
    .kpi-gain{font-size:.72rem;font-weight:600;margin-top:1px;font-family:'JetBrains Mono',monospace}
    .kpi-gain.positive{color:%s} .kpi-gain.negative{color:%s}
    .sidebar-section{margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid %s}
    .section-title{font-family:'JetBrains Mono',monospace;font-size:.7rem;text-transform:uppercase;letter-spacing:.15em;color:%s;margin-bottom:8px}
    .form-label{font-size:.78rem;color:%s}
    .form-control,.form-select{font-size:.82rem;background:%s!important;border-color:%s!important}
    .btn-primary{background:%s;border:none;font-family:'JetBrains Mono',monospace;font-size:.82rem;letter-spacing:.05em}
    .btn-primary:hover{background:%s;filter:brightness(1.15)}
    #status_bar{font-family:'JetBrains Mono',monospace;font-size:.75rem;color:%s;padding:8px 16px;background:%s;border-radius:8px;margin-bottom:12px}
    #status_bar .status-line{margin:2px 0}
    #status_bar .status-tag{color:%s;font-weight:700;margin-right:6px}
    #status_bar .spinner{display:inline-block;width:12px;height:12px;border:2px solid %s;border-top-color:%s;border-radius:50%%;animation:spin 0.8s linear infinite;vertical-align:middle;margin-left:8px}
    #status_bar .status-running{color:%s;font-weight:700;margin-left:8px}
    @keyframes spin{to{transform:rotate(360deg)}}
    .bslib-full-screen .card{border:none} .bslib-full-screen .card-body{background:%s}
    .info-tip{display:inline-block;width:16px;height:16px;border-radius:50%%;background:%s;color:%s;font-size:10px;text-align:center;line-height:16px;cursor:help;margin-left:4px;font-weight:700;vertical-align:middle}
    .info-tip:hover{filter:brightness(1.3)}
    .tab-explainer{background:%s;border:1px solid %s;border-radius:8px;padding:12px 16px;margin-bottom:16px;font-size:.82rem;color:%s;line-height:1.5}
    .tab-explainer summary{cursor:pointer;font-family:'JetBrains Mono',monospace;font-size:.75rem;text-transform:uppercase;letter-spacing:.1em;color:%s;list-style:none}
    .tab-explainer summary::-webkit-details-marker{display:none}
    .tab-explainer summary::before{content:'\\25B6  ';font-size:.6rem}
    .tab-explainer[open] summary::before{content:'\\25BC  '}
    .tab-explainer p{margin:8px 0 4px 0}
    .tab-explainer ul{margin:4px 0;padding-left:20px}
    .tab-explainer li{margin-bottom:2px}
    .tab-explainer strong{color:%s}
    .tab-explainer code{background:%s;padding:1px 5px;border-radius:3px;font-size:.78rem;color:%s}
  ", cl$bg_dark,cl$grid,cl$grid,cl$accent,cl$text_muted,cl$accent,cl$accent,cl$text_muted,
     cl$text_muted,cl$text_muted,cl$success,cl$danger,
     cl$grid,cl$accent,cl$text_muted,cl$bg_input,cl$grid,cl$accent,cl$accent,
     cl$text_muted,cl$bg_card,
     cl$accent,cl$grid,cl$accent,cl$accent,
     cl$bg_card,cl$accent3,cl$bg_dark,cl$bg_input,cl$grid,cl$text_muted,cl$accent,cl$accent,cl$bg_input,cl$opti)))),
  
  layout_sidebar(fillable = TRUE,
    sidebar = sidebar(width = 300, bg = cl$bg_card,
      tags$div(style = "padding:8px 0 16px 0;text-align:center;",
        tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:1.1rem;font-weight:700;color:%s;letter-spacing:.1em", cl$accent), HTML("&#9889; PAC OPTIMIZER")),
        tags$div(style = sprintf("font-size:.65rem;color:%s;margin-top:2px;letter-spacing:.15em;text-transform:uppercase", cl$text_muted), "Pilotage predictif")),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Periode", tip("Selectionnez la periode a simuler. Demo : donnees synthetiques. CSV : vos propres donnees.")),
        radioButtons("data_source", NULL, choices = c("Demo" = "demo", "CSV" = "csv"), selected = "demo", inline = TRUE),
        conditionalPanel("input.data_source=='csv'", fileInput("csv_file", NULL, accept = ".csv", buttonLabel = "Parcourir", placeholder = "data.csv")),
        conditionalPanel("input.data_source=='demo'",
          radioButtons("thermostat_type", "Thermostat baseline",
            choices = c("Reactif (classique)" = "reactif", "Proactif (anticipe)" = "proactif"),
            selected = "reactif", inline = TRUE),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Reactif = ON/OFF simple par hysteresis. Proactif = anticipe les chutes de temperature (avantage la baseline).")),
        dateRangeInput("date_range", NULL, start = as.Date("2025-07-01"), end = as.Date("2025-08-31"), language = "fr",
          min = as.Date("2025-01-01"), max = as.Date("2025-12-31")),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          HTML("Prix Belpex reels (ENTSO-E) utilises automatiquement.<br>Source : CSV locaux (2024-2025) + API si besoin."))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Optimisation", tip("Quatre approches : Rule-based (heuristique), MILP (on/off optimal), LP (charge continue lineaire) ou QP (charge continue + confort lisse, via CVXR).")),
        radioButtons("approche", "Approche", choices = c("Rule-based" = "rulebased", "MILP" = "optimiseur", "LP" = "optimiseur_lp", "QP" = "optimiseur_qp"), selected = "rulebased", inline = TRUE),
        conditionalPanel("input.approche=='rulebased'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Mode <b>Smart</b> : decision basee sur la valeur nette a chaque quart d'heure. Compare le cout de chauffer maintenant vs plus tard en tenant compte du surplus PV, des prix spot et du COP."))),
        conditionalPanel("input.approche=='optimiseur'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Resout un probleme MILP (Mixed Integer Linear Programming) : decisions <b>on/off</b> binaires. Trouve la solution optimale bloc par bloc.")),
          sliderInput("optim_bloc_h", tags$span("Horizon bloc", tip("Taille du bloc d'optimisation en heures. Plus court = plus rapide mais moins de vision. Plus long = meilleur resultat mais plus lent. 4h est un bon compromis : assez pour voir les tendances de prix et de PV, assez court pour resoudre en <1s.")),
            1, 24, 4, step = 1, post = "h"),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            HTML("4h = rapide (~1s/bloc) | 12h = equilibre | 24h = optimal mais lent"))),
        conditionalPanel("input.approche=='optimiseur_lp'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Optimisation <b>LP</b> (lineaire pur) : la PAC module sa puissance en continu (0-100%%). Probleme convexe, resolution rapide, optimum global garanti. Ideal pour PAC inverter.")),
          sliderInput("optim_bloc_h_lp", tags$span("Horizon bloc", tip("Taille du bloc en heures. Le LP etant plus rapide que le MILP, des blocs plus grands (12-24h) sont recommandes.")),
            1, 24, 24, step = 1, post = "h"),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            HTML("LP = rapide, des blocs de 24h sont recommandes"))),
        conditionalPanel("input.approche=='optimiseur' || input.approche=='optimiseur_lp'",
          sliderInput("slack_penalty", tags$span("Penalite T_min (EUR/C)", tip("Cout de violation de T_min par degre par quart d'heure. Plus bas = l'optimiseur explore des temperatures proches de T_min (meilleur COP, plus d'economies). Plus haut = respect strict de T_min. A 2.5 EUR/C, l'optimiseur accepte de descendre legerement sous T_min si le gain economique le justifie.")),
            0.5, 20, 2.5, step = 0.5, post = " EUR/C")),
        conditionalPanel("input.approche=='optimiseur_qp'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Optimisation <b>QP</b> (quadratique convexe, CVXR) : minimise le cout <i>et</i> penalise les ecarts de temperature a la consigne + les variations brusques de charge PAC. Resultat plus confortable et plus lisse.")),
          sliderInput("optim_bloc_h_qp", tags$span("Horizon bloc", tip("Taille du bloc en heures. CVXR gere bien des blocs de 12-24h.")),
            1, 24, 24, step = 1, post = "h"),
          sliderInput("qp_w_comfort", tags$span("Poids confort", tip("Penalite sur l'ecart a la consigne. Plus eleve = temperature plus stable autour de la consigne, mais cout potentiellement plus eleve.")),
            0, 1, 0.1, step = 0.01),
          sliderInput("qp_w_smooth", tags$span("Poids lissage", tip("Penalite sur les variations brusques de charge PAC. Plus eleve = charge plus lisse, moins de cycling.")),
            0, 1, 0.05, step = 0.01),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            HTML("Poids a 0 = LP pur. Augmenter pour plus de confort/lissage au detriment du cout.")))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Pompe a chaleur", tip("Caracteristiques electriques de votre PAC. Le COP varie avec la temperature exterieure ; la valeur nominale est celle a 7C.")),
        numericInput("p_pac_kw", "Puissance (kW)", 60, min = 0.5, max = 100, step = 0.5),
        numericInput("cop_nominal", "COP nominal", 3.5, min = 1.5, max = 6, step = 0.1),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "COP = Coefficient de Performance. Un COP de 3.5 signifie que 1 kWh electrique produit 3.5 kWh de chaleur.")),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Ballon thermique", tip("Le ballon sert de batterie thermique. Plus il est gros, plus on peut stocker de chaleur pour decaler la consommation.")),
        checkboxInput("volume_auto", "Volume auto", value = TRUE),
        conditionalPanel("input.volume_auto",
          uiOutput("volume_auto_display"),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;", cl$text_muted),
            HTML(paste0(
              "Dimensionne le ballon pour stocker <b>2h de chaleur PAC</b> dans la plage de tolerance. ",
              "Formule : V = P<sub>PAC</sub> &times; COP &times; 2h / (tolerance &times; 2 &times; 0.001163). ",
              "Plus le ballon est gros, plus l'optimiseur peut decaler la consommation vers les heures creuses ou le surplus PV. ",
              "Un ballon trop petit (ratio stockage/puissance faible) limite fortement les economies possibles.")))),
        conditionalPanel("!input.volume_auto",
          numericInput("volume_ballon_manual", "Volume (L)", 200, min = 50, max = 100000, step = 50)),
        numericInput("t_consigne", "Consigne (C)", 50, min = 35, max = 65, step = 1),
        sliderInput("t_tolerance", "Tolerance +/-C", 1, 10, 5, step = 1),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Plage autorisee = consigne +/- tolerance. L'algo ne laissera jamais la temperature sortir de cette plage."),
        numericInput("ecs_kwh_jour", tags$span("ECS (kWh_th/jour)", tip("Demande en eau chaude sanitaire par jour en kWh thermiques. Reference : 6 kWh/jour pour un menage, 50-200 kWh/jour pour un immeuble ou une industrie. Si vide, estime automatiquement a partir de la puissance PAC.")),
          NULL, min = 1, max = 5000, step = 1),
        conditionalPanel("input.p_pac_kw > 10",
          selectInput("building_type", tags$span("Type de batiment", tip("Influence le coefficient de deperdition thermique (G) pour le chauffage d'ambiance. Passif = tres bien isole, Standard = construction recente, Ancien = peu isole.")),
            choices = c("Passif (G faible)" = "passif", "Standard (RT2012)" = "standard", "Ancien (peu isole)" = "ancien"),
            selected = "standard"))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Tarification", tip("Le type de contrat change fondamentalement la strategie optimale. En dynamique, le prix varie chaque heure selon le marche Belpex.")),
        radioButtons("type_contrat", "Contrat", choices = c("Dynamique (spot)" = "dynamique", "Fixe" = "fixe"), selected = "dynamique", inline = TRUE),
        conditionalPanel("input.type_contrat=='fixe'",
          numericInput("prix_fixe_offtake", "Prix soutirage (EUR/kWh)", 0.30, min = 0, max = 1, step = 0.01),
          numericInput("prix_fixe_injection", "Prix injection (EUR/kWh)", 0.03, min = -0.05, max = 0.5, step = 0.005),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Prix constants sur toute la periode. En contrat fixe, le mode 'cout' perd son avantage car il n'y a pas de variation de prix a exploiter.")),
        conditionalPanel("input.type_contrat=='dynamique'",
          numericInput("taxe_transport", "Taxes reseau (EUR/kWh)", 0.15, min = 0, max = 0.5, step = 0.01),
          numericInput("coeff_injection", "Coeff. injection / spot", 1.0, min = 0, max = 1.5, step = 0.05),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Soutirage = spot + taxes. Injection = spot x coeff. Les prix negatifs signifient que vous PAYEZ pour injecter (surplus renouvelable sur le reseau)."))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Dimensionnement PV", tip("Simulez l'impact d'une installation PV plus grande ou plus petite. Les donnees sont mises a l'echelle proportionnellement.")),
        checkboxInput("pv_auto", "PV auto (couvre la PAC)", value = TRUE),
        conditionalPanel("input.pv_auto",
          uiOutput("pv_auto_display")),
        conditionalPanel("!input.pv_auto",
          sliderInput("pv_kwc_manual", "Puissance crete (kWc)", 1, 200, 6, step = 0.5)),
        conditionalPanel("input.data_source=='csv'",
          numericInput("pv_kwc_ref", "kWc reference (donnees CSV)", 6, min = 1, max = 200, step = 0.5),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Taille du PV dans vos donnees CSV. Le ratio kWc/ref rescale la production."))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Batterie", tip("Ajout d'une batterie electrochimique. Elle absorbe le surplus que le ballon ne peut plus stocker et le restitue en soiree.")),
        checkboxInput("batterie_active", "Activer la batterie", FALSE),
        conditionalPanel("input.batterie_active",
          numericInput("batt_kwh", "Capacite (kWh)", 10, min = 1, max = 50, step = 1),
          numericInput("batt_kw", "Puissance charge/decharge (kW)", 5, min = 0.5, max = 25, step = 0.5),
          sliderInput("batt_rendement", "Rendement aller-retour (%)", 70, 100, 90, step = 1),
          sliderInput("batt_soc_range", "Plage SoC (%)", 0, 100, c(10, 90), step = 5),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Rendement = part de l'energie recuperee apres un cycle charge/decharge (pertes thermiques). Plage SoC = limites min/max pour proteger la duree de vie."))),
      actionButton("run_sim", "Lancer la simulation", class = "btn-primary w-100 mt-2", icon = icon("play")),
      conditionalPanel("output.has_sim_result",
        downloadButton("download_csv", "Exporter CSV", class = "btn-outline-primary w-100 mt-1", icon = icon("download"))),
      tags$hr(style = sprintf("border-color:%s;margin:12px 0 8px 0;", cl$grid)),
      tags$div(style = "margin-top:8px;",
        actionButton("run_automagic", "Trouver la meilleure config", class = "w-100 mt-1",
          icon = icon("wand-magic-sparkles"),
          style = sprintf("background:linear-gradient(135deg,%s,%s);border:none;font-family:'JetBrains Mono',monospace;font-size:.78rem;letter-spacing:.05em;color:%s;",
            cl$accent3, "#6366f1", cl$text)),
        tags$div(class = "form-text text-center mt-1", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          "Grid search sur toutes les combinaisons")),
      tags$hr(style = sprintf("border-color:%s;margin:12px 0 8px 0;", cl$grid)),
      actionButton("show_guide", "Documentation", class = "w-100",
        icon = icon("book-open"),
        style = sprintf("background:transparent;border:1px solid %s;color:%s;font-family:'JetBrains Mono',monospace;font-size:.78rem;letter-spacing:.05em;",
          cl$grid, cl$text_muted))),
    
    uiOutput("status_bar"),

    navset_card_tab(id = "main_tabs",
      nav_panel(title = "Energie", icon = icon("bolt"),
        uiOutput("energy_kpi_row"),
        layout_columns(col_widths = c(4, 4, 4),
          card(full_screen = TRUE, card_header("Soutirage reseau"),
            card_body(plotlyOutput("plot_soutirage", height = "300px"))),
          card(full_screen = TRUE, card_header("Injection reseau"),
            card_body(plotlyOutput("plot_injection", height = "300px"))),
          card(full_screen = TRUE, card_header("Autoconsommation PV"),
            card_body(plotlyOutput("plot_autoconso", height = "300px")))),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Flux d'energie"),
            card_body(
              radioButtons("sankey_scenario", NULL, choices = c("Baseline" = "reel", "Optimise" = "optimise"), selected = "reel", inline = TRUE),
              plotlyOutput("plot_sankey", height = "350px"))))),
      nav_panel(title = "Finances", icon = icon("euro-sign"),
        uiOutput("finance_kpi_row"),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Facture nette cumulee — baseline vs optimise"),
            card_body(plotlyOutput("plot_cout_cumule", height = "320px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Decomposition de l'economie"),
            card_body(plotlyOutput("plot_waterfall", height = "300px"))),
          card(full_screen = TRUE, card_header("Bilan mensuel"),
            card_body(DTOutput("table_mensuel"))))),
      nav_panel(title = "Impact CO2", icon = icon("leaf"),
        layout_columns(col_widths = 12,
          uiOutput("co2_kpi_row")),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Impact CO2 horaire — baseline vs optimise"),
            card_body(plotlyOutput("plot_co2_hourly", height = "350px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("CO2 evite cumule"),
            card_body(plotlyOutput("plot_co2_cumul", height = "300px"))),
          card(full_screen = TRUE, card_header("Heatmap intensite CO2 du reseau"),
            card_body(plotlyOutput("plot_co2_heatmap", height = "300px")))),
        layout_columns(col_widths = 12,
          tags$div(style = sprintf("font-size:.75rem;color:%s;padding:4px 8px;", cl$text_muted),
            uiOutput("co2_data_source")))),
      nav_panel(title = "Details", icon = icon("magnifying-glass"),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("PAC — baseline vs optimise (timeline)"),
            card_body(plotlyOutput("plot_pac_timeline", height = "350px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Temperature ballon"),
            card_body(plotlyOutput("plot_temperature", height = "280px"))),
          card(full_screen = TRUE, card_header("COP journalier"),
            card_body(plotlyOutput("plot_cop", height = "280px")))),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Heatmap"),
            card_body(
              layout_columns(col_widths = c(4, 8),
                selectInput("heatmap_var", NULL, choices = c(
                  "Moins d'injection" = "inj_evitee", "Surplus PV" = "surplus",
                  "PAC ON (optimise)" = "pac_on", "Temperature ballon" = "t_ballon",
                  "Prix spot" = "prix"), selected = "inj_evitee"),
                tags$div()),
              plotlyOutput("plot_heatmap", height = "350px")))),
        conditionalPanel("input.batterie_active",
          layout_columns(col_widths = 12,
            card(full_screen = TRUE, card_header("Batterie — SoC"),
              card_body(plotlyOutput("plot_batterie", height = "250px")))))),
      nav_panel(title = "Dimensionnement", icon = icon("solar-panel"),
        explainer(
          tags$summary("Comprendre le dimensionnement"),
          tags$p("Outil d'aide a la decision pour ", tags$strong("dimensionner votre installation"), "."),
          tags$ul(
            tags$li(tags$strong("Scenarii PV :"), " compare automatiquement votre taille PV actuelle avec +/- 2 kWc. Le graphique montre le cout net annuel (barres) et le taux d'autoconsommation (ligne). Un PV plus grand produit plus mais injecte aussi plus — le point optimal depend de votre profil."),
            tags$li(tags$strong("Scenarii Batterie :"), " compare 5 tailles de batterie (0 a 20 kWh). Une batterie absorbe le surplus que le ballon ne peut plus stocker. Le cout diminue mais le retour sur investissement depend du prix de la batterie (non modelise ici)."),
            tags$li(tags$strong("Automagic :"), " teste ", tags$code("140 combinaisons"), " (7 tailles PV x 5 batteries x 2 modes x 2 contrats) et identifie la meilleure. La heatmap permet de voir les zones de cout optimal et les rendements decroissants.")
          ),
          tags$p(tags$strong("Conseil :"), " regardez le tableau des top 30. Parfois la 2e meilleure config coute 5 EUR de plus mais necessite une batterie beaucoup plus petite — ce qui peut etre plus rentable vu le cout d'achat.")),
        conditionalPanel("output.has_automagic",
          layout_columns(col_widths = 12,
            card(full_screen = TRUE, card_header(HTML("&#10024; Resultat Automagic — meilleure configuration")),
              card_body(
                uiOutput("automagic_best"),
                plotlyOutput("plot_automagic_heatmap", height = "350px"),
                DTOutput("table_automagic"))))),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Scenarii PV — impact du dimensionnement"),
            card_body(
              tags$div(class = "form-text mb-2", style = sprintf("color:%s;font-size:.8rem;", cl$text_muted),
                "Compare automatiquement le scenario actuel avec +/- 2 kWc par pas de 1 kWc."),
              plotlyOutput("plot_dim_pv", height = "350px")))),
        conditionalPanel("input.batterie_active",
          layout_columns(col_widths = 12,
            card(full_screen = TRUE, card_header("Scenarii Batterie — impact de la capacite"),
              card_body(plotlyOutput("plot_dim_batt", height = "350px")))))),
      nav_panel(title = "Comparaison", icon = icon("right-left"),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Comparer 2 ou 3 series temporelles"),
            card_body(
              layout_columns(col_widths = c(3, 3, 3, 3),
                selectInput("compare_var1", "Serie 1 (axe gauche)",
                  choices = NULL, selected = NULL),
                selectInput("compare_var2", "Serie 2 (axe droit)",
                  choices = NULL, selected = NULL),
                selectInput("compare_var3", "Serie 3 (optionnelle)",
                  choices = NULL, selected = NULL),
                dateRangeInput("compare_range", "Zoom periode",
                  start = Sys.Date() - 7, end = Sys.Date(), language = "fr")),
              plotlyOutput("plot_compare", height = "480px"))))),
      nav_panel(title = "Contraintes", icon = icon("check-circle"),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Temperature ballon vs bornes de confort"),
            card_body(uiOutput("cv_temp_summary"), plotlyOutput("plot_cv_temperature", height = "320px")))),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Bilan energetique — residu (entrees - sorties)"),
            card_body(uiOutput("cv_energy_summary"), plotlyOutput("plot_cv_energy_balance", height = "300px")))),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Coherence thermique — delta T predit vs simule"),
            card_body(plotlyOutput("plot_cv_thermal", height = "300px")))),
        conditionalPanel("input.batterie_active",
          layout_columns(col_widths = 12,
            card(full_screen = TRUE, card_header("Batterie — SoC vs bornes + anti-simultaneite"),
              card_body(uiOutput("cv_batt_summary"), plotlyOutput("plot_cv_battery", height = "320px")))))),
    ) # fin navset_card_tab
  ) # fin layout_sidebar
) # fin page_fillable

# =============================================================================
# SERVER
# =============================================================================

server <- function(input, output, session) {

  # ---- MODAL DOCUMENTATION ----
  observeEvent(input$show_guide, {
    showModal(modalDialog(
      title = NULL,
      size = "xl",
      easyClose = TRUE,
      footer = modalButton("Fermer"),
      tags$div(style = sprintf("color:%s;font-size:.85rem;line-height:1.6;", cl$text),
        tags$div(style = "text-align:center;margin-bottom:16px;",
          tags$h4(style = sprintf("color:%s;margin:0;", cl$accent), "Documentation — PAC Optimizer"),
          tags$p(style = sprintf("color:%s;font-size:.8rem;margin:4px 0 0 0;", cl$text_muted),
            "Cliquez sur une section pour la deplier.")),
        accordion(id = "guide_modal_accordion", open = FALSE,

          accordion_panel("1. Flux de donnees", icon = icon("database"),
            tags$p("A chaque quart d'heure, l'algorithme dispose des informations suivantes :"),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.75rem;color:%s;", cl$bg_input, cl$text_muted),
"DONNEES D'ENTREE (par quart d'heure)
\u251C\u2500\u2500 Grid meter \u2500\u2500\u2500\u2500 offtake + intake
\u251C\u2500\u2500 Production PV \u2500 kWh produits
\u251C\u2500\u2500 Temperature \u2500\u2500\u2500 ballon + exterieure
\u2514\u2500\u2500 Prix spot \u2500\u2500\u2500\u2500\u2500 Belpex (ENTSO-E)

DONNEES CALCULEES
\u251C\u2500\u2500 COP reel \u2500\u2500\u2500\u2500\u2500\u2500 f(T exterieure)
\u251C\u2500\u2500 Surplus PV \u2500\u2500\u2500\u2500 PV - conso hors PAC
\u251C\u2500\u2500 Pertes ballon \u2500 calibrees sur donnees
\u2514\u2500\u2500 Soutirage ECS \u2500 estime par chutes de T"),
            tags$p(tags$strong("Demo :"), " PV, conso et temperature synthetiques. ", tags$strong("CSV :"), " vos donnees. Dans les deux cas, les ", tags$strong("prix Belpex reels"), " sont injectes automatiquement.")
          ),

          accordion_panel("2. Modele thermique du ballon", icon = icon("temperature-half"),
            tags$p("Modele simple calibre sur vos donnees :"),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.78rem;color:%s;", cl$bg_input, cl$opti),
              "T(t+1) = T(t) + (chaleur_PAC - pertes - soutirage_ECS) / capacite_thermique"),
            tags$ul(
              tags$li(tags$strong("Chaleur PAC"), " = puissance x COP (varie avec T ext)"),
              tags$li(tags$strong("Pertes"), " = refroidissement naturel (calibre)"),
              tags$li(tags$strong("Capacite"), " = volume x 0.001163 kWh/L/degre"))
          ),

          accordion_panel("3. COP — Coefficient de Performance", icon = icon("gauge-high"),
            tags$p("Ratio chaleur produite / electricite consommee. Varie avec T exterieure :"),
            tags$ul(
              tags$li("0C : COP = 2.5"), tags$li("7C : COP = 3.5 (nominal)"),
              tags$li("15C : COP = 4.3"), tags$li("20C : COP = 4.8")),
            tags$p("Chauffer en journee = surplus PV + meilleur COP.")
          ),

          accordion_panel("4. Modes d'optimisation", icon = icon("sliders"),
            tags$h6(style = sprintf("color:%s;", cl$success), "SMART (Rule-based)"), tags$p("Decision basee sur la valeur nette a chaque quart d'heure. Compare le cout de chauffer maintenant vs plus tard en tenant compte du surplus PV, des prix spot et du COP. Tient compte des prix negatifs, de l'urgence confort et de l'anticipation de surplus futur."),
            tags$h6(style = sprintf("color:%s;", cl$opti), "OPTIMIZER (MILP)"), tags$p("Resout un probleme d'optimisation mathematique (MILP) qui minimise le cout net en respectant toutes les contraintes physiques. Trouve la solution optimale globale sur tout l'horizon, jour par jour.")
          ),

          accordion_panel("5. Types de decisions", icon = icon("code-branch"),
            tags$table(style = sprintf("width:100%%;font-size:.8rem;border-collapse:collapse;color:%s;", cl$text),
              tags$thead(tags$tr(style = sprintf("border-bottom:1px solid %s;", cl$grid),
                tags$th(style = "padding:6px;", "Decision"), tags$th(style = "padding:6px;", "PAC"), tags$th(style = "padding:6px;", "Signification"))),
              tags$tbody(
                tags$tr(tags$td(style = "padding:4px 6px;", "Urgence confort"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$danger), "ON"), tags$td(style = "padding:4px 6px;", "Ballon sous T min. Chauffage force.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Surplus PV"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "PV > conso. Stockage thermique.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Prix favorable"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "Parmi les 30% moins chers.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Soutirage pas cher"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "Prix spot tres bas.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Eviter inj. negative"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "Prix injection negatif.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Anticipation confort"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "Risque T min dans 30 min.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Ballon plein"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$text_muted), "OFF"), tags$td(style = "padding:4px 6px;", "T max atteinte.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Attente meilleur"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$text_muted), "OFF"), tags$td(style = "padding:4px 6px;", "Meilleur moment a venir.")),
                tags$tr(tags$td(style = "padding:4px 6px;", "Pas de surplus"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$text_muted), "OFF"), tags$td(style = "padding:4px 6px;", "Pas de PV, pas de raison eco."))
              ))
          ),

          accordion_panel("6. D'ou viennent les prix ?", icon = icon("coins"),
            tags$p("Marche day-ahead Belpex, publie par ENTSO-E Transparency."),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.75rem;color:%s;", cl$bg_input, cl$text_muted),
"TOUJOURS : prix reels Belpex (ENTSO-E)
  1. CSV locaux : data/belpex_historical_2024.csv et 2025.csv
  2. API ENTSO-E : si periode non couverte (cle dans .env)
  3. Fallback : prix synthetiques si rien ne marche"),
            tags$ul(
              tags$li(tags$strong("Publication :"), " ~13h, prix du lendemain. Quart-horaire (BE) depuis 2024."),
              tags$li(tags$strong("Prix negatifs :"), " vous payez pour injecter en contrat dynamique."),
              tags$li(tags$strong("Unite :"), " EUR/MWh converti en EUR/kWh dans l'app."))
          ),

          accordion_panel("7. Prix, ecologie et optimisation", icon = icon("leaf"),
            tags$p("Prix bas = renouvelable abondant = reseau vert. Prix haut = fossiles = carbone."),
            tags$p("Optimiser par le prix pousse a soutirer quand le reseau est vert. C'est vertueux."),
            tags$p(tags$strong("Nuance :"), " l'optimisation cout est la meilleure fonction objectif globale, mais stocker du PV qui aurait verdi le reseau en pointe est sous-optimal ecologiquement.")
          ),

          accordion_panel("8. Batterie electrochimique", icon = icon("battery-three-quarters"),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.75rem;color:%s;", cl$bg_input, cl$text_muted),
"PV \u2192 Conso residuelle \u2192 PAC \u2192 Batterie \u2192 Injection
Deficit \u2192 Batterie \u2192 Soutirage"),
            tags$ul(
              tags$li(tags$strong("Rendement :"), " 90% = 10% perdu/cycle."),
              tags$li(tags$strong("SoC :"), " 10-90% protege la duree de vie."),
              tags$li(tags$strong("Cycles :"), " lithium = 4000-6000 cycles."))
          ),

          accordion_panel("9. Backtest vs temps reel", icon = icon("clock-rotate-left"),
            tags$p(tags$strong("Backtest"), " (cette app) : prevision parfaite, gains optimaux."),
            tags$p(tags$strong("Temps reel :"), " previsions imparfaites, gains legerement inferieurs."),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.75rem;color:%s;", cl$bg_input, cl$text_muted),
"Passe (connu)            Present         Futur (inconnu)
Couts reels 5 modes  \u2192  choisir le  \u2192  esperer que
sur 14 derniers jours    meilleur       ca continue"),
            tags$p("Mode auto = adaptation, pas prediction. Fenetre courte = reactif. Longue = stable.")
          ),

          accordion_panel("10. Rule-based vs Optimiseur", icon = icon("scale-balanced"),
            tags$p("Cette app propose deux approches fondamentalement differentes pour piloter la PAC :"),
            tags$div(style = sprintf("background:%s;border:1px solid %s;border-radius:8px;padding:12px;margin:8px 0;", cl$bg_input, cl$grid),
              tags$h6(style = sprintf("color:%s;margin:0 0 6px 0;", cl$reel), "Rule-based (Smart)"),
              tags$p(style = "margin:0;", "A chaque quart d'heure, l'algo applique des regles : 'est-ce que chauffer maintenant coute moins cher que chauffer plus tard ?'. Decisions locales, basees sur la valeur nette."),
              tags$p(style = sprintf("margin:4px 0 0 0;font-size:.78rem;color:%s;", cl$text_muted), "Comme un joueur d'echecs qui decide coup par coup. Rapide (<1s).")),
            tags$div(style = sprintf("background:%s;border:1px solid %s;border-radius:8px;padding:12px;margin:8px 0;", cl$bg_input, cl$grid),
              tags$h6(style = sprintf("color:%s;margin:0 0 6px 0;", cl$success), "Optimiseur (MILP)"),
              tags$p(style = "margin:0;", "On declare l'objectif (minimiser la facture) et les contraintes (temperature, batterie, puissance). Un solveur mathematique (HiGHS) trouve la solution optimale sur tout le bloc simultanement."),
              tags$p(style = sprintf("margin:4px 0 0 0;font-size:.78rem;color:%s;", cl$text_muted), "Comme un joueur qui calcule 10 coups d'avance. Plus lent (~1 min pour 30 jours).")),
            tags$p(tags$strong("Exemple concret :"), " si les prix sont bas a 10h et tres eleves a 18h, l'optimiseur sait qu'il faut charger la batterie a 10h pour revendre a 18h. Le rule-based ne voit que l'heure en cours et peut rater cette opportunite."),
            tags$p(tags$strong("Quand utiliser quoi ?"), " Le rule-based est plus rapide et suffisant pour des profils de prix simples (contrat fixe). L'optimiseur brille en contrat dynamique avec des prix volatils et une batterie.")
          ),

          accordion_panel("11. Comment fonctionne l'optimiseur ?", icon = icon("microchip"),
            tags$p("L'optimiseur resout un probleme mathematique appele ", tags$strong("MILP"), " (Mixed Integer Linear Programming). Voici comment il fonctionne :"),

            tags$h6(style = sprintf("color:%s;margin:12px 0 6px 0;", cl$opti), "1. Decoupage en blocs"),
            tags$p("La periode simulee est decoupee en blocs (par defaut 4 heures = 16 quarts d'heure). Chaque bloc est resolu independamment, avec la temperature de fin du bloc precedent comme point de depart."),
            tags$p(tags$strong("Pourquoi des blocs ?"), " Resoudre 180 jours d'un coup (17 280 variables) serait trop lent. Des blocs de 4h (16 variables) se resolvent en <1 seconde chacun."),

            tags$h6(style = sprintf("color:%s;margin:12px 0 6px 0;", cl$opti), "2. Ce que le solveur decide"),
            tags$p("Pour chaque quart d'heure du bloc, le solveur choisit simultanement :"),
            tags$ul(
              tags$li("PAC ON ou OFF (variable binaire 0/1)"),
              tags$li("Si batterie : charge, decharge, ou rien"),
              tags$li("Combien soutirer du reseau, combien injecter")
            ),

            tags$h6(style = sprintf("color:%s;margin:12px 0 6px 0;", cl$opti), "3. L'objectif"),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.78rem;color:%s;", cl$bg_input, cl$opti),
              "Minimiser : somme( soutirage x prix_offtake - injection x prix_injection )"),
            tags$p("En clair : depenser le moins possible en electricite, tout en vendant au meilleur prix quand c'est rentable."),

            tags$h6(style = sprintf("color:%s;margin:12px 0 6px 0;", cl$opti), "4. Les contraintes"),
            tags$ul(
              tags$li(tags$strong("Bilan energetique :"), " a chaque qt, PV + soutirage = consommation + PAC + injection (+ batterie). L'energie se conserve."),
              tags$li(tags$strong("Dynamique thermique :"), " T(t+1) depend de T(t), de la chaleur PAC, des pertes, et des tirages ECS. Meme modele que le rule-based."),
              tags$li(tags$strong("Confort en fin de bloc :"), " la temperature du ballon doit etre dans [T_min, T_max] a la fin de chaque bloc. Intra-bloc, elle peut descendre temporairement (gros tirage ECS)."),
              tags$li(tags$strong("Batterie :"), " SOC dans les limites, pas de charge et decharge simultanee, rendement applique.")
            ),

            tags$h6(style = sprintf("color:%s;margin:12px 0 6px 0;", cl$opti), "5. Le parametre 'Horizon bloc'"),
            tags$p("Vous pouvez choisir la taille du bloc (1h a 24h) :"),
            tags$ul(
              tags$li(tags$strong("Bloc court (1-4h) :"), " rapide, mais l'optimiseur a peu de vision. Il ne peut pas anticiper un pic de prix dans 6h."),
              tags$li(tags$strong("Bloc moyen (6-12h) :"), " bon compromis. Voit les tendances de la journee."),
              tags$li(tags$strong("Bloc long (24h) :"), " solution optimale sur la journee entiere, mais plus lent (~10s/jour).")
            ),
            tags$p("En contrat fixe, la taille du bloc a peu d'impact (les prix ne varient pas). En contrat dynamique, un bloc plus long permet de mieux exploiter les variations de prix.")
          ),

          accordion_panel("12. Comprendre les resultats", icon = icon("chart-pie"),
            tags$h6(style = sprintf("color:%s;margin:0 0 8px 0;", cl$opti), "Pourquoi l'optimiseur est meilleur"),
            tags$p("L'optimiseur produit systematiquement une ", tags$strong("facture nette inferieure"), " au thermostat classique. Le mecanisme principal :"),
            tags$ul(
              tags$li(tags$strong("Moins de soutirage :"), " le thermostat classique chauffe la nuit (pas de PV, 100% reseau). L'optimiseur ne chauffe que quand c'est necessaire, au moment le moins cher."),
              tags$li(tags$strong("Moins de consommation totale :"), " le thermostat surchauffe souvent le ballon (cycle 48-52 C en permanence). L'optimiseur ne chauffe que le strict necessaire, ce qui reduit les pertes thermiques et donc la consommation totale."),
              tags$li(tags$strong("Autoconsommation vs facture :"), " l'optimiseur peut parfois injecter PLUS que le reel tout en coutant MOINS. C'est parce qu'il consomme moins au total (moins de pertes). Le taux d'autoconsommation n'est pas le bon indicateur — c'est la ", tags$strong("facture nette"), " qui compte.")
            ),

            tags$div(style = sprintf("background:%s;border:1px solid %s;border-radius:8px;padding:12px;margin:8px 0;", cl$bg_input, cl$grid),
              tags$h6(style = sprintf("color:%s;margin:0 0 6px 0;", cl$pv), "Pourquoi plus d'injection peut etre mieux"),
              tags$p(style = "margin:0;font-size:.82rem;", "Exemple : le thermostat chauffe inutilement le ballon de 48 a 52 C en journee (autoconsommant du PV), puis le ballon perd cette chaleur la nuit en pertes. L'optimiseur ne chauffe pas inutilement — le surplus PV est injecte (faible revenu a 0.03 EUR/kWh) mais le soutirage nocturne est evite (grosse economie a 0.30 EUR/kWh). La facture nette est meilleure malgre plus d'injection.")),

            tags$h6(style = sprintf("color:%s;margin:12px 0 8px 0;", cl$opti), "Contrat fixe vs dynamique"),
            tags$ul(
              tags$li(tags$strong("Contrat fixe :"), " l'economie vient uniquement du deplacement du volume (moins de soutirage, plus d'autoconsommation). Le timing ne compte pas car le prix est constant. L'economie est modeste car le thermostat classique autoconsomme deja partiellement par accident (il chauffe en journee quand le ballon est froid apres les tirages ECS du matin)."),
              tags$li(tags$strong("Contrat dynamique :"), " l'economie est plus importante car l'optimiseur exploite aussi les variations de prix horaires. Il soutire quand c'est pas cher, evite de soutirer quand c'est cher, et evite d'injecter quand les prix sont negatifs.")
            ),

            tags$h6(style = sprintf("color:%s;margin:12px 0 8px 0;", cl$opti), "La contrainte de confort"),
            tags$p("La temperature du ballon doit etre dans la plage [T_min, T_max] (definie par Consigne +/- Tolerance) ", tags$strong("a la fin de chaque bloc"), " d'optimisation. Intra-bloc, la temperature peut descendre temporairement sous T_min lors de gros tirages d'eau chaude — c'est physiquement inevitable et identique au comportement du thermostat classique."),
            tags$p("Si vous constatez des temperatures tres basses intra-bloc, c'est normal : un tirage de 3-4 kWh fait chuter la temperature de 15-20 degres instantanement dans un ballon de 200L. La PAC la remonte ensuite progressivement.")
          ),

          accordion_panel("13. Glossaire", icon = icon("spell-check"),
            tags$table(style = sprintf("width:100%%;font-size:.8rem;border-collapse:collapse;color:%s;", cl$text), tags$tbody(
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "Offtake"), tags$td(style = "padding:4px 6px;", "Electricite prelevee du reseau.")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "Intake"), tags$td(style = "padding:4px 6px;", "Electricite injectee (surplus PV).")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "Autoconso"), tags$td(style = "padding:4px 6px;", "Part du PV consomme sur place.")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "COP"), tags$td(style = "padding:4px 6px;", "Chaleur produite / electricite consommee.")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "kWc"), tags$td(style = "padding:4px 6px;", "Puissance crete PV (conditions standard).")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "Belpex"), tags$td(style = "padding:4px 6px;", "Marche belge, prix day-ahead.")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "SoC"), tags$td(style = "padding:4px 6px;", "Niveau de charge batterie (%).")),
              tags$tr(tags$td(style = sprintf("padding:4px 6px;font-weight:600;color:%s;", cl$opti), "Grid search"), tags$td(style = "padding:4px 6px;", "Test de toutes les combinaisons."))
            )))
        ) # fin accordion
      ) # fin tags$div
    )) # fin modalDialog + showModal
  })

  # Volume ballon : auto (dimensionne pour 2h de stockage thermique) ou manuel
  # Formule : V = P_pac * COP * heures_stockage / (delta_T * 0.001163)
  # delta_T = 2 * tolerance (plage complete T_min → T_max)
  # heures_stockage = 2h (permet de decaler 2h de chauffage vers les creux de prix/surplus PV)
  volume_ballon_eff <- reactive({
    if (isTRUE(input$volume_auto)) {
      p_kw <- input$p_pac_kw
      cop <- input$cop_nominal
      tol <- input$t_tolerance
      delta_t <- 2 * tol  # plage T_min → T_max
      heures_stockage <- 2
      # Energie thermique a stocker (kWh) = puissance thermique * duree
      energie_kwh <- p_kw * cop * heures_stockage
      # Volume = energie / (delta_T * capacite_specifique)
      vol <- energie_kwh / (delta_t * 0.001163)
      round(vol / 50) * 50  # arrondi au 50L le plus proche
    } else {
      input$volume_ballon_manual
    }
  })

  output$volume_auto_display <- renderUI({
    vol <- volume_ballon_eff()
    p_kw <- input$p_pac_kw; cop <- input$cop_nominal; tol <- input$t_tolerance
    delta_t <- 2 * tol
    cap_kwh <- vol * 0.001163 * delta_t  # capacite thermique reelle
    cap_elec <- round(cap_kwh / cop, 1)  # equivalent electrique
    heures_flex <- round(cap_kwh / (p_kw * cop), 1)  # heures de flexibilite
    tags$div(style = sprintf("font-size:.85rem;color:%s;padding:4px 8px;background:%s;border-radius:4px;margin-bottom:6px;",
      cl$opti, cl$bg_input),
      HTML(sprintf("<b>%s L</b> &middot; stockage <b>%s kWh<sub>th</sub></b> (%s kWh<sub>e</sub>) &middot; <b>%sh</b> de flexibilite",
        formatC(vol, format = "d", big.mark = " "), round(cap_kwh, 1), cap_elec, heures_flex)))
  })

  # PV auto : dimensionne pour couvrir la consommation annuelle de la PAC
  # Deux modeles selon la taille :
  #   Petite PAC (<= 10 kW) : modele ECS (pertes + tirages / COP)
  #   Grosse PAC (> 10 kW)  : modele heures equivalentes (chauffage + ECS)
  # Production : 950 kWh/kWc/an en Belgique (orientation sud, 35 deg)
  pv_kwc_eff <- reactive({
    if (isTRUE(input$pv_auto)) {
      p_pac <- input$p_pac_kw
      vol <- volume_ballon_eff()
      cop_moy <- input$cop_nominal

      if (p_pac <= 10) {
        # Petite PAC : modele ECS detaille
        pertes_jour_kwh <- 0.004 * (input$t_consigne - 20) * 24
        ecs_jour_kwh <- 6 * vol / 200
        conso_pac_an <- (ecs_jour_kwh + pertes_jour_kwh) / cop_moy * 365
      } else {
        # Grosse PAC (> 10 kW) : modele heures equivalentes
        # PAC mixte chauffage + ECS : ~5h equivalent pleine charge par jour
        # en moyenne annuelle (plus en hiver, moins en ete)
        heq_jour <- 5
        conso_pac_an <- p_pac * heq_jour * 365 / cop_moy
      }

      kwc <- conso_pac_an / 950
      round(kwc * 2) / 2  # arrondi au 0.5 kWc le plus proche
    } else {
      input$pv_kwc_manual
    }
  })

  output$pv_auto_display <- renderUI({
    kwc <- pv_kwc_eff()
    p_pac <- input$p_pac_kw
    vol <- volume_ballon_eff()
    cop <- input$cop_nominal

    if (p_pac <= 10) {
      pertes <- round(0.004 * (input$t_consigne - 20) * 24, 1)
      ecs <- round(6 * vol / 200, 1)
      conso <- round((ecs + pertes) / cop * 365)
      detail <- sprintf("ECS %.0f + pertes %.0f kWh/j", ecs, pertes)
    } else {
      conso <- round(p_pac * 5 * 365 / cop)
      detail <- sprintf("%s kW &times; 5h/j &divide; COP %s", p_pac, cop)
    }
    tags$div(style = sprintf("font-size:.85rem;color:%s;padding:4px 8px;background:%s;border-radius:4px;margin-bottom:6px;",
      cl$opti, cl$bg_input),
      HTML(sprintf("<b>%.1f kWc</b> (%d kWh/an &mdash; %s)", kwc, conso, detail)))
  })

  params_r <- reactive({
    vol <- volume_ballon_eff()
    kwc <- pv_kwc_eff()
    list(t_consigne = input$t_consigne, t_tolerance = input$t_tolerance,
      t_min = input$t_consigne - input$t_tolerance, t_max = input$t_consigne + input$t_tolerance,
      p_pac_kw = input$p_pac_kw, cop_nominal = input$cop_nominal, t_ref_cop = 7,
      volume_ballon_l = vol,
      capacite_kwh_par_degre = vol * 0.001163,
      horizon_qt = 16, seuil_surplus_pct = 0.3, dt_h = 0.25,
      type_contrat = input$type_contrat,
      taxe_transport_eur_kwh = ifelse(input$type_contrat == "dynamique", input$taxe_transport, 0),
      coeff_injection = ifelse(input$type_contrat == "dynamique", input$coeff_injection, 1),
      prix_fixe_offtake = ifelse(input$type_contrat == "fixe", input$prix_fixe_offtake, 0.30),
      prix_fixe_injection = ifelse(input$type_contrat == "fixe", input$prix_fixe_injection, 0.03),
      perte_kwh_par_qt = 0.05,
      pv_kwc = kwc,
      pv_kwc_ref = if (input$data_source == "csv") input$pv_kwc_ref else kwc,
      batterie_active = input$batterie_active,
      batt_kwh = input$batt_kwh, batt_kw = input$batt_kw,
      batt_rendement = input$batt_rendement / 100,
      batt_soc_min = input$batt_soc_range[1] / 100,
      batt_soc_max = input$batt_soc_range[2] / 100,
      poids_cout = 0.5,
      slack_penalty = if (!is.null(input$slack_penalty)) input$slack_penalty else 2.5,
      optim_bloc_h = if (!is.null(input$optim_bloc_h)) input$optim_bloc_h else 4)
  })
  
  raw_data <- reactive({
    if (input$data_source == "csv") {
      req(input$csv_file)
      df <- read_csv(input$csv_file$datapath, show_col_types = FALSE) %>% mutate(timestamp = ymd_hms(timestamp))
    } else {
      req(input$date_range)
      df <- generer_demo(input$date_range[1], input$date_range[2],
        p_pac_kw = input$p_pac_kw, volume_ballon_l = volume_ballon_eff(),
        pv_kwc = pv_kwc_eff(),
        ecs_kwh_jour = input$ecs_kwh_jour,
        building_type = if (!is.null(input$building_type)) input$building_type else "standard")
    }

    # Injecter les vrais prix Belpex (CSV uniquement — demo les charge deja dans generer_demo)
    if (input$data_source == "csv") {
      api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
      belpex <- load_belpex_prices(
        start_date = min(df$timestamp),
        end_date = max(df$timestamp),
        api_key = api_key,
        data_dir = "data"
      )
      if (!is.null(belpex$data) && nrow(belpex$data) > 0) {
        belpex_h <- belpex$data %>%
          mutate(
            datetime_bxl = with_tz(datetime, tzone = "Europe/Brussels"),
            heure_join = floor_date(datetime_bxl, unit = "hour"),
            prix_belpex = price_eur_mwh / 1000
          ) %>%
          distinct(heure_join, .keep_all = TRUE) %>%
          select(heure_join, prix_belpex)

        df <- df %>%
          mutate(heure_join = floor_date(timestamp, unit = "hour")) %>%
          left_join(belpex_h, by = "heure_join") %>%
          mutate(prix_eur_kwh = coalesce(prix_belpex, prix_eur_kwh)) %>%
          select(-heure_join, -prix_belpex)

        n_matched <- sum(!is.na(df$prix_eur_kwh) & df$prix_eur_kwh != 0)
        message(sprintf("[Belpex] %d/%d quarts d'heure avec prix reels", n_matched, nrow(df)))
      } else {
        showNotification("Prix Belpex indisponibles, prix synthetiques utilises", type = "warning", duration = 5)
      }
    }
    df
  })
  
  sim_running <- reactiveVal(FALSE)
  observeEvent(input$run_sim, { sim_running(TRUE) }, ignoreInit = TRUE)

  sim_result <- eventReactive(input$run_sim, {
    on.exit(sim_running(FALSE), add = TRUE)
    p <- params_r(); df <- raw_data()
    approche <- input$approche

    withProgress(message = "Preparation...", value = 0.1, {
      prep <- prepare_df(df, p)
      df_prep <- prep$df; p <- prep$params

      # Baseline : thermostat (reactif ou proactif selon choix utilisateur)
      proactif <- !is.null(input$thermostat_type) && input$thermostat_type == "proactif"
      setProgress(0.2, detail = paste0("Calcul baseline thermostat ", if (proactif) "proactif" else "reactif", "..."))
      df_prep <- run_baseline(df_prep, p, proactif = proactif)

      # Filet de securite : si l'optimisation fait pire que la baseline, garder la baseline
      guard_baseline <- function(sim, df_prep, p, mode_label) {
        facture_baseline <- sum(df_prep$offtake_kwh * df_prep$prix_offtake - df_prep$intake_kwh * df_prep$prix_injection, na.rm = TRUE)
        facture_opti <- sum(sim$sim_offtake * sim$prix_offtake - sim$sim_intake * sim$prix_injection, na.rm = TRUE)
        if (facture_opti > facture_baseline) {
          message(sprintf("[%s] Facture opti (%.1f) > baseline (%.1f) — fallback baseline", mode_label, facture_opti, facture_baseline))
          sim$sim_t_ballon <- df_prep$t_ballon
          sim$sim_offtake <- df_prep$offtake_kwh
          sim$sim_intake <- df_prep$intake_kwh
          sim$sim_cop <- calc_cop(df_prep$t_ext, p$cop_nominal, p$t_ref_cop)
          sim$decision_raison <- "baseline_fallback"
          sim$mode_actif <- paste0(mode_label, "_baseline")
          showNotification(sprintf("%s fait pire que la baseline — resultats baseline affiches", mode_label), type = "warning", duration = 8)
        }
        sim
      }

      if (approche == "optimiseur") {
        setProgress(0.3, detail = "Optimisation MILP en cours...")
        sim <- tryCatch({
          run_optimization_milp(df_prep, p)
        }, error = function(e) {
          showNotification(paste("Erreur optimiseur MILP:", e$message), type = "error", duration = 10)
          NULL
        })
        if (is.null(sim)) {
          showNotification("Optimisation MILP infaisable — verifiez les contraintes (tolerance temperature, etc.)", type = "error")
          sim <- run_simulation(df_prep, p, "smart", 0.5)
          sim$mode_actif <- "smart_fallback"
        } else {
          sim <- guard_baseline(sim, df_prep, p, "MILP")
        }
        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "optimizer")
      } else if (approche == "optimiseur_lp") {
        p$optim_bloc_h <- input$optim_bloc_h_lp
        setProgress(0.3, detail = "Optimisation LP en cours...")
        sim <- tryCatch({
          run_optimization_lp(df_prep, p)
        }, error = function(e) {
          showNotification(paste("Erreur optimiseur LP:", e$message), type = "error", duration = 10)
          NULL
        })
        if (is.null(sim)) {
          showNotification("Optimisation LP infaisable — verifiez les contraintes", type = "error")
          sim <- run_simulation(df_prep, p, "smart", 0.5)
          sim$mode_actif <- "smart_fallback"
        } else {
          sim <- guard_baseline(sim, df_prep, p, "LP")
        }
        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "optimizer_lp")
      } else if (approche == "optimiseur_qp") {
        p$optim_bloc_h <- input$optim_bloc_h_qp
        p$qp_w_comfort <- input$qp_w_comfort
        p$qp_w_smooth <- input$qp_w_smooth
        setProgress(0.3, detail = "Optimisation QP (CVXR) en cours...")
        sim <- tryCatch({
          run_optimization_qp(df_prep, p)
        }, error = function(e) {
          showNotification(paste("Erreur optimiseur QP:", e$message), type = "error", duration = 10)
          NULL
        })
        if (is.null(sim)) {
          showNotification("Optimisation QP infaisable — verifiez les contraintes", type = "error")
          sim <- run_simulation(df_prep, p, "smart", 0.5)
          sim$mode_actif <- "smart_fallback"
        } else {
          sim <- guard_baseline(sim, df_prep, p, "QP")
        }
        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "optimizer_qp")
      } else {
        setProgress(0.3, detail = "Simulation Smart en cours...")
        sim <- run_simulation(df_prep, p, "smart", 0.5)
        sim$mode_actif <- "smart"
        sim <- guard_baseline(sim, df_prep, p, "Smart")

        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "smart")
      }
    })
  })
  
  observeEvent(sim_result(), {
    res <- sim_result()
    sim <- res$sim
    p <- res$params
    mode <- res$mode
    # Debug log
    cr <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm=TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm=TRUE)
    co <- sum(sim$sim_offtake * sim$prix_offtake, na.rm=TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm=TRUE)
    jours <- round(as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days")), 1)
    thermostat <- if (!is.null(input$thermostat_type)) input$thermostat_type else "n/a"
    contrat <- if (p$type_contrat == "fixe") {
      sprintf("fixe %.3f/%.3f EUR/kWh", p$prix_fixe_offtake, p$prix_fixe_injection)
    } else {
      sprintf("spot (taxe=%.3f, coeff_inj=%.2f)", p$taxe_transport_eur_kwh, p$coeff_injection)
    }
    batt <- if (p$batterie_active) sprintf("%skWh/%skW rend=%.2f SoC[%d-%d]%%",
      p$batt_kwh, p$batt_kw, p$batt_rendement, round(p$batt_soc_min * 100), round(p$batt_soc_max * 100)) else "off"
    message("==================== SIMULATION ====================")
    message(sprintf("[PARAMS] Mode=%s | Baseline=%s | Periode=%.1f j (%d pts) | Source=%s",
      mode, thermostat, jours, nrow(sim), input$data_source))
    message(sprintf("[PARAMS] PV=%s kWc (ref=%s) | PAC=%s kW COP=%s | Ballon=%s L [%s..%s]C consigne=%s",
      p$pv_kwc, p$pv_kwc_ref, p$p_pac_kw, p$cop_nominal,
      p$volume_ballon_l, p$t_min, p$t_max, p$t_consigne))
    message(sprintf("[PARAMS] Contrat=%s | Batterie=%s | Bloc opti=%sh | Penalite slack=%s EUR/C",
      contrat, batt, if (!is.null(p$optim_bloc_h)) p$optim_bloc_h else "n/a",
      if (!is.null(p$slack_penalty)) p$slack_penalty else "n/a"))
    if (mode == "optimizer_qp") {
      message(sprintf("[PARAMS] QP poids: confort=%s lissage=%s", p$qp_w_comfort, p$qp_w_smooth))
    }
    message(sprintf("[RESULT] Offtake reel=%d opti=%d kWh | Injection reel=%d opti=%d kWh",
      round(sum(sim$offtake_kwh,na.rm=TRUE)), round(sum(sim$sim_offtake,na.rm=TRUE)),
      round(sum(sim$intake_kwh,na.rm=TRUE)), round(sum(sim$sim_intake,na.rm=TRUE))))
    message(sprintf("[RESULT] Cout reel=%.1f opti=%.1f EUR | GAIN=%.1f EUR (%.1f%%)",
      cr, co, cr-co, if (cr != 0) 100*(cr-co)/cr else 0))
    message("====================================================")
    updateDateRangeInput(session, "date_range",
      start = as.Date(min(sim$timestamp)), end = as.Date(max(sim$timestamp)),
      min = as.Date(min(sim$timestamp)), max = as.Date(max(sim$timestamp)))
  })

  sim_filtered <- reactive({
    req(sim_result(), input$date_range)
    sim <- sim_result()$sim
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + days(1)
    sim %>% filter(timestamp >= d1, timestamp < d2)
  })

  # ---- Onglet Comparaison ----
  # Variables disponibles pour la comparaison
  compare_vars <- c(
    "Production PV (kWh)" = "pv_kwh",
    "Soutirage baseline (kWh)" = "offtake_kwh",
    "Soutirage optimise (kWh)" = "sim_offtake",
    "Injection baseline (kWh)" = "intake_kwh",
    "Injection optimisee (kWh)" = "sim_intake",
    "Autoconsommation baseline (kWh)" = "autoconso_baseline",
    "Autoconsommation optimisee (kWh)" = "autoconso_opti",
    "Facture baseline (EUR)" = "facture_baseline",
    "Facture optimisee (EUR)" = "facture_opti",
    "Conso hors PAC (kWh)" = "conso_hors_pac",
    "Soutirage ECS (kWh)" = "soutirage_estime_kwh",
    "Temperature ballon baseline (C)" = "t_ballon",
    "Temperature ballon optimisee (C)" = "sim_t_ballon",
    "Temperature exterieure (C)" = "t_ext",
    "COP" = "sim_cop",
    "PAC on (optimise)" = "sim_pac_on",
    "Prix soutirage (EUR/kWh)" = "prix_offtake",
    "Prix injection (EUR/kWh)" = "prix_injection",
    "Prix spot (EUR/kWh)" = "prix_eur_kwh"
  )

  # Colonnes derivees (calculees a la volee dans compare_data)
  compare_derived <- c("autoconso_baseline", "autoconso_opti", "facture_baseline", "facture_opti")

  # Initialiser les selectInputs une fois le sim_result dispo
  observeEvent(sim_result(), {
    sim <- sim_result()$sim
    # Variables natives + derivees dispo
    avail_native <- compare_vars[compare_vars %in% names(sim)]
    avail_derived <- compare_vars[compare_vars %in% compare_derived]
    avail <- c(avail_native, avail_derived)
    updateSelectInput(session, "compare_var1", choices = avail,
      selected = if ("pv_kwh" %in% avail) "pv_kwh" else avail[1])
    updateSelectInput(session, "compare_var2", choices = avail,
      selected = if ("prix_eur_kwh" %in% avail) "prix_eur_kwh" else avail[min(2, length(avail))])
    # Serie 3 : "Aucune" par defaut
    avail3 <- c("Aucune" = "", avail)
    updateSelectInput(session, "compare_var3", choices = avail3, selected = "")
  })

  # Helper : extrait l'unite depuis le label d'une variable (entre parentheses)
  get_unit <- function(var) {
    if (is.null(var) || var == "") return(NA_character_)
    label <- names(compare_vars)[compare_vars == var]
    if (length(label) == 0) return(NA_character_)
    m <- regmatches(label, regexpr("\\(([^)]+)\\)", label))
    if (length(m) == 0) return(NA_character_)
    gsub("[()]", "", m)
  }

  # Sync compare_range avec date_range (bornes = simulation complete)
  observeEvent(input$date_range, {
    req(input$date_range)
    updateDateRangeInput(session, "compare_range",
      start = input$date_range[1], end = input$date_range[2],
      min = input$date_range[1], max = input$date_range[2])
  })

  # Filtrage local pour l'onglet comparaison + colonnes derivees
  compare_data <- reactive({
    req(sim_result(), input$compare_range)
    sim <- sim_result()$sim
    d1 <- as.POSIXct(input$compare_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$compare_range[2], tz = "Europe/Brussels") + days(1)
    sim %>%
      filter(timestamp >= d1, timestamp < d2) %>%
      mutate(
        autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
        autoconso_opti = pmax(0, pv_kwh - sim_intake),
        facture_baseline = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
        facture_opti = sim_offtake * prix_offtake - sim_intake * prix_injection
      )
  })

  output$plot_compare <- renderPlotly({
    req(compare_data(), input$compare_var1, input$compare_var2)
    df <- compare_data()
    v1 <- input$compare_var1; v2 <- input$compare_var2
    v3 <- input$compare_var3
    if (is.null(v3) || v3 == "") v3 <- NA_character_
    vars <- c(v1, v2, if (!is.na(v3)) v3 else NULL)
    if (!all(vars %in% names(df))) return(plot_ly())

    summable <- c("pv_kwh", "offtake_kwh", "sim_offtake", "intake_kwh", "sim_intake",
      "conso_hors_pac", "soutirage_estime_kwh", "sim_pac_on",
      "autoconso_baseline", "autoconso_opti",
      "facture_baseline", "facture_opti")

    # Agregation adaptative (somme ou moyenne selon la variable)
    nr <- nrow(df)
    level <- if (nr <= 14 * 96) "qt" else if (nr <= 60 * 96) "hour" else if (nr <= 180 * 96) "day" else "week"
    label <- c(qt = "15 min", hour = "Horaire", day = "Journalier", week = "Hebdomadaire")[level]

    df_work <- df %>% mutate(.w = case_when(
      level == "qt" ~ timestamp,
      level == "hour" ~ floor_date(timestamp, "hour"),
      level == "day" ~ floor_date(timestamp, "day"),
      level == "week" ~ floor_date(timestamp, "week")
    ))
    agg_exprs <- lapply(vars, function(v) {
      if (v %in% summable) rlang::expr(sum(.data[[!!v]], na.rm = TRUE))
      else rlang::expr(mean(.data[[!!v]], na.rm = TRUE))
    })
    names(agg_exprs) <- vars
    df_agg <- df_work %>% group_by(.w) %>%
      summarise(!!!agg_exprs, .groups = "drop") %>%
      rename(timestamp = .w)

    # Labels et unites
    label1 <- names(compare_vars)[compare_vars == v1]
    label2 <- names(compare_vars)[compare_vars == v2]
    unit1 <- get_unit(v1); unit2 <- get_unit(v2)

    # Couleurs : axe gauche (cyan/opti), axe droit (orange/accent3)
    # Serie 3 : meme axe qu'une des deux premieres selon l'unite
    # Couleur : variante (cyan2 ou accent2) pour la distinguer
    p <- plot_ly(df_agg, x = ~timestamp) %>%
      add_trace(y = df_agg[[v1]], type = "scatter", mode = "lines",
        name = label1, line = list(color = cl$opti, width = 2), yaxis = "y") %>%
      add_trace(y = df_agg[[v2]], type = "scatter", mode = "lines",
        name = label2, line = list(color = cl$accent3, width = 2), yaxis = "y2")

    if (!is.na(v3)) {
      label3 <- names(compare_vars)[compare_vars == v3]
      unit3 <- get_unit(v3)
      # Choix de l'axe : priorite match d'unite, sinon axe gauche
      if (!is.na(unit3) && !is.na(unit1) && unit3 == unit1) {
        axe3 <- "y"; col3 <- cl$success
      } else if (!is.na(unit3) && !is.na(unit2) && unit3 == unit2) {
        axe3 <- "y2"; col3 <- cl$pv
      } else {
        axe3 <- "y"; col3 <- cl$success
        showNotification(sprintf("Serie 3 (unite %s) placee sur l'axe gauche par defaut", unit3),
          type = "warning", duration = 3)
      }
      p <- p %>% add_trace(y = df_agg[[v3]], type = "scatter", mode = "lines",
        name = label3, line = list(color = col3, width = 2, dash = "dot"), yaxis = axe3)
    }

    p %>% layout(
      title = paste0("Agregation: ", label),
      yaxis = list(title = label1, tickfont = list(color = cl$opti),
        titlefont = list(color = cl$opti)),
      yaxis2 = list(title = label2, overlaying = "y", side = "right",
        tickfont = list(color = cl$accent3), titlefont = list(color = cl$accent3),
        gridcolor = "rgba(0,0,0,0)"),
      hovermode = "x unified"
    ) %>%
      pl_layout()
  })

  output$status_bar <- renderUI({
    p <- params_r()
    running <- sim_running()
    res <- tryCatch(sim_result(), error = function(e) NULL)
    has_sim <- !running && !is.null(res) && !is.null(res$sim)

    ml <- c(rulebased = "SMART", smart = "SMART", optimizer = "MILP", optimizer_lp = "LP", optimizer_qp = "QP")
    mode_label <- if (has_sim) ml[res$mode] else {
      a <- input$approche
      c(rulebased = "SMART", optimiseur = "MILP", optimiseur_lp = "LP", optimiseur_qp = "QP")[a]
    }
    if (is.na(mode_label) || is.null(mode_label)) mode_label <- "?"

    thermostat <- if (!is.null(input$thermostat_type)) input$thermostat_type else "n/a"
    contrat <- if (p$type_contrat == "fixe") {
      sprintf("fixe %.3f/%.3f EUR/kWh", p$prix_fixe_offtake, p$prix_fixe_injection)
    } else {
      sprintf("spot (taxe=%.3f, coeff_inj=%.2f)", p$taxe_transport_eur_kwh, p$coeff_injection)
    }
    batt <- if (p$batterie_active) sprintf("%skWh/%skW rend=%.2f SoC[%d-%d]%%",
      p$batt_kwh, p$batt_kw, p$batt_rendement, round(p$batt_soc_min * 100), round(p$batt_soc_max * 100)) else "off"
    bloc <- switch(input$approche %||% "rulebased",
      optimiseur = paste0(input$optim_bloc_h %||% 4, "h"),
      optimiseur_lp = paste0(input$optim_bloc_h_lp %||% 24, "h"),
      optimiseur_qp = paste0(input$optim_bloc_h_qp %||% 24, "h"),
      "n/a")

    header <- if (running) {
      tags$span(HTML(sprintf("SIMULATION %s EN COURS", mode_label)),
        tags$span(class = "spinner"),
        tags$span(class = "status-running", "..."))
    } else if (has_sim) {
      sim <- res$sim
      jours <- round(as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days")), 1)
      cr <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm=TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm=TRUE)
      co <- sum(sim$sim_offtake * sim$prix_offtake, na.rm=TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm=TRUE)
      gain <- cr - co
      pct <- if (cr != 0) 100 * gain / cr else 0
      gain_col <- if (gain > 0.01) cl$success else if (gain < -0.01) cl$danger else cl$text_muted
      tags$span(HTML(sprintf("SIMULATION %s — %.1f j &middot; %s pts &middot; GAIN <b style='color:%s'>%.1f EUR (%.1f%%)</b>",
        mode_label, jours, formatC(nrow(sim), format = "d", big.mark = " "),
        gain_col, gain, pct)))
    } else {
      tags$span(HTML(sprintf("PRET &middot; Mode selectionne : <b>%s</b>", mode_label)))
    }

    line_tag <- function(label, content) {
      tags$div(class = "status-line",
        tags$span(class = "status-tag", label),
        HTML(content))
    }

    tags$div(id = "status_bar",
      line_tag("RUN ", as.character(header)),
      line_tag("DIM ", sprintf("PV=<b>%s kWc</b> (ref=%s) &middot; PAC=<b>%s kW</b> COP=%s &middot; Ballon=<b>%s L</b> [%s..%s]&deg;C consigne=%s",
        p$pv_kwc, p$pv_kwc_ref, p$p_pac_kw, p$cop_nominal, p$volume_ballon_l, p$t_min, p$t_max, p$t_consigne)),
      line_tag("CFG ", sprintf("Contrat=<b>%s</b> &middot; Batterie=<b>%s</b> &middot; Bloc=<b>%s</b> &middot; Slack=<b>%s EUR/C</b> &middot; Baseline=<b>%s</b> &middot; Source=<b>%s</b>",
        contrat, batt, bloc, if (!is.null(input$slack_penalty)) input$slack_penalty else "n/a", thermostat, input$data_source))
    )
  })
  outputOptions(output, "status_bar", suspendWhenHidden = FALSE)

  # ---- KPIs ENERGIE (onglet Energie) ----
  output$energy_kpi_row <- renderUI({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()

    pv_tot    <- sum(sim$pv_kwh, na.rm = TRUE)
    inj_base  <- sum(sim$intake_kwh, na.rm = TRUE)
    inj_opti  <- sum(sim$sim_intake, na.rm = TRUE)
    offt_base <- sum(sim$offtake_kwh, na.rm = TRUE)
    offt_opti <- sum(sim$sim_offtake, na.rm = TRUE)
    ac_base   <- round((1 - inj_base / max(pv_tot, 1)) * 100, 1)
    ac_opti   <- round((1 - inj_opti / max(pv_tot, 1)) * 100, 1)
    pac_qt <- p$p_pac_kw * p$dt_h
    conso_pac_opti <- sum(sim$sim_pac_on * pac_qt, na.rm = TRUE)
    # Bilan energetique baseline : PAC = soutirage + PV - injection - conso hors PAC
    conso_pac_base <- sum(sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac, na.rm = TRUE)
    conso_pac_base <- max(0, conso_pac_base)

    kpis <- list(
      kpi_card(formatC(round(pv_tot), big.mark = " ", format = "d"),
        "Production PV", "kWh", cl$pv,
        tooltip = "Production photovoltaique totale sur la periode. Identique en baseline et optimise (meme ensoleillement)."),
      kpi_card(paste0(ac_opti, "%"),
        "Autoconsommation", "", cl$success,
        baseline_val = ac_base, opti_val = ac_opti,
        gain_val = round(ac_opti - ac_base, 1), gain_unit = "pts",
        tooltip = "Part du PV consommee sur place. = 1 - (injection / production PV). Plus c'est haut, moins on gaspille de PV."),
      kpi_card(formatC(round(offt_base - offt_opti), big.mark = " ", format = "d"),
        "Moins de soutirage", "kWh", cl$accent3,
        baseline_val = offt_base, opti_val = offt_opti, gain_invert = TRUE,
        gain_val = round(offt_base - offt_opti), gain_unit = "kWh",
        tooltip = "Reduction du soutirage reseau. = soutirage baseline - soutirage optimise. Chaque kWh evite est un kWh non achete."),
      kpi_card(formatC(round(inj_base - inj_opti), big.mark = " ", format = "d"),
        "Moins d'injection", "kWh", cl$opti,
        baseline_val = inj_base, opti_val = inj_opti, gain_invert = TRUE,
        gain_val = round(inj_base - inj_opti), gain_unit = "kWh",
        tooltip = "Reduction de l'injection reseau. = injection baseline - injection optimise. Energie gardee sur place plutot que vendue a bas prix."),
      kpi_card(formatC(round(conso_pac_opti), big.mark = " ", format = "d"),
        "Conso PAC", "kWh", cl$pac,
        baseline_val = conso_pac_base, opti_val = conso_pac_opti, gain_invert = TRUE,
        gain_val = round(conso_pac_opti - conso_pac_base), gain_unit = "kWh",
        tooltip = "Consommation electrique de la PAC. Baseline = bilan energetique (soutirage + PV - injection - conso hors PAC). Optimise = somme(taux_charge x puissance x dt). Moins = meilleur pilotage ou meilleur COP.")
    )

    if (p$batterie_active && !is.null(sim$batt_flux)) {
      charge_tot <- sum(pmax(0, sim$batt_flux), na.rm = TRUE)
      cycles <- round(charge_tot / max(p$batt_kwh, 1), 1)
      kpis <- c(kpis, list(
        kpi_card(cycles, "Cycles batterie", "", cl$accent3,
          tooltip = "Cycles complets de charge/decharge. = energie chargee totale / capacite batterie.")))
    }

    ncols <- length(kpis)
    cw <- rep(floor(12 / ncols), ncols)
    cw[1] <- 12 - sum(cw[-1])
    do.call(layout_columns, c(list(col_widths = cw, style = "margin-bottom:12px;"), kpis))
  })

  # ---- KPIs FINANCES (onglet Finances) ----
  output$finance_kpi_row <- renderUI({
    req(sim_filtered()); sim <- sim_filtered()

    facture_base <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) -
                    sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    facture_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) -
                    sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
    gain <- facture_base - facture_opti
    pct_gain <- if (abs(facture_base) > 0.01) round(gain / abs(facture_base) * 100, 1) else 0

    cout_sout_base <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE)
    cout_sout_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE)

    rev_inj_base <- sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    rev_inj_opti <- sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)

    prix_moy <- mean(sim$prix_offtake, na.rm = TRUE)

    layout_columns(col_widths = c(2, 2, 2, 2, 2, 2), style = "margin-bottom:12px;",
      kpi_card(paste0(round(facture_base), " EUR"),
        "Facture baseline", "", cl$reel,
        tooltip = "Cout net baseline = somme(soutirage x prix) - somme(injection x prix). Sans optimisation."),
      kpi_card(paste0(round(facture_opti), " EUR"),
        "Facture optimisee", "", cl$opti,
        baseline_val = facture_base, opti_val = facture_opti, gain_invert = TRUE,
        tooltip = "Cout net optimise = somme(soutirage_opti x prix) - somme(injection_opti x prix). Avec pilotage PAC."),
      kpi_card(paste0(ifelse(gain >= 0, "+", ""), round(gain), " EUR"),
        "Economie nette", "", if (gain >= 0) cl$success else cl$danger,
        tooltip = "Economie = facture baseline - facture optimisee. Inclut la reduction de soutirage, la variation d'injection et l'arbitrage horaire."),
      kpi_card(paste0(pct_gain, "%"),
        "Reduction facture", "", if (gain >= 0) cl$success else cl$danger,
        tooltip = "Reduction en % = economie / |facture baseline| x 100."),
      kpi_card(paste0(round(cout_sout_base - cout_sout_opti), " EUR"),
        "Eco. soutirage", "", cl$accent3,
        baseline_val = cout_sout_base, opti_val = cout_sout_opti, gain_invert = TRUE,
        tooltip = "Economie sur le soutirage = cout soutirage baseline - cout soutirage optimise. Principale source d'economie."),
      kpi_card(paste0(round(rev_inj_opti - rev_inj_base), " EUR"),
        "Delta injection", "", cl$pv,
        tooltip = "Variation du revenu d'injection = revenu injection optimise - revenu injection baseline. Negatif si l'optimisation reduit l'injection (normal : on autoconsomme plus).")
    )
  })
  
  # --- Helpers pour les 3 charts energie ---
  conso_data <- reactive({
    req(sim_filtered())
    sf <- sim_filtered()
    agg <- auto_aggregate(sf)
    d <- agg$data %>% mutate(
      soutirage_baseline = offtake_kwh,
      soutirage_opti = sim_offtake,
      injection_baseline = intake_kwh,
      injection_opti = sim_intake,
      autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
      autoconso_opti = pmax(0, pv_kwh - sim_intake)
    )
    list(data = d, label = agg$label)
  })

  output$plot_soutirage <- renderPlotly({
    req(conso_data()); cd <- conso_data()
    plot_ly(cd$data, x = ~timestamp) %>%
      add_bars(y = ~soutirage_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
      add_bars(y = ~soutirage_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
      layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })

  output$plot_injection <- renderPlotly({
    req(conso_data()); cd <- conso_data()
    plot_ly(cd$data, x = ~timestamp) %>%
      add_bars(y = ~injection_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
      add_bars(y = ~injection_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
      layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })

  output$plot_autoconso <- renderPlotly({
    req(conso_data()); cd <- conso_data()
    plot_ly(cd$data, x = ~timestamp) %>%
      add_bars(y = ~autoconso_baseline, name = "Baseline", marker = list(color = cl$pv, opacity = 0.6)) %>%
      add_bars(y = ~autoconso_opti, name = "Optimise", marker = list(color = cl$success)) %>%
      layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })
  
  output$plot_temperature <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    # Sous-echantillonner par heure (moyenne) — pas d'auto_aggregate qui somme les temperatures
    s <- sim %>% mutate(h = floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(t_ballon = mean(t_ballon, na.rm = TRUE),
                sim_t_ballon = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h)
    plot_ly(s, x = ~timestamp) %>%
      add_trace(y = ~t_ballon, type = "scatter", mode = "lines", name = "Baseline", line = list(color = cl$reel, width = 1)) %>%
      add_trace(y = ~sim_t_ballon, type = "scatter", mode = "lines", name = "Optimise", line = list(color = cl$opti, width = 1.5)) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_min, yend = p$t_min, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_max, yend = p$t_max, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      pl_layout(ylab = "C")
  })

  output$plot_cop <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()
    # Moyenne journaliere directe sur donnees brutes — pas d'auto_aggregate qui somme les COP
    d <- sim %>% filter(!is.na(sim_cop)) %>% mutate(jour = as.Date(timestamp)) %>%
      group_by(jour) %>% summarise(cop = mean(sim_cop, na.rm = TRUE), .groups = "drop")
    plot_ly(d, x = ~jour, y = ~cop, type = "scatter", mode = "lines", line = list(color = cl$pac, width = 1.5), fill = "tozeroy", fillcolor = "rgba(52,211,153,0.08)") %>% pl_layout(ylab = "COP")
  })
  
  # (plot_profil, plot_decisions, plot_prix_pac removed — content redistributed to other tabs)
  
  # ---- FINANCES : Facture nette cumulee reel vs optimise ----
  output$plot_cout_cumule <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()
    # Calculer la facture sur les donnees brutes (pas d'auto_aggregate qui somme les prix)
    d <- sim %>%
      mutate(
        facture_reel_qt = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
        facture_opti_qt = sim_offtake * prix_offtake - sim_intake * prix_injection
      ) %>%
      mutate(
        cum_reel = cumsum(ifelse(is.na(facture_reel_qt), 0, facture_reel_qt)),
        cum_opti = cumsum(ifelse(is.na(facture_opti_qt), 0, facture_opti_qt))
      )
    # Sous-echantillonner for performance
    d_h <- d %>% mutate(h = floor_date(timestamp, "hour")) %>%
      group_by(h) %>% slice_tail(n = 1) %>% ungroup()
    plot_ly(d_h, x = ~timestamp) %>%
      add_trace(y = ~cum_reel, type = "scatter", mode = "lines", name = "Facture baseline",
        line = list(color = cl$reel, width = 2), fill = "tozeroy", fillcolor = "rgba(249,115,22,0.08)") %>%
      add_trace(y = ~cum_opti, type = "scatter", mode = "lines", name = "Facture optimisee",
        line = list(color = cl$opti, width = 2), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.08)") %>%
      pl_layout(ylab = "Facture nette cumulee (EUR)")
  })


  # ---- DETAILS : PAC timeline — baseline vs optimise ----
  output$plot_pac_timeline <- renderPlotly({
    req(sim_filtered())
    sf <- sim_filtered()
    p <- if (!is.null(sim_result()$params)) sim_result()$params else params_r()
    pac_qt <- p$p_pac_kw * p$dt_h

    # Calculer la conso PAC par qt (reel et optimise)
    sf <- sf %>% mutate(
      pac_kwh_reel = ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0),
      pac_kwh_opti = sim_pac_on * pac_qt
    )

    # Auto-agreger
    agg <- auto_aggregate(sf)
    d <- agg$data

    plot_ly(d, x = ~timestamp) %>%
      # PV en fond (zone jaune)
      add_trace(y = ~pv_kwh, type = "scatter", mode = "lines", name = "Production PV",
        fill = "tozeroy", fillcolor = "rgba(251,191,36,0.12)",
        line = list(color = cl$pv, width = 1)) %>%
      # PAC reel (barres orange semi-transparentes)
      add_bars(y = ~pac_kwh_reel, name = "PAC baseline",
        marker = list(color = cl$reel, opacity = 0.4)) %>%
      # PAC optimise (barres cyan)
      add_bars(y = ~pac_kwh_opti, name = "PAC optimise",
        marker = list(color = cl$opti, opacity = 0.7)) %>%
      layout(barmode = "overlay", bargap = 0.05) %>%
      pl_layout(ylab = paste0("kWh (", agg$label, ")"))
  })

  # ---- DETAILS : Profil PAC reel vs optimise (moyenne horaire) ----
  output$plot_profil_pac <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- if (!is.null(sim_result()$params)) sim_result()$params else params_r()
    pac_qt <- p$p_pac_kw * p$dt_h

    pr <- sim %>%
      mutate(h = hour(timestamp) + minute(timestamp) / 60) %>%
      group_by(h) %>%
      summarise(
        pv = mean(pv_kwh, na.rm = TRUE),
        pac_reel = mean(ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0), na.rm = TRUE),
        pac_opti = mean(sim_pac_on * pac_qt, na.rm = TRUE),
        .groups = "drop"
      )

    plot_ly(pr, x = ~h) %>%
      add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV moyen",
        fill = "tozeroy", fillcolor = "rgba(251,191,36,0.12)",
        line = list(color = cl$pv, width = 1)) %>%
      add_trace(y = ~pac_reel, type = "scatter", mode = "lines", name = "PAC baseline",
        line = list(color = cl$reel, width = 2.5, dash = "dot")) %>%
      add_trace(y = ~pac_opti, type = "scatter", mode = "lines", name = "PAC optimise",
        line = list(color = cl$opti, width = 2.5)) %>%
      pl_layout(xlab = "Heure", ylab = "kWh moyen/qt")
  })
  
  # ---- INSIGHTS : Heatmap ----
  output$plot_heatmap <- renderPlotly({
    req(sim_filtered(), input$heatmap_var); sim <- sim_filtered()

    hm <- sim %>%
      mutate(jour = as.Date(timestamp), h = floor(hour(timestamp) + minute(timestamp) / 60)) %>%
      group_by(jour, h) %>%
      summarise(
        inj_evitee = sum(intake_kwh - sim_intake, na.rm = TRUE),
        surplus = sum(pmax(0, pv_kwh - conso_hors_pac), na.rm = TRUE),
        pac_on = sum(sim_pac_on, na.rm = TRUE) / 4,
        t_ballon = mean(sim_t_ballon, na.rm = TRUE),
        prix = mean(prix_eur_kwh, na.rm = TRUE) * 100,
        .groups = "drop"
      )

    v <- input$heatmap_var
    zlab <- c(inj_evitee = "Moins d'injection (kWh)", surplus = "Surplus PV (kWh)",
              pac_on = "PAC ON (frac.)", t_ballon = "T ballon (C)", prix = "Prix (cEUR/kWh)")

    cs <- if (v == "inj_evitee") list(c(0, cl$danger), c(0.5, "#1a1d27"), c(1, cl$success))
          else if (v == "prix") list(c(0, cl$success), c(0.5, cl$pv), c(1, cl$danger))
          else if (v == "t_ballon") list(c(0, cl$opti), c(0.5, cl$pv), c(1, cl$danger))
          else list(c(0, "#1a1d27"), c(1, cl$opti))

    # Pivoter en matrice pour plotly heatmap
    mat <- hm %>%
      select(jour, h, val = !!sym(v)) %>%
      tidyr::pivot_wider(names_from = h, values_from = val) %>%
      arrange(jour)

    jours <- mat$jour
    heures <- as.integer(colnames(mat)[-1])
    z_mat <- as.matrix(mat[, -1])

    # Matrice de texte hover
    txt_mat <- matrix(
      paste0(rep(format(jours, "%d %b %Y"), each = length(heures)), " ", rep(heures, length(jours)), "h\n",
             round(as.vector(t(z_mat)), 2), " ", zlab[v]),
      nrow = length(jours), ncol = length(heures), byrow = TRUE)

    plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
      colorscale = cs, hoverinfo = "text", text = txt_mat,
      colorbar = list(title = list(text = zlab[v], font = list(color = cl$text_muted, size = 9)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "Heure", ylab = NULL)
  })


  # ---- FINANCES : Decomposition de l'economie (waterfall) ----
  output$plot_waterfall <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()

    # Decomposition de l'economie
    moins_soutirage_kwh <- sum(sim$offtake_kwh, na.rm = TRUE) - sum(sim$sim_offtake, na.rm = TRUE)
    moins_injection_kwh <- sum(sim$intake_kwh, na.rm = TRUE) - sum(sim$sim_intake, na.rm = TRUE)

    # Economie soutirage = kWh evites * prix moyen offtake
    prix_moy_offt <- mean(sim$prix_offtake, na.rm = TRUE)
    prix_moy_inj <- mean(sim$prix_injection, na.rm = TRUE)

    eco_soutirage <- moins_soutirage_kwh * prix_moy_offt
    perte_injection <- moins_injection_kwh * prix_moy_inj

    # Arbitrage horaire (difference entre prix moyen et prix reel pondere)
    facture_reel <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    facture_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
    eco_totale <- facture_reel - facture_opti
    eco_arbitrage <- eco_totale - eco_soutirage + perte_injection

    labels <- c("Moins de soutirage", "Moins d'injection", "Arbitrage horaire", "Economie totale")
    values <- c(eco_soutirage, -perte_injection, eco_arbitrage, eco_totale)
    colors <- c(
      ifelse(eco_soutirage >= 0, cl$success, cl$danger),
      ifelse(-perte_injection >= 0, cl$success, cl$danger),
      ifelse(eco_arbitrage >= 0, cl$success, cl$danger),
      ifelse(eco_totale >= 0, cl$success, cl$danger)
    )
    measures <- c("relative", "relative", "relative", "total")

    plot_ly(
      x = labels, y = values,
      type = "waterfall",
      measure = measures,
      text = paste0(ifelse(values >= 0, "+", ""), round(values, 1), " EUR"),
      textposition = "outside",
      textfont = list(color = cl$text, size = 10, family = "JetBrains Mono"),
      connector = list(line = list(color = cl$grid, width = 1)),
      increasing = list(marker = list(color = cl$success)),
      decreasing = list(marker = list(color = cl$danger)),
      totals = list(marker = list(color = ifelse(eco_totale >= 0, cl$opti, cl$danger)))
    ) %>%
      pl_layout(ylab = "EUR") %>%
      layout(xaxis = list(tickfont = list(size = 10)))
  })

  output$table_mensuel <- renderDT({
    req(sim_filtered()); sim <- sim_filtered()
    m <- sim %>% mutate(mois = floor_date(timestamp, "month")) %>% group_by(mois) %>%
      summarise(`PV` = round(sum(pv_kwh, na.rm = TRUE)),
        `Facture baseline` = round(sum(offtake_kwh * prix_offtake - intake_kwh * prix_injection, na.rm = TRUE)),
        `Facture opti` = round(sum(sim_offtake * prix_offtake - sim_intake * prix_injection, na.rm = TRUE)),
        .groups = "drop") %>%
      mutate(Mois = format(mois, "%b %Y"), Economie = `Facture baseline` - `Facture opti`, `EUR/j` = round(Economie / days_in_month(mois), 2)) %>%
      select(Mois, PV, `Facture baseline`, `Facture opti`, Economie, `EUR/j`)
    datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
      formatStyle("Economie", color = styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
  })


  # ---- IMPACT CO2 ----

  # Reactive: fetch CO2 intensity once per simulation run
  co2_data <- reactive({
    req(sim_filtered())
    sim <- sim_filtered()
    start_d <- min(sim$timestamp, na.rm = TRUE)
    end_d   <- max(sim$timestamp, na.rm = TRUE)
    fetch_co2_intensity(start_d, end_d)
  })

  # Reactive: compute CO2 impact
  co2_impact <- reactive({
    req(sim_filtered(), co2_data())
    sim <- sim_filtered()
    co2_raw <- co2_data()
    co2_15min <- interpolate_co2_15min(co2_raw$df, sim$timestamp)
    compute_co2_impact(sim, co2_15min)
  })

  # ---- KPIs CO2 (onglet Impact CO2) ----
  output$co2_kpi_row <- renderUI({
    req(co2_impact())
    impact <- co2_impact()

    co2_base_kg <- sum(impact$co2_baseline_g, na.rm = TRUE) / 1000
    co2_opti_kg <- sum(impact$co2_opti_g, na.rm = TRUE) / 1000

    layout_columns(col_widths = c(2, 2, 2, 2, 2, 2), style = "margin-bottom:12px;",
      kpi_card(sprintf("%.1f", impact$co2_saved_kg),
        "CO2 evite", "kg", cl$success,
        baseline_val = co2_base_kg, opti_val = co2_opti_kg, gain_invert = TRUE,
        gain_val = round(impact$co2_saved_kg, 1), gain_unit = "kg",
        tooltip = "Emissions evitees = somme((soutirage_base - soutirage_opti) x intensite_CO2). Positif = moins de CO2 emis."),
      kpi_card(sprintf("%.0f", impact$intensity_before),
        "Intensite baseline", "gCO2/kWh", cl$reel,
        tooltip = "Intensite carbone moyenne ponderee par la consommation baseline. = somme(soutirage_base x intensite) / somme(soutirage_base)."),
      kpi_card(sprintf("%.0f", impact$intensity_after),
        "Intensite optimisee", "gCO2/kWh", cl$opti,
        baseline_val = impact$intensity_before, opti_val = impact$intensity_after, gain_invert = TRUE,
        gain_val = round(impact$intensity_after - impact$intensity_before), gain_unit = "gCO2/kWh",
        tooltip = "Intensite carbone moyenne ponderee par la consommation optimisee. Plus bas = consommation deplacee vers des heures plus vertes."),
      kpi_card(sprintf("%.1f%%", impact$co2_pct_reduction),
        "Reduction intensite", "", cl$success,
        tooltip = "Reduction de l'intensite carbone = (intensite_before - intensite_after) / intensite_before x 100."),
      kpi_card(sprintf("%.0f", impact$equiv_car_km),
        "Equiv. voiture", "km", "#22d3ee",
        tooltip = "Kilometres de voiture thermique equivalents au CO2 evite. Facteur : 120 gCO2/km (EU WLTP 2024)."),
      kpi_card(sprintf("%.1f", impact$equiv_trees_year),
        "Equiv. arbres", "/an", "#fbbf24",
        tooltip = "Nombre d'arbres necessaires pour absorber le CO2 evite en 1 an. Facteur : 25 kg CO2/arbre/an (FAO).")
    )
  })

  # Hourly CO2 impact chart (bars = saved/added, line = intensity)
  output$plot_co2_hourly <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(
        co2_saved_g   = impact$co2_saved_g,
        co2_intensity = impact$co2_intensity,
        h = floor_date(timestamp, "hour")
      ) %>%
      group_by(h) %>%
      summarise(
        co2_saved_g   = sum(co2_saved_g, na.rm = TRUE),
        co2_intensity = mean(co2_intensity, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      rename(timestamp = h)

    bar_colors <- ifelse(d$co2_saved_g >= 0, cl$success, cl$danger)

    plot_ly(d, x = ~timestamp) %>%
      add_bars(y = ~co2_saved_g, name = "CO2 evite (g)",
        marker = list(color = bar_colors)) %>%
      add_trace(y = ~co2_intensity, type = "scatter", mode = "lines",
        name = "Intensite reseau (gCO2/kWh)", yaxis = "y2",
        line = list(color = cl$accent3, width = 1.5, dash = "dot")) %>%
      pl_layout(ylab = "CO2 evite (g)") %>%
      layout(
        yaxis2 = list(
          title = "gCO2eq/kWh", overlaying = "y", side = "right",
          gridcolor = "transparent", tickfont = list(size = 10, color = cl$accent3),
          titlefont = list(color = cl$accent3, size = 11)
        ),
        barmode = "relative"
      )
  })

  # Cumulative CO2 saved
  output$plot_co2_cumul <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(co2_cumul_kg = impact$co2_saved_cumul_kg) %>%
      select(timestamp, co2_cumul_kg)

    plot_ly(d, x = ~timestamp, y = ~co2_cumul_kg, type = "scatter", mode = "lines",
      name = "CO2 evite cumule",
      fill = "tozeroy", fillcolor = "rgba(52,211,153,0.15)",
      line = list(color = cl$success, width = 2)) %>%
      pl_layout(ylab = "kg CO2eq evite")
  })

  # CO2 intensity heatmap (day x hour)
  output$plot_co2_heatmap <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(
        co2_intensity = impact$co2_intensity,
        jour = as.Date(timestamp),
        h = hour(timestamp)
      ) %>%
      group_by(jour, h) %>%
      summarise(co2 = mean(co2_intensity, na.rm = TRUE), .groups = "drop")

    mat <- d %>%
      tidyr::pivot_wider(names_from = h, values_from = co2) %>%
      arrange(jour)

    jours  <- mat$jour
    heures <- as.integer(colnames(mat)[-1])
    z_mat  <- as.matrix(mat[, -1])

    txt_mat <- matrix(
      paste0(rep(format(jours, "%d %b"), each = length(heures)), " ", rep(heures, length(jours)), "h\n",
             round(as.vector(t(z_mat)), 0), " gCO2/kWh"),
      nrow = length(jours), ncol = length(heures), byrow = TRUE)

    # Echelle : vert (bas carbone) → rouge (haut carbone)
    cs <- list(c(0, "#065f46"), c(0.3, "#34d399"), c(0.5, "#fbbf24"), c(0.8, "#f97316"), c(1, "#dc2626"))

    plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
      colorscale = cs, hoverinfo = "text", text = txt_mat,
      colorbar = list(title = list(text = "gCO2/kWh", font = list(color = cl$text_muted, size = 9)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "Heure", ylab = NULL)
  })

  # Source de donnees
  output$co2_data_source <- renderUI({
    req(co2_data())
    src <- co2_data()$source
    label <- switch(src,
      api_historical    = "Elia ODS192 (historique, consumption-based)",
      api_realtime      = "Elia ODS191 (temps reel, consumption-based)",
      api_generation_mix = "Elia ODS201 (calcule depuis le mix de generation)",
      fallback          = "Profil synthetique (moyennes belges 2024)"
    )
    icon_name <- if (src == "fallback") "triangle-exclamation" else "circle-check"
    icon_col  <- if (src == "fallback") cl$danger else cl$success
    tags$span(
      tags$i(class = paste0("fa fa-", icon_name), style = sprintf("color:%s;", icon_col)),
      sprintf(" Source CO2 : %s", label)
    )
  })

  # ---- Batterie SoC ----
  output$plot_batterie <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    if (!p$batterie_active || is.null(sim$batt_soc)) return(plot_ly() %>% pl_layout())

    plot_ly(sim, x = ~timestamp) %>%
      add_trace(y = ~batt_soc * 100, type = "scatter", mode = "lines", name = "SoC",
        fill = "tozeroy", fillcolor = "rgba(34,211,238,0.1)",
        line = list(color = cl$opti, width = 1.5)) %>%
      add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
        y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
        line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
      add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
        y = p$batt_soc_max * 100, yend = p$batt_soc_max * 100,
        line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
      pl_layout(ylab = "SoC (%)")
  })
  
  output$plot_sankey <- renderPlotly({
    req(sim_filtered(), input$sankey_scenario)
    sf <- sim_filtered()
    is_opti <- input$sankey_scenario == "optimise"

    pv_tot <- sum(sf$pv_kwh, na.rm = TRUE)
    if (is_opti) {
      inj <- sum(sf$sim_intake, na.rm = TRUE)
      off <- sum(sf$sim_offtake, na.rm = TRUE)
    } else {
      inj <- sum(sf$intake_kwh, na.rm = TRUE)
      off <- sum(sf$offtake_kwh, na.rm = TRUE)
    }
    pv_auto <- pv_tot - inj
    pac_elec <- if (is_opti) sum(sf$sim_pac_on * 0.5, na.rm = TRUE) else sum((sf$offtake_kwh > 0.4) * 0.5, na.rm = TRUE)
    maison <- pv_auto + off - pac_elec
    maison <- max(0, maison)

    # Nodes: 0=PV, 1=Reseau, 2=PAC, 3=Conso residuelle, 4=Injection
    nodes <- list(
      label = c("PV", "Reseau", "PAC", "Conso residuelle", "Injection"),
      color = c(cl$pv, cl$danger, cl$pac, cl$text_muted, cl$reel),
      pad = 20, thickness = 20
    )

    # Links: source -> target, value
    links <- list(
      source = c(0, 0, 0, 1, 1),
      target = c(2, 3, 4, 2, 3),
      value = c(
        min(pv_auto, pac_elec),          # PV -> PAC
        max(0, pv_auto - pac_elec),      # PV -> Conso residuelle
        inj,                              # PV -> Injection
        max(0, pac_elec - pv_auto),      # Reseau -> PAC
        max(0, off - max(0, pac_elec - pv_auto))  # Reseau -> Conso residuelle
      ),
      color = c(
        "rgba(251,191,36,0.4)",
        "rgba(251,191,36,0.2)",
        "rgba(249,115,22,0.4)",
        "rgba(248,113,113,0.4)",
        "rgba(248,113,113,0.2)"
      )
    )

    # Remove zero-value links
    mask <- links$value > 0.5
    links$source <- links$source[mask]
    links$target <- links$target[mask]
    links$value <- round(links$value[mask])
    links$color <- links$color[mask]

    plot_ly(type = "sankey", orientation = "h",
      node = list(
        label = paste0(nodes$label, " (", c(round(pv_tot), round(off), round(pac_elec), round(maison), round(inj)), " kWh)"),
        color = nodes$color,
        pad = nodes$pad, thickness = nodes$thickness,
        line = list(width = 0)
      ),
      link = list(
        source = links$source, target = links$target,
        value = links$value, color = links$color
      )
    ) %>% pl_layout()
  })



  # ---- CONTRAINTES : Temperature ballon vs bornes ----
  output$plot_cv_temperature <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    d <- sim %>% mutate(h = floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(t_bal = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h) %>%
      mutate(
        violation_low  = ifelse(t_bal < p$t_min, t_bal, NA_real_),
        violation_high = ifelse(t_bal > p$t_max, t_bal, NA_real_)
      )
    plot_ly(d, x = ~timestamp) %>%
      add_trace(y = ~t_bal, type = "scatter", mode = "lines", name = "T ballon optimise",
        line = list(color = cl$opti, width = 1.5)) %>%
      add_trace(y = ~violation_low, type = "scatter", mode = "markers", name = "Violation T_min",
        marker = list(color = cl$danger, size = 5, symbol = "circle"), hoverinfo = "x+y") %>%
      add_trace(y = ~violation_high, type = "scatter", mode = "markers", name = "Violation T_max",
        marker = list(color = "#f59e0b", size = 5, symbol = "diamond"), hoverinfo = "x+y") %>%
      add_segments(x = min(d$timestamp), xend = max(d$timestamp), y = p$t_min, yend = p$t_min,
        line = list(color = cl$danger, dash = "dash", width = 1), name = "T_min") %>%
      add_segments(x = min(d$timestamp), xend = max(d$timestamp), y = p$t_max, yend = p$t_max,
        line = list(color = "#f59e0b", dash = "dash", width = 1), name = "T_max") %>%
      pl_layout(ylab = "Temperature (C)")
  })

  output$cv_temp_summary <- renderUI({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    n_low  <- sum(sim$sim_t_ballon < p$t_min, na.rm = TRUE)
    n_high <- sum(sim$sim_t_ballon > p$t_max, na.rm = TRUE)
    n_tot  <- sum(!is.na(sim$sim_t_ballon))
    pct_ok <- round((1 - (n_low + n_high) / n_tot) * 100, 1)
    col <- if (pct_ok >= 99) cl$success else if (pct_ok >= 95) "#f59e0b" else cl$danger
    tags$div(style = sprintf("font-size:.82rem;color:%s;margin-bottom:6px;", cl$text_muted),
      HTML(sprintf("Conformite : <b style='color:%s'>%s%%</b> &middot; Violations T_min : <b>%d qt</b> (%.1f h) &middot; Violations T_max : <b>%d qt</b> (%.1f h)",
        col, pct_ok, n_low, n_low * 0.25, n_high, n_high * 0.25)))
  })

  # ---- CONTRAINTES : Bilan energetique ----
  output$plot_cv_energy_balance <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    pac_qt <- p$p_pac_kw * p$dt_h
    d <- sim %>% mutate(
      entrees = pv_kwh + sim_offtake,
      sorties = conso_hors_pac + sim_pac_on * pac_qt + sim_intake,
      residu  = entrees - sorties
    )
    # Ajouter batterie si active
    if (p$batterie_active && !is.null(sim$batt_flux)) {
      batt_eff <- sqrt(p$batt_rendement)
      d <- d %>% mutate(
        entrees = entrees + pmax(0, -batt_flux) * batt_eff,
        sorties = sorties + pmax(0, batt_flux),
        residu  = entrees - sorties
      )
    }
    d_h <- d %>% mutate(h = floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(residu = sum(residu, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h)
    plot_ly(d_h, x = ~timestamp) %>%
      add_bars(y = ~residu, name = "Residu",
        marker = list(color = ifelse(abs(d_h$residu) > 0.01, cl$danger, cl$success))) %>%
      pl_layout(ylab = "Residu (kWh)")
  })

  output$cv_energy_summary <- renderUI({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    pac_qt <- p$p_pac_kw * p$dt_h
    residu <- sim$pv_kwh + sim$sim_offtake - sim$conso_hors_pac - sim$sim_pac_on * pac_qt - sim$sim_intake
    if (p$batterie_active && !is.null(sim$batt_flux)) {
      batt_eff <- sqrt(p$batt_rendement)
      residu <- residu + pmax(0, -sim$batt_flux) * batt_eff - pmax(0, sim$batt_flux)
    }
    max_abs <- round(max(abs(residu), na.rm = TRUE), 4)
    sum_abs <- round(sum(abs(residu), na.rm = TRUE), 4)
    col <- if (max_abs < 0.001) cl$success else if (max_abs < 0.01) "#f59e0b" else cl$danger
    tags$div(style = sprintf("font-size:.82rem;color:%s;margin-bottom:6px;", cl$text_muted),
      HTML(sprintf("Residu max : <b style='color:%s'>%s kWh</b> &middot; Residu cumule abs : <b>%s kWh</b> &middot; %s",
        col, max_abs, sum_abs,
        if (max_abs < 0.001) "Bilan parfait" else if (max_abs < 0.01) "Ecarts negligeables" else "Ecarts detectes — verifier")))
  })

  # ---- CONTRAINTES : Coherence thermique ----
  output$plot_cv_thermal <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    cap <- p$capacite_kwh_par_degre
    k_perte <- 0.004 * p$dt_h
    t_amb <- 20
    pac_qt <- p$p_pac_kw * p$dt_h
    d <- sim %>% mutate(
      chaleur_pac = sim_pac_on * pac_qt * sim_cop,
      t_predit = (lag(sim_t_ballon) * (cap - k_perte) + chaleur_pac + k_perte * t_amb - soutirage_estime_kwh) / cap,
      ecart = sim_t_ballon - t_predit
    ) %>% filter(!is.na(ecart))
    d_h <- d %>% mutate(h = floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(ecart = mean(ecart, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h)
    plot_ly(d_h, x = ~timestamp) %>%
      add_bars(y = ~ecart, name = "Ecart T",
        marker = list(color = ifelse(abs(d_h$ecart) > 0.5, cl$danger, cl$success))) %>%
      pl_layout(ylab = "Ecart T simule - T predit (C)")
  })

  # ---- CONTRAINTES : Batterie SOC + anti-simultaneite ----
  output$plot_cv_battery <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    if (!p$batterie_active || is.null(sim$batt_soc)) return(plot_ly() %>% pl_layout())
    d <- sim %>% mutate(
      soc_pct = batt_soc * 100,
      soc_min_pct = p$batt_soc_min * 100,
      soc_max_pct = p$batt_soc_max * 100,
      charge   = pmax(0, batt_flux),
      decharge = pmax(0, -batt_flux),
      simult   = ifelse(charge > 0.001 & decharge > 0.001, soc_pct, NA_real_)
    )
    plot_ly(d, x = ~timestamp) %>%
      add_trace(y = ~soc_pct, type = "scatter", mode = "lines", name = "SoC",
        line = list(color = cl$opti, width = 1.5), fill = "tozeroy",
        fillcolor = "rgba(34,211,238,0.08)") %>%
      add_trace(y = ~simult, type = "scatter", mode = "markers", name = "Charge+decharge simultanées",
        marker = list(color = cl$danger, size = 7, symbol = "x"), hoverinfo = "x+y") %>%
      add_segments(x = min(d$timestamp), xend = max(d$timestamp),
        y = d$soc_min_pct[1], yend = d$soc_min_pct[1],
        line = list(color = cl$danger, dash = "dash", width = 1), name = "SoC min") %>%
      add_segments(x = min(d$timestamp), xend = max(d$timestamp),
        y = d$soc_max_pct[1], yend = d$soc_max_pct[1],
        line = list(color = "#f59e0b", dash = "dash", width = 1), name = "SoC max") %>%
      pl_layout(ylab = "SoC (%)")
  })

  output$cv_batt_summary <- renderUI({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    if (!p$batterie_active || is.null(sim$batt_soc)) return(NULL)
    soc <- sim$batt_soc
    n_below <- sum(soc < p$batt_soc_min - 0.001, na.rm = TRUE)
    n_above <- sum(soc > p$batt_soc_max + 0.001, na.rm = TRUE)
    charge   <- pmax(0, sim$batt_flux)
    decharge <- pmax(0, -sim$batt_flux)
    n_simult <- sum(charge > 0.001 & decharge > 0.001, na.rm = TRUE)
    col_soc <- if (n_below + n_above == 0) cl$success else cl$danger
    col_sim <- if (n_simult == 0) cl$success else cl$danger
    tags$div(style = sprintf("font-size:.82rem;color:%s;margin-bottom:6px;", cl$text_muted),
      HTML(sprintf("Bornes SoC : <b style='color:%s'>%d violations</b> (min: %d, max: %d) &middot; Anti-simultaneite : <b style='color:%s'>%d violations</b>",
        col_soc, n_below + n_above, n_below, n_above, col_sim, n_simult)))
  })

  # ---- AUTOMAGIC : grid search ----
  automagic_results <- reactiveVal(NULL)
  
  output$has_automagic <- reactive({ !is.null(automagic_results()) })
  outputOptions(output, "has_automagic", suspendWhenHidden = FALSE)
  
  observeEvent(input$run_automagic, {
    p <- params_r()
    df_raw <- raw_data()
    
    # Grille de recherche
    pv_range   <- seq(max(1, p$pv_kwc - 3), p$pv_kwc + 3, by = 1)
    batt_range <- c(0, 5, 10, 15, 20)
    modes      <- c("smart", "optimizer", "optimizer_lp", "optimizer_qp")
    contrats   <- c("fixe", "dynamique")
    
    total <- length(pv_range) * length(batt_range) * length(modes) * length(contrats)
    
    withProgress(message = "Automagic en cours...", value = 0, {
      
      resultats <- list()
      k <- 0
      
      for (ct in contrats) {
        # Préparer le df une fois par type de contrat
        p_ct <- p
        p_ct$type_contrat <- ct
        if (ct == "fixe") {
          p_ct$taxe_transport_eur_kwh <- 0
          p_ct$prix_fixe_offtake <- p$prix_fixe_offtake
          p_ct$prix_fixe_injection <- p$prix_fixe_injection
        }
        
        for (pv_kwc in pv_range) {
          p_ct$pv_kwc <- pv_kwc
          prep_ct <- prepare_df(df_raw, p_ct)
          df_prep <- prep_ct$df; p_ct <- prep_ct$params
          # Rescaler PV
          ratio <- pv_kwc / p$pv_kwc_ref
          df_prep$pv_kwh <- df_raw$pv_kwh * ratio
          # Baseline thermostat (meme type que la simulation principale)
          proactif_am <- !is.null(input$thermostat_type) && input$thermostat_type == "proactif"
          df_prep <- run_baseline(df_prep, p_ct, proactif = proactif_am)
          
          for (bkwh in batt_range) {
            p_sim <- p_ct
            p_sim$batterie_active <- bkwh > 0
            p_sim$batt_kwh <- bkwh
            p_sim$batt_kw <- min(bkwh / 2, 5)  # rule of thumb C/2
            
            for (m in modes) {
              k <- k + 1
              setProgress(k / total, detail = sprintf("%d/%d — PV %dkWc Batt %dkWh %s %s",
                k, total, pv_kwc, bkwh, m, ct))
              
              tryCatch({
                sim <- if (m == "optimizer") {
                  run_optimization_milp(df_prep, p_sim)
                } else if (m == "optimizer_lp") {
                  run_optimization_lp(df_prep, p_sim)
                } else if (m == "optimizer_qp") {
                  p_sim$qp_w_comfort <- 0.1
                  p_sim$qp_w_smooth <- 0.05
                  run_optimization_qp(df_prep, p_sim)
                } else {
                  run_simulation(df_prep, p_sim, "smart", 0.5)
                }
                
                pv_tot  <- sum(sim$pv_kwh, na.rm = TRUE)
                inj_tot <- sum(sim$sim_intake, na.rm = TRUE)
                off_tot <- sum(sim$sim_offtake, na.rm = TRUE)
                cout_net <- sum(sim$sim_offtake * sim$prix_offtake - 
                                sim$sim_intake * sim$prix_injection, na.rm = TRUE)
                autoconso <- if (pv_tot > 0) (1 - inj_tot / pv_tot) * 100 else 0
                
                resultats[[k]] <- tibble(
                  PV_kWc = pv_kwc, Batterie_kWh = bkwh,
                  Mode = m, Contrat = ct,
                  Cout_EUR = round(cout_net),
                  Autoconso_pct = round(autoconso, 1),
                  Injection_kWh = round(inj_tot),
                  Soutirage_kWh = round(off_tot)
                )
              }, error = function(e) {
                resultats[[k]] <<- tibble(
                  PV_kWc = pv_kwc, Batterie_kWh = bkwh,
                  Mode = m, Contrat = ct,
                  Cout_EUR = NA_real_, Autoconso_pct = NA_real_,
                  Injection_kWh = NA_real_, Soutirage_kWh = NA_real_
                )
              })
            }
          }
        }
      }
    })
    
    all_res <- bind_rows(resultats) %>% filter(!is.na(Cout_EUR)) %>% arrange(Cout_EUR)
    automagic_results(all_res)
    
    # Switch to Dimensionnement tab
    updateNavsetCardTab(session, "main_tabs", selected = "Dimensionnement")
    showNotification(
      sprintf("Automagic termine! %d combinaisons testees. Meilleur cout: %d EUR/an",
              nrow(all_res), all_res$Cout_EUR[1]),
      type = "message", duration = 8)
  })
  
  output$automagic_best <- renderUI({
    req(automagic_results())
    best <- automagic_results() %>% slice(1)
    
    tags$div(style = sprintf("background:%s;border-radius:8px;padding:16px;margin-bottom:16px;", cl$bg_input),
      layout_columns(col_widths = c(2, 2, 2, 2, 2, 2),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$accent), paste0(best$PV_kWc, " kWc")),
          tags$div(class = "kpi-label", "PV optimal")),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", "#818cf8"), paste0(best$Batterie_kWh, " kWh")),
          tags$div(class = "kpi-label", "Batterie")),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$success), toupper(best$Mode)),
          tags$div(class = "kpi-label", "Mode")),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$pv), toupper(best$Contrat)),
          tags$div(class = "kpi-label", "Contrat")),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$success), paste0(best$Cout_EUR, " EUR")),
          tags$div(class = "kpi-label", "Facture nette/an")),
        tags$div(class = "text-center",
          tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$opti), paste0(best$Autoconso_pct, "%")),
          tags$div(class = "kpi-label", "Autoconsommation"))
      ),
      tags$div(style = sprintf("text-align:center;margin-top:8px;font-size:.7rem;color:%s;", cl$text_muted),
        actionButton("apply_best", "Appliquer cette configuration",
          icon = icon("check"),
          style = sprintf("background:%s;border:none;color:%s;font-family:'JetBrains Mono',monospace;font-size:.78rem;margin-top:4px;",
            cl$success, cl$bg_dark)))
    )
  })
  
  # Appliquer la meilleure config
  observeEvent(input$apply_best, {
    req(automagic_results())
    best <- automagic_results() %>% slice(1)
    
    updateCheckboxInput(session, "pv_auto", value = FALSE)
    updateSliderInput(session, "pv_kwc_manual", value = best$PV_kWc)
    updateCheckboxInput(session, "batterie_active", value = best$Batterie_kWh > 0)
    updateNumericInput(session, "batt_kwh", value = best$Batterie_kWh)
    if (best$Mode == "optimizer") {
      updateRadioButtons(session, "approche", selected = "optimiseur")
    } else if (best$Mode == "optimizer_lp") {
      updateRadioButtons(session, "approche", selected = "optimiseur_lp")
    } else if (best$Mode == "optimizer_qp") {
      updateRadioButtons(session, "approche", selected = "optimiseur_qp")
    } else {
      updateRadioButtons(session, "approche", selected = "rulebased")
    }
    updateRadioButtons(session, "type_contrat", selected = best$Contrat)
    
    showNotification("Configuration appliquee! Lancez la simulation pour voir les details.", type = "message")
  })
  
  # Heatmap PV x Batterie (meilleur mode pour chaque combo)
  output$plot_automagic_heatmap <- renderPlotly({
    req(automagic_results())
    res <- automagic_results()
    
    # Pour chaque combo PV x Batterie, garder le meilleur coût
    best_per_combo <- res %>%
      group_by(PV_kWc, Batterie_kWh) %>%
      slice_min(Cout_EUR, n = 1, with_ties = FALSE) %>%
      ungroup()
    
    plot_ly(best_per_combo, x = ~factor(PV_kWc), y = ~factor(Batterie_kWh),
      z = ~Cout_EUR, type = "heatmap",
      text = ~paste0(Cout_EUR, " EUR\n", Mode, " / ", Contrat, "\nAC: ", Autoconso_pct, "%"),
      hoverinfo = "text",
      colorscale = list(c(0, cl$success), c(0.5, cl$pv), c(1, cl$danger)),
      colorbar = list(title = list(text = "EUR/an", font = list(color = cl$text_muted, size = 10)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "PV installe (kWc)", ylab = "Batterie (kWh)")
  })
  
  # Table complète
  output$table_automagic <- renderDT({
    req(automagic_results())
    res <- automagic_results() %>%
      rename(`PV (kWc)` = PV_kWc, `Batt (kWh)` = Batterie_kWh,
             `Facture (EUR)` = Cout_EUR, `AC (%)` = Autoconso_pct,
             `Inj (kWh)` = Injection_kWh, `Offt (kWh)` = Soutirage_kWh) %>%
      head(30)
    
    datatable(res, rownames = FALSE,
      options = list(dom = "tip", pageLength = 10, order = list(list(4, "asc"))),
      class = "compact",
      caption = "Top 30 configurations (triees par facture croissante)") %>%
      formatStyle("Facture (EUR)", fontWeight = "bold",
        color = styleInterval(
          quantile(res$`Facture (EUR)`, c(0.33, 0.66), na.rm = TRUE),
          c(cl$success, cl$pv, cl$danger)))
  })
  
  # ---- Dimensionnement PV ----
  output$plot_dim_pv <- renderPlotly({
    req(sim_result(), input$date_range); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + days(1)
    df_base <- res$df %>% filter(timestamp >= d1, timestamp < d2)

    kwc_ref <- p$pv_kwc
    kwc_range <- seq(max(1, kwc_ref - 2), kwc_ref + 2, by = 1)

    scenarii <- bind_rows(lapply(kwc_range, function(kwc) {
      p_sc <- p; p_sc$pv_kwc <- kwc; p_sc$pv_kwc_ref <- p$pv_kwc  # already scaled in res$df
      df_sc <- df_base %>% mutate(pv_kwh = pv_kwh * kwc / kwc_ref)
      sim_sc <- run_simulation(df_sc, p_sc, "smart", 0.5)
      tibble(
        kWc = kwc,
        `Injection (kWh)` = round(sum(sim_sc$sim_intake, na.rm = TRUE)),
        `Soutirage (kWh)` = round(sum(sim_sc$sim_offtake, na.rm = TRUE)),
        `Autoconso (%)` = round((1 - sum(sim_sc$sim_intake, na.rm = TRUE) / max(sum(sim_sc$pv_kwh, na.rm = TRUE), 1)) * 100, 1),
        `Facture nette (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))
    
    is_current <- scenarii$kWc == kwc_ref
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)
    
    p1 <- plot_ly() %>%
      add_bars(data = scenarii, x = ~factor(kWc), y = ~`Facture nette (EUR)`, name = "Facture nette",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
        textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
      add_trace(data = scenarii, x = ~factor(kWc), y = ~`Autoconso (%)`, name = "Autoconso %",
        type = "scatter", mode = "lines+markers", yaxis = "y2",
        line = list(color = cl$success, width = 2),
        marker = list(color = cl$success, size = 8)) %>%
      layout(
        yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
          gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
          titlefont = list(color = cl$success)),
        barmode = "group"
      ) %>%
      pl_layout(xlab = "kWc installe", ylab = "Facture nette (EUR/an)")
    p1
  })
  
  # ---- Dimensionnement batterie ----
  output$plot_dim_batt <- renderPlotly({
    req(sim_result(), input$date_range); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    if (!p$batterie_active) return(plot_ly() %>% pl_layout())
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + days(1)
    df_base <- res$df %>% filter(timestamp >= d1, timestamp < d2)

    cap_range <- c(0, 5, 10, 15, 20)

    scenarii <- bind_rows(lapply(cap_range, function(cap) {
      p_sc <- p
      p_sc$batterie_active <- cap > 0
      p_sc$batt_kwh <- cap
      sim_sc <- run_simulation(df_base, p_sc, "smart", 0.5)
      tibble(
        `Batterie (kWh)` = cap,
        `Injection (kWh)` = round(sum(sim_sc$sim_intake, na.rm = TRUE)),
        `Soutirage (kWh)` = round(sum(sim_sc$sim_offtake, na.rm = TRUE)),
        `Autoconso (%)` = round((1 - sum(sim_sc$sim_intake, na.rm = TRUE) / max(sum(sim_sc$pv_kwh, na.rm = TRUE), 1)) * 100, 1),
        `Facture nette (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))
    
    is_current <- scenarii$`Batterie (kWh)` == p$batt_kwh
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)
    
    plot_ly() %>%
      add_bars(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Facture nette (EUR)`, name = "Facture nette",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
        textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
      add_trace(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Autoconso (%)`, name = "Autoconso %",
        type = "scatter", mode = "lines+markers", yaxis = "y2",
        line = list(color = cl$success, width = 2),
        marker = list(color = cl$success, size = 8)) %>%
      layout(
        yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
          gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
          titlefont = list(color = cl$success)),
        barmode = "group"
      ) %>%
      pl_layout(xlab = "Capacite batterie (kWh)", ylab = "Facture nette (EUR/an)")
  })

  # ----------------------------------------------------------
  # CSV Export
  # ----------------------------------------------------------
  output$has_sim_result <- reactive({ !is.null(tryCatch(sim_result(), error = function(e) NULL)) })
  outputOptions(output, "has_sim_result", suspendWhenHidden = FALSE)

  output$download_csv <- downloadHandler(
    filename = function() {
      paste0("pac_optimizer_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv")
    },
    content = function(file) {
      req(sim_filtered())
      sim <- sim_filtered()
      export <- sim %>% select(
        timestamp, t_ext, pv_kwh, prix_offtake, prix_injection,
        conso_hors_pac, soutirage_estime_kwh,
        t_ballon_baseline = t_ballon, offtake_baseline = offtake_kwh, injection_baseline = intake_kwh,
        t_ballon_opti = sim_t_ballon, offtake_opti = sim_offtake, injection_opti = sim_intake,
        pac_on_opti = sim_pac_on, cop_opti = sim_cop, decision = decision_raison
      )
      if (!is.null(sim$batt_soc)) {
        export$batt_soc <- sim$batt_soc
        export$batt_flux <- sim$batt_flux
      }
      write.csv(export, file, row.names = FALSE)
    }
  )
}

shinyApp(ui, server)
