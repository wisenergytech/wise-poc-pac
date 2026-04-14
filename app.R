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
source("R/optimizer.R", local = TRUE)

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

calc_cop <- function(t_ext, cop_nominal = 3.5, t_ref = 7) {
  cop <- cop_nominal + 0.1 * (t_ext - t_ref)
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
  
  if (t_actuelle < params$t_min) return(list(pac_on = 1L, raison = "urgence_confort"))
  if (t_actuelle >= params$t_max) return(list(pac_on = 0L, raison = "ballon_plein"))
  
  surplus_futur <- pv_futur - conso_hp_fut
  cop_futur     <- calc_cop(t_ext_futur, params$cop_nominal, params$t_ref_cop)
  
  t_simul <- t_actuelle
  qt_avant_t_min <- length(sout_futur)
  for (j in seq_along(sout_futur)) {
    delta <- -(params$perte_kwh_par_qt + sout_futur[j]) / params$capacite_kwh_par_degre
    t_simul <- t_simul + delta
    if (t_simul < params$t_min) { qt_avant_t_min <- j; break }
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

    # Prix negatif a l'injection : toujours autoconsommer
    if (prix_injection_now < 0 & surplus_now > 0 & t_actuelle < params$t_max)
      return(list(pac_on = 1L, raison = "smart_eviter_inj_neg"))

    # Le ballon va-t-il avoir besoin de chaleur ?
    needs_heat <- t_actuelle < params$t_consigne | qt_avant_t_min <= params$horizon_qt

    if (!needs_heat) {
      # Ballon OK et pas de besoin proche : ne pas chauffer
      return(list(pac_on = 0L, raison = "smart_ballon_ok"))
    }

    # Le ballon a besoin de chaleur. Question : maintenant ou plus tard ?

    # Cas 1 : Surplus PV total — chauffer est quasi-gratuit
    if (surplus_now >= pac_conso_qt) {
      # Cout = perte d'injection. Toujours moins cher que soutirer plus tard
      # sauf si prix_injection > prix_offtake futur (rare)
      if (cout_par_kwh_th_now < cout_moyen_futur * 1.5) {
        return(list(pac_on = 1L, raison = "smart_surplus_gratuit"))
      }
      # Cas rare : mieux vaut injecter maintenant et soutirer pas cher plus tard
      return(list(pac_on = 0L, raison = "smart_injection_rentable"))
    }

    # Cas 2 : Pas de surplus total — chauffer coute du soutirage
    # Ne chauffer sur reseau que si le prix actuel est significativement
    # moins cher que le futur (contrat dynamique uniquement)
    if (cout_par_kwh_th_now < cout_moyen_futur * 0.7) {
      # Prix actuellement bas par rapport a la moyenne future
      if (t_actuelle < params$t_consigne)
        return(list(pac_on = 1L, raison = "smart_prix_favorable"))
    }

    # Cas 3 : Urgence — le ballon va tomber sous t_min
    if (qt_avant_t_min <= 2)
      return(list(pac_on = 1L, raison = "smart_urgence"))

    # Cas 4 : Attendre du surplus PV futur si le ballon tient
    h_avant <- which(surplus_futur >= pac_conso_qt)
    if (length(h_avant) > 0 & qt_avant_t_min > min(h_avant))
      return(list(pac_on = 0L, raison = "smart_attente_surplus"))

    # Cas 5 : Pas de surplus a venir, confort menace bientot
    if (qt_avant_t_min <= 4 & t_actuelle < params$t_min + 2)
      return(list(pac_on = 1L, raison = "smart_anticipation"))

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
  
  sim_t[1] <- df$t_ballon[1]; sim_on[1] <- 0L
  
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
  
  for (i in 2:n) {
    t_act <- sim_t[i - 1]
    cop_n <- calc_cop(df$t_ext[i], params$cop_nominal, params$t_ref_cop)
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
    apport <- d$pac_on * ch_pac
    dt <- (apport - params$perte_kwh_par_qt - df$soutirage_estime_kwh[i]) / params$capacite_kwh_par_degre
    sim_t[i] <- max(params$t_min - 2, min(params$t_max + 2, t_act + dt))
    
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

generer_demo <- function(jours = 365) {
  # ---------------------------------------------------------------
  # Genere un scenario realiste de maison avec PAC non-optimisee
  # (thermostat classique : allume quand T < seuil_bas, eteint quand T > seuil_haut)
  # La PAC ne regarde PAS la production PV → beaucoup d'injection evitable
  # ---------------------------------------------------------------
  n <- jours * 96
  # Seed fixe pour reproductibilite
  set.seed(42)
  # Demarre en fevrier 2025 pour couvrir les prix Belpex disponibles
  ts <- seq(as.POSIXct("2025-02-01 00:00:00", tz = "Europe/Brussels"), by = "15 min", length.out = n)
  h <- hour(ts) + minute(ts) / 60
  doy <- yday(ts)

  # --- Production PV (6 kWc, profil realiste) ---
  env <- 0.5 + 0.5 * sin(2 * pi * (doy - 80) / 365)  # enveloppe saisonniere
  couverture <- 0.6 + 0.4 * runif(n)                    # nebulosite aleatoire
  pv_kw <- 6 * 0.8 * pmax(0, sin(pi * (h - 6) / 14)) * env * couverture

  # --- Temperature exterieure (realiste Belgique) ---
  t_ext <- 10 + 10 * sin(2 * pi * (doy - 80) / 365) +   # saisonnalite
            4 * sin(pi * (h - 6) / 18) +                   # cycle jour/nuit
            rnorm(n, 0, 2)                                  # bruit

  # --- Consommation de base (hors PAC) ---
  # Profil residentiel : pic matin (7-9h) et soir (17-21h)
  conso_base_kw <- 0.3 +
    0.2 * exp(-0.5 * ((h - 8) / 1.5)^2) +    # pic matin
    0.35 * exp(-0.5 * ((h - 19) / 2)^2) +     # pic soir
    runif(n, 0, 0.1)                            # bruit

  # --- Soutirage ECS (eau chaude sanitaire) ---
  # Menage type : ~150L/jour a 45C = ~6-8 kWh/jour de tirage
  # Reparti : douche matin (gros tirage), vaisselle midi, douche/bain soir
  ecs_kwh <- numeric(n)
  for (i in seq_len(n)) {
    if (h[i] > 6.5 & h[i] < 8.5) {
      if (runif(1) < 0.6) ecs_kwh[i] <- runif(1, 1.0, 3.0)  # douche matin
    } else if (h[i] > 12 & h[i] < 13.5) {
      if (runif(1) < 0.3) ecs_kwh[i] <- runif(1, 0.3, 1.0)  # vaisselle midi
    } else if (h[i] > 18.5 & h[i] < 21) {
      if (runif(1) < 0.6) ecs_kwh[i] <- runif(1, 1.5, 4.0)  # douche/bain soir
    } else if (h[i] > 8 & h[i] < 22) {
      if (runif(1) < 0.05) ecs_kwh[i] <- runif(1, 0.2, 0.5)  # petit tirage ponctuel
    }
  }

  # --- PAC pilotee par thermostat classique (NON-OPTIMISEE) ---
  # Regle simple : ON quand T < consigne - 2C, OFF quand T > consigne + 2C
  # Plage etroite (4C) = thermostat classique typique
  # Ne regarde JAMAIS la production PV
  p_pac_kw <- 2.0
  pac_conso_qt <- p_pac_kw * 0.25  # kWh par quart d'heure
  t_consigne_bas <- 50 - 2  # consigne - hysteresis
  t_consigne_haut <- 50 + 2  # consigne + hysteresis
  volume_l <- 200
  cap_kwh_deg <- volume_l * 0.001163

  t_ballon <- rep(NA_real_, n)
  pac_on <- rep(0L, n)
  t_ballon[1] <- 50

  for (i in 2:n) {
    t_prev <- t_ballon[i - 1]
    cop <- calc_cop(t_ext[i])

    # Thermostat classique avec hysteresis
    if (t_prev < t_consigne_bas) {
      pac_on[i] <- 1L
    } else if (t_prev > t_consigne_haut) {
      pac_on[i] <- 0L
    } else {
      pac_on[i] <- pac_on[i - 1]  # maintient l'etat precedent
    }

    # Pertes thermiques (proportionnelles a T_ballon - T_ambiante)
    # Ballon 200L typique : ~2-3 kWh/jour de pertes statiques = ~0.03 kWh/qt a delta_T=30
    t_ambiante <- 20
    perte_kwh <- 0.004 * (t_prev - t_ambiante) * 0.25

    # Bilan thermique
    apport <- pac_on[i] * pac_conso_qt * cop
    delta_t <- (apport - perte_kwh - ecs_kwh[i]) / cap_kwh_deg
    t_ballon[i] <- t_prev + delta_t
    t_ballon[i] <- max(20, min(70, t_ballon[i]))  # bornes physiques
  }

  # --- Bilan electrique (grid meter) ---
  conso_totale_kwh <- conso_base_kw * 0.25 + pac_on * pac_conso_qt
  pv_kwh <- pv_kw * 0.25
  surplus <- pv_kwh - conso_totale_kwh
  offtake <- pmax(0, -surplus)   # ce qu'on prend au reseau
  intake  <- pmax(0, surplus)    # ce qu'on injecte

  # --- Prix (placeholder, sera ecrase par Belpex) ---
  bp <- 0.05 + 0.03 * sin(2 * pi * (doy - 30) / 365)
  prix <- bp + 0.04 * sin(pi * (h - 8) / 12) + rnorm(n, 0, 0.015)
  prix <- ifelse(doy > 120 & doy < 250 & h > 11 & h < 15 & runif(n) < 0.15,
                 -abs(rnorm(n, 0.02, 0.01)), prix)

  tibble(
    timestamp = ts,
    pv_kwh = round(pv_kwh, 4),
    offtake_kwh = round(offtake, 4),
    intake_kwh = round(intake, 4),
    t_ballon = round(t_ballon, 1),
    t_ext = round(t_ext, 1),
    prix_eur_kwh = round(prix, 4),
    conso_base_kwh = round(conso_base_kw * 0.25, 4),
    soutirage_ecs_kwh = round(ecs_kwh, 4)
  )
}

prepare_df <- function(df, params) {
  pq <- params$p_pac_kw * params$dt_h
  
  # Rescaler la production PV selon le dimensionnement choisi
  ratio_pv <- params$pv_kwc / params$pv_kwc_ref
  # Si conso_base_kwh est fournie (mode demo), l'utiliser directement
  # Sinon, estimer par desagregation du grid meter
  has_conso_base <- "conso_base_kwh" %in% names(df)

  df <- df %>% mutate(
    pv_kwh_original = pv_kwh,
    pv_kwh = pv_kwh * ratio_pv,
    cop_reel = calc_cop(t_ext, params$cop_nominal, params$t_ref_cop),
    delta_t_mesure = t_ballon - lag(t_ballon)
  )

  if (has_conso_base) {
    df <- df %>% mutate(
      pac_on_reel = as.integer((offtake_kwh + intake_kwh + conso_base_kwh) > (pv_kwh + conso_base_kwh + 0.01)),
      conso_hors_pac = conso_base_kwh
    )
  } else {
    df <- df %>% mutate(
      pac_on_reel = as.integer(offtake_kwh > pq * 0.5),
      conso_hors_pac = pmax(0, offtake_kwh - pac_on_reel * pq)
    )
  }
  
  # Appliquer les prix selon le type de contrat
  if (params$type_contrat == "fixe") {
    # Contrat fixe : prix constants, indépendants du spot
    df <- df %>% mutate(
      prix_offtake   = params$prix_fixe_offtake,
      prix_injection = params$prix_fixe_injection
    )
  } else {
    # Contrat dynamique : suit le spot
    df <- df %>% mutate(
      prix_offtake   = prix_eur_kwh + params$taxe_transport_eur_kwh,
      prix_injection = prix_eur_kwh * params$coeff_injection
    )
    # Protection contre les prix négatifs à l'injection si activée
    if (params$protege_negatif) {
      df <- df %>% mutate(prix_injection = pmax(0, prix_injection))
    }
  }
  
  if ("soutirage_ecs_kwh" %in% names(df)) {
    # Mode demo : on connait les pertes exactes du modele thermique
    # Perte = 0.004 * (T_moyen - 20) * 0.25 ≈ 0.03 kWh/qt pour T=50
    t_moy <- mean(df$t_ballon, na.rm = TRUE)
    params$perte_kwh_par_qt <- 0.004 * (t_moy - 20) * 0.25
  } else {
    # Mode CSV : calibrer les pertes sur les periodes PAC OFF sans ECS
    pm <- df %>% filter(offtake_kwh < 0.05, delta_t_mesure < 0) %>%
      summarise(p = median(delta_t_mesure, na.rm = TRUE)) %>% pull(p)
    if (is.na(pm) || pm >= 0) pm <- -0.2
    params$perte_kwh_par_qt <- abs(pm) * params$capacite_kwh_par_degre
  }

  df_out <- if ("soutirage_ecs_kwh" %in% names(df)) {
    df %>% mutate(soutirage_estime_kwh = soutirage_ecs_kwh)
  } else {
    df %>% mutate(soutirage_estime_kwh = case_when(
      offtake_kwh < 0.05 & delta_t_mesure < pm ~
        (abs(delta_t_mesure) - abs(pm)) * params$capacite_kwh_par_degre,
      TRUE ~ 0))
  }

  # Retourner df ET params mis a jour (perte_kwh_par_qt calibree)
  list(df = df_out, params = params)
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
    legend = list(orientation = "h", y = -0.15, font = list(size = 10)),
    margin = list(t = 50, b = 60, l = 60, r = 20),
    hoverlabel = list(font = list(family = "JetBrains Mono", size = 11)))
}

# =============================================================================
# HELPERS PEDAGOGIQUES
# =============================================================================

# Infobulle inline : petit cercle "i" avec tooltip HTML natif
tip <- function(text) {
  tags$span(class = "info-tip", title = text, "i")
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
    .sidebar-section{margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid %s}
    .section-title{font-family:'JetBrains Mono',monospace;font-size:.7rem;text-transform:uppercase;letter-spacing:.15em;color:%s;margin-bottom:8px}
    .form-label{font-size:.78rem;color:%s}
    .form-control,.form-select{font-size:.82rem;background:%s!important;border-color:%s!important}
    .btn-primary{background:%s;border:none;font-family:'JetBrains Mono',monospace;font-size:.82rem;letter-spacing:.05em}
    .btn-primary:hover{background:%s;filter:brightness(1.15)}
    #status_bar{font-family:'JetBrains Mono',monospace;font-size:.75rem;color:%s;padding:8px 16px;background:%s;border-radius:8px;margin-bottom:12px}
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
     cl$text_muted,cl$grid,cl$accent,cl$text_muted,cl$bg_input,cl$grid,cl$accent,cl$accent,
     cl$text_muted,cl$bg_card,
     cl$bg_card,cl$accent3,cl$bg_dark,cl$bg_input,cl$grid,cl$text_muted,cl$accent,cl$accent,cl$bg_input,cl$opti)))),
  
  layout_sidebar(fillable = TRUE,
    sidebar = sidebar(width = 300, bg = cl$bg_card,
      tags$div(style = "padding:8px 0 16px 0;text-align:center;",
        tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:1.1rem;font-weight:700;color:%s;letter-spacing:.1em", cl$accent), HTML("&#9889; PAC OPTIMIZER")),
        tags$div(style = sprintf("font-size:.65rem;color:%s;margin-top:2px;letter-spacing:.15em;text-transform:uppercase", cl$text_muted), "Pilotage predictif")),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Source de donnees", tip("Demo : donnees synthetiques (PV, conso, temperature) + vrais prix Belpex. CSV : vos propres donnees completes.")),
        radioButtons("data_source", NULL, choices = c("Demo" = "demo", "CSV" = "csv"), selected = "demo", inline = TRUE),
        conditionalPanel("input.data_source=='csv'", fileInput("csv_file", NULL, accept = ".csv", buttonLabel = "Parcourir", placeholder = "data.csv")),
        conditionalPanel("input.data_source=='demo'", sliderInput("demo_jours", "Jours", 30, 365, 180, step = 30)),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          HTML("Prix Belpex reels (ENTSO-E) utilises automatiquement.<br>Source : CSV locaux (2024-2025) + API si besoin."))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Optimisation", tip("Deux approches : Rule-based (regles heuristiques, rapide) ou Optimiseur (MILP, trouve la solution mathematiquement optimale).")),
        radioButtons("approche", "Approche", choices = c("Rule-based" = "rulebased", "Optimiseur" = "optimiseur"), selected = "rulebased", inline = TRUE),
        conditionalPanel("input.approche=='rulebased'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Mode <b>Smart</b> : decision basee sur la valeur nette a chaque quart d'heure. Compare le cout de chauffer maintenant vs plus tard en tenant compte du surplus PV, des prix spot et du COP."))),
        conditionalPanel("input.approche=='optimiseur'",
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
            HTML("Resout un probleme d'optimisation mathematique (MILP) qui minimise le cout net en respectant toutes les contraintes physiques. Trouve la <b>solution optimale globale</b> sur tout l'horizon, jour par jour.")))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Pompe a chaleur", tip("Caracteristiques electriques de votre PAC. Le COP varie avec la temperature exterieure ; la valeur nominale est celle a 7C.")),
        numericInput("p_pac_kw", "Puissance (kW)", 2, min = 0.5, max = 10, step = 0.5),
        numericInput("cop_nominal", "COP nominal", 3.5, min = 1.5, max = 6, step = 0.1),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "COP = Coefficient de Performance. Un COP de 3.5 signifie que 1 kWh electrique produit 3.5 kWh de chaleur.")),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Ballon thermique", tip("Le ballon sert de batterie thermique. Plus il est gros, plus on peut stocker de chaleur pour decaler la consommation.")),
        numericInput("volume_ballon", "Volume (L)", 200, min = 50, max = 1000, step = 50),
        numericInput("t_consigne", "Consigne (C)", 50, min = 35, max = 65, step = 1),
        sliderInput("t_tolerance", "Tolerance +/-C", 1, 10, 5, step = 1),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Plage autorisee = consigne +/- tolerance. L'algo ne laissera jamais la temperature sortir de cette plage.")),
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
          checkboxInput("protege_negatif", "Protection prix negatifs injection", FALSE),
          tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Soutirage = spot + taxes. Injection = spot x coeff. Les prix negatifs signifient que vous PAYEZ pour injecter (surplus renouvelable sur le reseau)."))),
      tags$div(class = "sidebar-section",
        tags$div(class = "section-title", "Dimensionnement PV", tip("Simulez l'impact d'une installation PV plus grande ou plus petite. Les donnees sont mises a l'echelle proportionnellement.")),
        sliderInput("pv_kwc", "Puissance crete (kWc)", 1, 20, 6, step = 0.5),
        numericInput("pv_kwc_ref", "kWc reference (donnees)", 6, min = 1, max = 20, step = 0.5),
        tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          "kWc ref = taille reelle de l'installation dans vos donnees. Le ratio kWc/ref rescale la production PV. Ex: 9 kWc / 6 kWc ref = x1.5")),
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
    uiOutput("kpi_row"),
    
    navset_card_tab(id = "main_tabs",
      nav_panel(title = "Vue d'ensemble", icon = icon("chart-line"),
        explainer(
          tags$summary("Comprendre cette vue"),
          tags$p("Cette vue compare le fonctionnement ", tags$strong("reel"), " de votre installation (courbes orange) avec le fonctionnement ", tags$strong("optimise"), " par l'algorithme (courbes cyan)."),
          tags$ul(
            tags$li(tags$strong("Production PV vs injection :"), " la courbe jaune montre votre production solaire quotidienne. L'ecart entre l'injection reelle (pointilles) et optimisee (trait plein) represente l'energie que l'algo aurait permis d'autoconsommer."),
            tags$li(tags$strong("Temperature ballon :"), " montre comment l'algo utilise le ballon comme batterie thermique — il chauffe quand le PV est disponible et laisse descendre quand il ne l'est pas, tout en respectant les limites."),
            tags$li(tags$strong("COP journalier :"), " le Coefficient de Performance varie avec la temperature exterieure. En ete (COP ~4-5), chaque kWh electrique produit plus de chaleur qu'en hiver (COP ~2-3).")
          )),
        layout_columns(col_widths = 12, card(full_screen = TRUE, card_header("Production PV vs injection"), card_body(plotlyOutput("plot_overview", height = "320px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Temperature ballon"), card_body(plotlyOutput("plot_temperature", height = "280px"))),
          card(full_screen = TRUE, card_header("COP journalier"), card_body(plotlyOutput("plot_cop", height = "280px")))),
        conditionalPanel("input.batterie_active",
          layout_columns(col_widths = 12,
            card(full_screen = TRUE, card_header("Batterie — Etat de charge (SoC)"), card_body(plotlyOutput("plot_batterie", height = "250px")))))),
      nav_panel(title = "Analyse", icon = icon("magnifying-glass"),
        explainer(
          tags$summary("Comprendre cette analyse"),
          tags$p("Cet onglet decompose le ", tags$strong("comportement de l'algorithme"), " pour comprendre ses decisions."),
          tags$ul(
            tags$li(tags$strong("Profil journalier :"), " moyenne sur mai-aout (periode de forte production PV). Permet de voir si la PAC tourne bien pendant les heures d'ensoleillement plutot que le soir."),
            tags$li(tags$strong("Repartition des decisions :"), " pourquoi l'algo allume ou eteint la PAC a chaque quart d'heure. 'Surplus PV' = le soleil produit plus que la maison ne consomme. 'Attente meilleur' = l'algo anticipe un meilleur moment."),
            tags$li(tags$strong("Prix spot et PAC ON :"), " les points cyan montrent a quel prix l'algo fait tourner la PAC. Idealement, la PAC tourne quand le prix est bas (beaucoup de renouvelable sur le reseau).")
          )),
        layout_columns(col_widths = 12, card(full_screen = TRUE, card_header("Profil journalier moyen (mai-aout)"), card_body(plotlyOutput("plot_profil", height = "320px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Repartition des decisions"), card_body(plotlyOutput("plot_decisions", height = "300px"))),
          card(full_screen = TRUE, card_header("Prix spot et PAC ON"), card_body(plotlyOutput("plot_prix_pac", height = "300px"))))),
      nav_panel(title = "Comparaison", icon = icon("code-compare"),
        explainer(
          tags$summary("Comprendre la comparaison"),
          tags$p("Compare le scenario ", tags$strong("reel"), " (ce qui s'est passe) avec le scenario ", tags$strong("optimise"), " (ce que l'algo aurait fait)."),
          tags$ul(
            tags$li(tags$strong("Bilan quotidien :"), " les barres cyan representent l'injection evitee chaque jour. Plus la barre est haute, plus l'algo a ete efficace ce jour-la.")
          )),
        layout_columns(col_widths = 12, card(full_screen = TRUE, card_header("Bilan quotidien"), card_body(plotlyOutput("plot_injection_compare", height = "320px"))))),
      nav_panel(title = "Insights", icon = icon("lightbulb"),
        explainer(
          tags$summary("Comprendre ces visualisations"),
          tags$ul(
            tags$li(tags$strong("Heatmap :"), " chaque cellule = 1 heure d'une journee. La couleur montre l'intensite de la variable choisie. Permet de reperer les patterns saisonniers et journaliers."),
            tags$li(tags$strong("Load shifting :"), " superpose le profil moyen reel et optimise. Montre comment la PAC est decalee des heures sans PV vers les heures avec PV."),
            tags$li(tags$strong("Waterfall :"), " decompose le gain financier : soutirage evite, injection perdue, et gain de timing (contrat dynamique).")
          )),
        layout_columns(col_widths = 12,
          card(full_screen = TRUE, card_header("Heatmap — pattern journalier x saisonnier"),
            card_body(
              layout_columns(col_widths = c(4, 8),
                selectInput("heatmap_var", NULL, choices = c(
                  "Injection evitee" = "inj_evitee", "Surplus PV" = "surplus",
                  "PAC ON (optimise)" = "pac_on", "Temperature ballon" = "t_ballon",
                  "Prix spot" = "prix"), selected = "inj_evitee"),
                tags$div()),
              plotlyOutput("plot_heatmap", height = "380px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Load shifting — profil journalier moyen"),
            card_body(plotlyOutput("plot_loadshift", height = "320px"))),
          card(full_screen = TRUE, card_header("Waterfall — decomposition des economies"),
            card_body(plotlyOutput("plot_waterfall", height = "320px"))))),
      nav_panel(title = "Bilan EUR", icon = icon("euro-sign"),
        explainer(
          tags$summary("Comprendre le bilan financier"),
          tags$p("Traduction en ", tags$strong("euros"), " des gains energetiques."),
          tags$ul(
            tags$li(tags$strong("Economies mensuelles :"), " difference entre ce que vous auriez paye sans optimisation et avec. Les barres vertes = economies, rouges = l'algo a fait pire (rare, en general les premiers jours avant calibration)."),
            tags$li(tags$strong("Bilan mensuel :"), " detail mois par mois. La colonne 'Gain' est l'economie nette en euros."),
            tags$li(tags$strong("Repartition des couts :"), " combien vous payez en soutirage vs combien vous recevez en injection. En contrat dynamique, l'objectif est de maximiser l'autoconsommation pour reduire le soutirage aux heures cheres.")
          ),
          tags$p(tags$strong("Note :"), " en contrat fixe, le gain vient uniquement de la reduction du volume soutire/injecte. En contrat dynamique, le gain vient aussi du ", tags$strong("timing"), " (soutirer quand c'est moins cher).")),
        layout_columns(col_widths = 12, card(full_screen = TRUE, card_header("Economies mensuelles"), card_body(plotlyOutput("plot_gains", height = "320px")))),
        layout_columns(col_widths = c(6, 6),
          card(full_screen = TRUE, card_header("Bilan mensuel"), card_body(DTOutput("table_mensuel"))),
          card(full_screen = TRUE, card_header("Repartition des couts"), card_body(plotlyOutput("plot_cout_repartition", height = "300px"))))),
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
      nav_panel(title = "Explorer", icon = icon("calendar-days"),
        explainer(
          tags$summary("Comment utiliser l'explorateur"),
          tags$p("Selectionnez une ", tags$strong("periode"), " et une ", tags$strong("variable"), " pour zoomer sur n'importe quelle portion des donnees."),
          tags$ul(
            tags$li(tags$strong("Injection / Soutirage :"), " compare les flux reseau reels vs optimises sur la periode choisie."),
            tags$li(tags$strong("Temperature :"), " verifie que le ballon reste dans les limites (lignes pointillees). Utile pour ajuster la tolerance."),
            tags$li(tags$strong("PV + PAC :"), " superpose la production solaire et les moments ou la PAC tourne (points verts)."),
            tags$li(tags$strong("Prix spot :"), " visualise la correlation entre les prix du marche et les decisions de l'algo. La ligne rouge en pointilles marque le zero (prix negatifs en dessous).")
          ),
          tags$p("Astuce : utilisez le zoom Plotly (cliquer-glisser) pour analyser des journees individuelles.")),
        card(full_screen = TRUE, card_header("Zoom sur une periode"), card_body(
          layout_columns(col_widths = c(4, 4, 4),
            dateRangeInput("date_range", "Periode", start = Sys.Date() - 30, end = Sys.Date(), language = "fr"),
            selectInput("zoom_var", "Variable", choices = c("Injection" = "intake", "Soutirage" = "offtake", "Temperature" = "temp", "PV + PAC" = "pv_pac", "Prix spot" = "prix")),
            tags$div()),
          plotlyOutput("plot_zoom", height = "400px"))))),
    ) # fin navset_card_tab
  ) # fin layout_sidebar + page_fillable

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
                tags$tr(tags$td(style = "padding:4px 6px;", "Cout optimal"), tags$td(style = sprintf("color:%s;padding:4px 6px;", cl$success), "ON"), tags$td(style = "padding:4px 6px;", "Parmi les 30% moins chers.")),
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
"PV \u2192 Maison \u2192 PAC \u2192 Batterie \u2192 Injection
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
              tags$h6(style = sprintf("color:%s;margin:0 0 6px 0;", cl$reel), "Rule-based (regles heuristiques)"),
              tags$p(style = "margin:0;", "A chaque quart d'heure, l'algo applique des regles : 'si surplus PV ET ballon froid ALORS allumer'. Decisions locales, pas de vision d'ensemble."),
              tags$p(style = sprintf("margin:4px 0 0 0;font-size:.78rem;color:%s;", cl$text_muted), "Comme un joueur d'echecs qui decide coup par coup.")),
            tags$div(style = sprintf("background:%s;border:1px solid %s;border-radius:8px;padding:12px;margin:8px 0;", cl$bg_input, cl$grid),
              tags$h6(style = sprintf("color:%s;margin:0 0 6px 0;", cl$success), "Optimiseur (MILP)"),
              tags$p(style = "margin:0;", "On declare l'objectif (minimiser la facture) et les contraintes (temperature, batterie, puissance). Le solveur trouve la solution mathematiquement optimale sur toute la journee simultanement."),
              tags$p(style = sprintf("margin:4px 0 0 0;font-size:.78rem;color:%s;", cl$text_muted), "Comme un joueur qui calcule 10 coups d'avance.")),
            tags$p(tags$strong("Exemple concret :"), " si les prix sont bas a 10h et tres eleves a 18h, l'optimiseur sait qu'il faut charger la batterie a 10h pour revendre a 18h. Le rule-based ne voit que l'heure en cours et peut rater cette opportunite."),
            tags$p(tags$strong("Quand utiliser quoi ?"), " Le rule-based est plus rapide et suffisant pour des profils de prix simples (contrat fixe). L'optimiseur brille en contrat dynamique avec des prix volatils et une batterie.")
          ),

          accordion_panel("11. Glossaire", icon = icon("spell-check"),
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

  params_r <- reactive({
    list(t_consigne = input$t_consigne, t_tolerance = input$t_tolerance,
      t_min = input$t_consigne - input$t_tolerance, t_max = input$t_consigne + input$t_tolerance,
      p_pac_kw = input$p_pac_kw, cop_nominal = input$cop_nominal, t_ref_cop = 7,
      volume_ballon_l = input$volume_ballon,
      capacite_kwh_par_degre = input$volume_ballon * 0.001163,
      horizon_qt = 16, seuil_surplus_pct = 0.3, dt_h = 0.25,
      type_contrat = input$type_contrat,
      taxe_transport_eur_kwh = ifelse(input$type_contrat == "dynamique", input$taxe_transport, 0),
      coeff_injection = ifelse(input$type_contrat == "dynamique", input$coeff_injection, 1),
      protege_negatif = ifelse(input$type_contrat == "dynamique", input$protege_negatif, TRUE),
      prix_fixe_offtake = ifelse(input$type_contrat == "fixe", input$prix_fixe_offtake, 0.30),
      prix_fixe_injection = ifelse(input$type_contrat == "fixe", input$prix_fixe_injection, 0.03),
      perte_kwh_par_qt = 0.05,
      pv_kwc = input$pv_kwc, pv_kwc_ref = input$pv_kwc_ref,
      batterie_active = input$batterie_active,
      batt_kwh = input$batt_kwh, batt_kw = input$batt_kw,
      batt_rendement = input$batt_rendement / 100,
      batt_soc_min = input$batt_soc_range[1] / 100,
      batt_soc_max = input$batt_soc_range[2] / 100,
      poids_cout = 0.5)
  })
  
  raw_data <- reactive({
    if (input$data_source == "csv") {
      req(input$csv_file)
      df <- read_csv(input$csv_file$datapath, show_col_types = FALSE) %>% mutate(timestamp = ymd_hms(timestamp))
    } else {
      df <- generer_demo(input$demo_jours)
    }

    # Toujours injecter les vrais prix Belpex
    api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
    belpex <- load_belpex_prices(
      start_date = min(df$timestamp),
      end_date = max(df$timestamp),
      api_key = api_key,
      data_dir = "data"
    )
    if (!is.null(belpex$data) && nrow(belpex$data) > 0) {
      # Convertir en Brussels et creer une cle horaire pour la jointure
      belpex_h <- belpex$data %>%
        mutate(
          datetime_bxl = with_tz(datetime, tzone = "Europe/Brussels"),
          heure_join = floor_date(datetime_bxl, unit = "hour"),
          prix_belpex = price_eur_mwh / 1000  # EUR/MWh -> EUR/kWh
        ) %>%
        distinct(heure_join, .keep_all = TRUE) %>%
        select(heure_join, prix_belpex)

      # Joindre par heure arrondie (chaque qt d'heure prend le prix de son heure)
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
    df
  })
  
  sim_result <- eventReactive(input$run_sim, {
    p <- params_r(); df <- raw_data()
    approche <- input$approche

    withProgress(message = "Preparation...", value = 0.1, {
      prep <- prepare_df(df, p)
      df_prep <- prep$df; p <- prep$params

      if (approche == "optimiseur") {
        setProgress(0.3, detail = "Optimisation MILP en cours...")
        sim <- tryCatch({
          run_optimization_milp(df_prep, p)
        }, error = function(e) {
          showNotification(paste("Erreur optimiseur:", e$message), type = "error", duration = 10)
          NULL
        })
        if (is.null(sim)) {
          showNotification("Optimisation infaisable — verifiez les contraintes (tolerance temperature, etc.)", type = "error")
          # Fallback : mode smart
          sim <- run_simulation(df_prep, p, "smart", 0.5)
          sim$mode_actif <- "smart_fallback"
        }
        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "optimizer")
      } else {
        setProgress(0.3, detail = "Simulation en cours...")
        sim <- run_simulation(df_prep, p, "smart", 0.5)
        sim$mode_actif <- "smart"
        setProgress(1, detail = "Termine!")
        list(sim = sim, candidats = NULL, modes = NULL, df = df_prep, params = p, mode = "smart")
      }
    })
  })
  
  observeEvent(sim_result(), {
    sim <- sim_result()$sim
    # Debug log
    cr <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm=TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm=TRUE)
    co <- sum(sim$sim_offtake * sim$prix_offtake, na.rm=TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm=TRUE)
    message(sprintf("[DEBUG] Offtake reel=%d opti=%d | Injection reel=%d opti=%d | Cout reel=%.1f opti=%.1f | GAIN=%.1f EUR",
      round(sum(sim$offtake_kwh,na.rm=TRUE)), round(sum(sim$sim_offtake,na.rm=TRUE)),
      round(sum(sim$intake_kwh,na.rm=TRUE)), round(sum(sim$sim_intake,na.rm=TRUE)),
      cr, co, cr-co))
    updateDateRangeInput(session, "date_range", start = as.Date(min(sim$timestamp)), end = as.Date(max(sim$timestamp)))
  })
  
  output$status_bar <- renderUI({
    req(sim_result()); res <- sim_result(); sim <- res$sim; n <- nrow(sim)
    p <- if (!is.null(res$params)) res$params else params_r()
    jours <- as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days"))
    ml <- c(smart = "SMART", optimizer = "OPTIM")
    batt <- if (p$batterie_active) paste0(p$batt_kwh, "kWh/", p$batt_kw, "kW") else "non"
    contrat <- if (p$type_contrat == "fixe") paste0("fixe ", p$prix_fixe_offtake, "/", p$prix_fixe_injection) else "spot"
    tags$div(id = "status_bar", HTML(sprintf(
      "PV <b>%s kWc</b> &middot; PAC <b>%s kW</b> COP %s &middot; Ballon <b>%s L</b> %s&plusmn;%s&deg;C &middot; Batt <b>%s</b> &middot; Mode <b>%s</b> &middot; Contrat <b>%s</b> &middot; %d j &middot; %s pts",
      p$pv_kwc, p$p_pac_kw, p$cop_nominal, p$volume_ballon_l, p$t_consigne, p$t_tolerance,
      batt, ml[res$mode], contrat, round(jours), formatC(n, format = "d", big.mark = " ")
    )))
  })

  output$kpi_row <- renderUI({
    req(sim_result()); sim <- sim_result()$sim
    pv_tot <- sum(sim$pv_kwh, na.rm = TRUE)
    inj_r <- sum(sim$intake_kwh, na.rm = TRUE); inj_o <- sum(sim$sim_intake, na.rm = TRUE)
    offt_r <- sum(sim$offtake_kwh, na.rm = TRUE); offt_o <- sum(sim$sim_offtake, na.rm = TRUE)
    ac <- round((1 - inj_o / max(pv_tot, 1)) * 100, 1)
    cr <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    co <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
    gain <- cr - co
    kpi <- function(v, l, u, c) tags$div(class = "text-center",
      tags$div(class = "kpi-value", style = sprintf("color:%s;", c), v, tags$span(class = "kpi-unit", u)),
      tags$div(class = "kpi-label", l))
    
    kpis <- list(
      kpi(formatC(round(pv_tot), big.mark = " ", format = "d"), "Production PV", "kWh", cl$pv),
      kpi(paste0(ac, "%"), "Autoconsommation", "", cl$success),
      kpi(formatC(round(inj_r - inj_o), big.mark = " ", format = "d"), "Injection evitee", "kWh", cl$opti),
      kpi(formatC(round(offt_r - offt_o), big.mark = " ", format = "d"), "Soutirage evite", "kWh", cl$accent3),
      kpi(paste0("+", round(gain)), "Economie", "EUR", cl$success),
      kpi(round(sum(sim$sim_pac_on, na.rm = TRUE) * 0.25), "Heures PAC", "h", cl$pac)
    )
    
    # Ajouter KPI batterie si active
    p <- params_r()
    if (p$batterie_active && !is.null(sim$batt_flux)) {
      charge_tot <- sum(pmax(0, sim$batt_flux), na.rm = TRUE)
      cycles <- round(charge_tot / max(p$batt_kwh, 1), 1)
      kpis <- c(kpis, list(kpi(cycles, "Cycles batterie", "/an", "#818cf8")))
    }
    
    ncols <- length(kpis)
    cw <- rep(floor(12 / ncols), ncols)
    cw[1] <- 12 - sum(cw[-1])
    do.call(layout_columns, c(list(col_widths = cw, style = "margin-bottom:12px;"), kpis))
  })
  
  output$plot_overview <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    d <- sim %>% mutate(jour = as.Date(timestamp)) %>% group_by(jour) %>%
      summarise(pv = sum(pv_kwh, na.rm = TRUE), ir = sum(intake_kwh, na.rm = TRUE), io = sum(sim_intake, na.rm = TRUE), .groups = "drop")
    plot_ly(d, x = ~jour) %>%
      add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV", line = list(color = cl$pv, width = 1), fill = "tozeroy", fillcolor = "rgba(251,191,36,0.1)") %>%
      add_trace(y = ~ir, type = "scatter", mode = "lines", name = "Injection reelle", line = list(color = cl$reel, width = 1.5, dash = "dot")) %>%
      add_trace(y = ~io, type = "scatter", mode = "lines", name = "Injection optimisee", line = list(color = cl$opti, width = 1.5)) %>% pl_layout(ylab = "kWh/jour")
  })
  
  output$plot_temperature <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim; p <- params_r()
    s <- sim %>% filter(month(timestamp) == 7) %>% slice(1:(7*96))
    if (nrow(s) < 96) s <- tail(sim, 7*96)
    plot_ly(s, x = ~timestamp) %>%
      add_trace(y = ~t_ballon, type = "scatter", mode = "lines", name = "Reel", line = list(color = cl$reel, width = 1)) %>%
      add_trace(y = ~sim_t_ballon, type = "scatter", mode = "lines", name = "Optimise", line = list(color = cl$opti, width = 1.5)) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_min, yend = p$t_min, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_max, yend = p$t_max, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      pl_layout(ylab = "C")
  })
  
  output$plot_cop <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    d <- sim %>% filter(!is.na(sim_cop)) %>% mutate(jour = as.Date(timestamp)) %>% group_by(jour) %>% summarise(cop = mean(sim_cop, na.rm = TRUE), .groups = "drop")
    plot_ly(d, x = ~jour, y = ~cop, type = "scatter", mode = "lines", line = list(color = cl$pac, width = 1.5), fill = "tozeroy", fillcolor = "rgba(52,211,153,0.08)") %>% pl_layout(ylab = "COP")
  })
  
  output$plot_profil <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim; p <- params_r()
    pr <- sim %>% filter(month(timestamp) %in% 5:8) %>% mutate(h = hour(timestamp) + minute(timestamp)/60) %>%
      group_by(h) %>% summarise(pv = mean(pv_kwh, na.rm = TRUE), pac = mean(sim_pac_on * p$p_pac_kw * p$dt_h, na.rm = TRUE),
        ir = mean(intake_kwh, na.rm = TRUE), io = mean(sim_intake, na.rm = TRUE), .groups = "drop")
    plot_ly(pr, x = ~h) %>%
      add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV", fill = "tozeroy", fillcolor = "rgba(251,191,36,0.15)", line = list(color = cl$pv, width = 1)) %>%
      add_trace(y = ~pac, type = "scatter", mode = "lines", name = "PAC optimisee", line = list(color = cl$pac, width = 2)) %>%
      add_trace(y = ~ir, type = "scatter", mode = "lines", name = "Injection reelle", line = list(color = cl$reel, width = 1.5, dash = "dot")) %>%
      add_trace(y = ~io, type = "scatter", mode = "lines", name = "Injection optimisee", line = list(color = cl$opti, width = 1.5)) %>%
      pl_layout(xlab = "Heure", ylab = "kWh/qt")
  })
  
  output$plot_decisions <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    dec <- sim %>% filter(!is.na(decision_raison)) %>%
      mutate(cat = case_when(
        grepl("urgence", decision_raison) ~ "Urgence confort", grepl("ballon_plein", decision_raison) ~ "Ballon plein",
        grepl("surplus_pv", decision_raison) ~ "Surplus PV", grepl("eviter_inj", decision_raison) ~ "Inj. neg. evitee",
        grepl("soutirage_pas_cher", decision_raison) ~ "Soutirage pas cher", grepl("cout_optimal", decision_raison) ~ "Cout optimal",
        grepl("anticipation", decision_raison) ~ "Anticipation confort", grepl("attente", decision_raison) ~ "Attente meilleur",
        grepl("pas_de_surplus|pas_rentable", decision_raison) ~ "Pas d'action", TRUE ~ "Autre")) %>%
      count(cat) %>% arrange(desc(n))
    cols <- c(cl$success, cl$opti, cl$pv, cl$accent3, cl$reel, cl$danger, cl$text_muted, "#6366f1", "#ec4899", "#14b8a6", "#f59e0b", "#8b5cf6")
    plot_ly(dec, labels = ~cat, values = ~n, type = "pie", textposition = "inside", textinfo = "label+percent",
      textfont = list(size = 10, family = "JetBrains Mono"),
      marker = list(colors = cols[1:nrow(dec)], line = list(color = cl$bg_dark, width = 2)), hole = 0.45) %>% pl_layout()
  })
  
  output$plot_prix_pac <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    s <- sim %>% filter(month(timestamp) == 7) %>% slice(1:(7*96))
    if (nrow(s) < 96) s <- tail(sim, 7*96)
    po <- s %>% filter(sim_pac_on == 1)
    plot_ly(s, x = ~timestamp) %>%
      add_trace(y = ~prix_eur_kwh*100, type = "scatter", mode = "lines", name = "Prix spot", line = list(color = cl$prix, width = 1)) %>%
      add_markers(data = po, x = ~timestamp, y = ~prix_eur_kwh*100, name = "PAC ON", marker = list(color = cl$opti, size = 4, opacity = 0.6)) %>%
      pl_layout(ylab = "cEUR/kWh")
  })
  
  output$plot_injection_compare <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    d <- sim %>% mutate(jour = as.Date(timestamp)) %>% group_by(jour) %>%
      summarise(r = sum(intake_kwh, na.rm = TRUE), o = sum(sim_intake, na.rm = TRUE), .groups = "drop") %>% mutate(e = r - o)
    plot_ly(d, x = ~jour) %>%
      add_trace(y = ~r, type = "scatter", mode = "lines", name = "Reel", line = list(color = cl$reel, width = 1)) %>%
      add_trace(y = ~o, type = "scatter", mode = "lines", name = "Optimise", line = list(color = cl$opti, width = 1.5)) %>%
      add_bars(y = ~e, name = "Evite", marker = list(color = "rgba(34,211,238,0.2)")) %>% pl_layout(ylab = "kWh/jour")
  })
  
  # ---- INSIGHTS : Heatmap ----
  output$plot_heatmap <- renderPlotly({
    req(sim_result(), input$heatmap_var); sim <- sim_result()$sim

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
    zlab <- c(inj_evitee = "Inj. evitee (kWh)", surplus = "Surplus PV (kWh)",
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

  # ---- INSIGHTS : Load shifting ----
  output$plot_loadshift <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim; p <- if (!is.null(sim_result()$params)) sim_result()$params else params_r()
    pac_qt <- p$p_pac_kw * p$dt_h

    ls <- sim %>%
      mutate(h = hour(timestamp) + minute(timestamp) / 60) %>%
      group_by(h) %>%
      summarise(
        pac_reel = mean(ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0), na.rm = TRUE),
        pac_opti = mean(sim_pac_on * pac_qt, na.rm = TRUE),
        pv = mean(pv_kwh, na.rm = TRUE),
        .groups = "drop"
      )

    plot_ly(ls, x = ~h) %>%
      add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV moyen",
        fill = "tozeroy", fillcolor = "rgba(251,191,36,0.1)",
        line = list(color = cl$pv, width = 1)) %>%
      add_trace(y = ~pac_reel, type = "scatter", mode = "lines", name = "PAC reel",
        line = list(color = cl$reel, width = 2, dash = "dot")) %>%
      add_trace(y = ~pac_opti, type = "scatter", mode = "lines", name = "PAC optimise",
        line = list(color = cl$opti, width = 2)) %>%
      pl_layout(xlab = "Heure", ylab = "kWh moyen/qt")
  })

  # ---- INSIGHTS : Waterfall ----
  output$plot_waterfall <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim

    # Decomposition du gain
    soutirage_evite_kwh <- sum(sim$offtake_kwh, na.rm = TRUE) - sum(sim$sim_offtake, na.rm = TRUE)
    injection_perdue_kwh <- sum(sim$intake_kwh, na.rm = TRUE) - sum(sim$sim_intake, na.rm = TRUE)

    # Gain soutirage = kWh evites * prix moyen offtake
    prix_moy_offt <- mean(sim$prix_offtake, na.rm = TRUE)
    prix_moy_inj <- mean(sim$prix_injection, na.rm = TRUE)

    gain_soutirage <- soutirage_evite_kwh * prix_moy_offt
    perte_injection <- injection_perdue_kwh * prix_moy_inj

    # Gain de timing (difference entre prix moyen et prix reel pondere)
    cout_reel <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    cout_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
    gain_total <- cout_reel - cout_opti
    gain_timing <- gain_total - gain_soutirage + perte_injection

    labels <- c("Soutirage evite", "Injection perdue", "Timing prix", "Gain net")
    values <- c(gain_soutirage, -perte_injection, gain_timing, gain_total)
    colors <- c(
      ifelse(gain_soutirage >= 0, cl$success, cl$danger),
      ifelse(-perte_injection >= 0, cl$success, cl$danger),
      ifelse(gain_timing >= 0, cl$success, cl$danger),
      ifelse(gain_total >= 0, cl$success, cl$danger)
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
      totals = list(marker = list(color = ifelse(gain_total >= 0, cl$opti, cl$danger)))
    ) %>%
      pl_layout(ylab = "EUR") %>%
      layout(xaxis = list(tickfont = list(size = 10)))
  })

  output$plot_gains <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    m <- sim %>% mutate(mois = floor_date(timestamp, "month")) %>% group_by(mois) %>%
      summarise(cr = sum(offtake_kwh * prix_offtake, na.rm = TRUE) - sum(intake_kwh * prix_injection, na.rm = TRUE),
        co = sum(sim_offtake * prix_offtake, na.rm = TRUE) - sum(sim_intake * prix_injection, na.rm = TRUE), .groups = "drop") %>%
      mutate(gain = cr - co)
    cols <- ifelse(m$gain >= 0, cl$success, cl$danger)
    plot_ly(m, x = ~mois, y = ~gain, type = "bar", marker = list(color = cols, line = list(width = 0)),
      text = ~paste0(round(gain), " EUR"), textposition = "outside",
      textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>% pl_layout(ylab = "Economie (EUR)")
  })
  
  output$table_mensuel <- renderDT({
    req(sim_result()); sim <- sim_result()$sim
    m <- sim %>% mutate(mois = floor_date(timestamp, "month")) %>% group_by(mois) %>%
      summarise(`PV` = round(sum(pv_kwh, na.rm = TRUE)), `Inj.ev` = round(sum(intake_kwh, na.rm = TRUE) - sum(sim_intake, na.rm = TRUE)),
        `EUR reel` = round(sum(offtake_kwh * prix_offtake, na.rm = TRUE) - sum(intake_kwh * prix_injection, na.rm = TRUE)),
        `EUR opti` = round(sum(sim_offtake * prix_offtake, na.rm = TRUE) - sum(sim_intake * prix_injection, na.rm = TRUE)),
        .groups = "drop") %>% mutate(Mois = format(mois, "%b %Y"), `Gain` = `EUR reel` - `EUR opti`) %>% select(Mois, PV, Inj.ev, `EUR reel`, `EUR opti`, Gain)
    datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
      formatStyle("Gain", color = styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
  })
  
  output$plot_cout_repartition <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim
    v <- c(sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE), -sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE))
    plot_ly(labels = c("Soutirage paye", "Injection recue"), values = abs(v), type = "pie",
      textinfo = "label+value", texttemplate = "%{label}<br>%{value:.0f} EUR",
      textfont = list(size = 11, family = "JetBrains Mono"),
      marker = list(colors = c(cl$danger, cl$success), line = list(color = cl$bg_dark, width = 2)), hole = 0.5) %>% pl_layout()
  })
  
  output$plot_zoom <- renderPlotly({
    req(sim_result(), input$date_range); sim <- sim_result()$sim; p <- params_r()
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels"); d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + days(1)
    ch <- sim %>% filter(timestamp >= d1, timestamp < d2)
    if (nrow(ch) == 0) return(plot_ly() %>% pl_layout(title = "Pas de donnees"))
    v <- input$zoom_var
    if (v == "intake") plot_ly(ch, x = ~timestamp) %>% add_trace(y = ~intake_kwh, name = "Reel", type = "scatter", mode = "lines", line = list(color = cl$reel, width = 1)) %>% add_trace(y = ~sim_intake, name = "Optimise", type = "scatter", mode = "lines", line = list(color = cl$opti, width = 1.5)) %>% pl_layout(ylab = "Injection (kWh)")
    else if (v == "offtake") plot_ly(ch, x = ~timestamp) %>% add_trace(y = ~offtake_kwh, name = "Reel", type = "scatter", mode = "lines", line = list(color = cl$reel, width = 1)) %>% add_trace(y = ~sim_offtake, name = "Optimise", type = "scatter", mode = "lines", line = list(color = cl$opti, width = 1.5)) %>% pl_layout(ylab = "Soutirage (kWh)")
    else if (v == "temp") plot_ly(ch, x = ~timestamp) %>% add_trace(y = ~t_ballon, name = "Reel", type = "scatter", mode = "lines", line = list(color = cl$reel, width = 1)) %>% add_trace(y = ~sim_t_ballon, name = "Optimise", type = "scatter", mode = "lines", line = list(color = cl$opti, width = 1.5)) %>% add_segments(x = min(ch$timestamp), xend = max(ch$timestamp), y = p$t_min, yend = p$t_min, showlegend = FALSE, line = list(color = cl$text_muted, dash = "dash", width = .8)) %>% add_segments(x = min(ch$timestamp), xend = max(ch$timestamp), y = p$t_max, yend = p$t_max, showlegend = FALSE, line = list(color = cl$text_muted, dash = "dash", width = .8)) %>% pl_layout(ylab = "C")
    else if (v == "pv_pac") { po <- ch %>% filter(sim_pac_on == 1); plot_ly(ch, x = ~timestamp) %>% add_trace(y = ~pv_kwh, name = "PV", type = "scatter", mode = "lines", fill = "tozeroy", fillcolor = "rgba(251,191,36,0.1)", line = list(color = cl$pv, width = 1)) %>% add_markers(data = po, x = ~timestamp, y = ~(p$p_pac_kw * p$dt_h), name = "PAC ON", marker = list(color = cl$pac, size = 3, opacity = .5)) %>% pl_layout(ylab = "kWh") }
    else if (v == "prix") { po <- ch %>% filter(sim_pac_on == 1); plot_ly(ch, x = ~timestamp) %>% add_trace(y = ~prix_eur_kwh*100, name = "Spot", type = "scatter", mode = "lines", line = list(color = cl$prix, width = 1)) %>% add_markers(data = po, x = ~timestamp, y = ~prix_eur_kwh*100, name = "PAC ON", marker = list(color = cl$opti, size = 4, opacity = .5)) %>% add_segments(x = min(ch$timestamp), xend = max(ch$timestamp), y = 0, yend = 0, showlegend = FALSE, line = list(color = cl$danger, dash = "dot", width = .8)) %>% pl_layout(ylab = "cEUR/kWh") }
  })
  
  # ---- Batterie SoC ----
  output$plot_batterie <- renderPlotly({
    req(sim_result()); sim <- sim_result()$sim; p <- params_r()
    if (!p$batterie_active || is.null(sim$batt_soc)) return(plot_ly() %>% pl_layout())
    
    s <- sim %>% filter(month(timestamp) == 7) %>% slice(1:(7*96))
    if (nrow(s) < 96) s <- tail(sim, 7*96)
    
    plot_ly(s, x = ~timestamp) %>%
      add_trace(y = ~batt_soc * 100, type = "scatter", mode = "lines", name = "SoC",
        fill = "tozeroy", fillcolor = "rgba(34,211,238,0.1)",
        line = list(color = cl$opti, width = 1.5)) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp),
        y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
        line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
      add_segments(x = min(s$timestamp), xend = max(s$timestamp),
        y = p$batt_soc_max * 100, yend = p$batt_soc_max * 100,
        line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
      pl_layout(ylab = "SoC (%)")
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
    modes      <- c("smart", "optimizer")
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
                sim <- if (m == "optimizer") run_optimization_milp(df_prep, p_sim) else run_simulation(df_prep, p_sim, "smart", 0.5)
                
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
          tags$div(class = "kpi-label", "Cout net/an")),
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
    
    updateSliderInput(session, "pv_kwc", value = best$PV_kWc)
    updateCheckboxInput(session, "batterie_active", value = best$Batterie_kWh > 0)
    updateNumericInput(session, "batt_kwh", value = best$Batterie_kWh)
    if (best$Mode == "optimizer") {
      updateRadioButtons(session, "approche", selected = "optimiseur")
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
             `Cout (EUR)` = Cout_EUR, `AC (%)` = Autoconso_pct,
             `Inj (kWh)` = Injection_kWh, `Offt (kWh)` = Soutirage_kWh) %>%
      head(30)
    
    datatable(res, rownames = FALSE,
      options = list(dom = "tip", pageLength = 10, order = list(list(4, "asc"))),
      class = "compact",
      caption = "Top 30 configurations (triees par cout croissant)") %>%
      formatStyle("Cout (EUR)", fontWeight = "bold",
        color = styleInterval(
          quantile(res$`Cout (EUR)`, c(0.33, 0.66), na.rm = TRUE),
          c(cl$success, cl$pv, cl$danger)))
  })
  
  # ---- Dimensionnement PV ----
  output$plot_dim_pv <- renderPlotly({
    req(sim_result()); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    df_base <- res$df

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
        `Cout net (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))
    
    is_current <- scenarii$kWc == kwc_ref
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)
    
    p1 <- plot_ly() %>%
      add_bars(data = scenarii, x = ~factor(kWc), y = ~`Cout net (EUR)`, name = "Cout net",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Cout net (EUR)`, " EUR"), textposition = "outside",
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
      pl_layout(xlab = "kWc installe", ylab = "Cout net (EUR/an)")
    p1
  })
  
  # ---- Dimensionnement batterie ----
  output$plot_dim_batt <- renderPlotly({
    req(sim_result()); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    if (!p$batterie_active) return(plot_ly() %>% pl_layout())
    df_base <- res$df

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
        `Cout net (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))
    
    is_current <- scenarii$`Batterie (kWh)` == p$batt_kwh
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)
    
    plot_ly() %>%
      add_bars(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Cout net (EUR)`, name = "Cout net",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Cout net (EUR)`, " EUR"), textposition = "outside",
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
      pl_layout(xlab = "Capacite batterie (kWh)", ylab = "Cout net (EUR/an)")
  })
}

shinyApp(ui, server)
