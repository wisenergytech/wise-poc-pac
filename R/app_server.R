#' The application server-side
#'
#' @param input,output,session Internal parameters for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_server <- function(input, output, session) {

  # Initialize future plan for async CO2 fetching
  future::plan(future::multisession)

  # Load .env if present (for API keys etc.)
  env_file <- if (file.exists(".env")) ".env" else file.path(app_sys(), "..", "..", ".env")
  if (file.exists(env_file)) {
    env_lines <- readLines(env_file, warn = FALSE)
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

  # ---- MODAL DOCUMENTATION ----
  observeEvent(input$show_guide, {
    showModal(modalDialog(
      title = NULL,
      size = "xl",
      easyClose = TRUE,
      footer = modalButton("Fermer"),
      tags$div(style = sprintf("color:%s;font-size:.85rem;line-height:1.6;", cl$text),
        tags$div(style = "text-align:center;margin-bottom:16px;",
          tags$h4(style = sprintf("color:%s;margin:0;", cl$accent), "Documentation -- PAC Optimizer"),
          tags$p(style = sprintf("color:%s;font-size:.8rem;margin:4px 0 0 0;", cl$text_muted),
            "Cliquez sur une section pour la deplier.")),
        bslib::accordion(id = "guide_modal_accordion", open = FALSE,

          bslib::accordion_panel("1. Flux de donnees", icon = icon("database"),
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

          bslib::accordion_panel("2. Modele thermique du ballon", icon = icon("temperature-half"),
            tags$p("Modele simple calibre sur vos donnees :"),
            tags$pre(style = sprintf("background:%s;border-radius:8px;padding:12px;font-size:.78rem;color:%s;", cl$bg_input, cl$opti),
              "T(t+1) = T(t) + (chaleur_PAC - pertes - soutirage_ECS) / capacite_thermique"),
            tags$ul(
              tags$li(tags$strong("Chaleur PAC"), " = puissance x COP (varie avec T ext)"),
              tags$li(tags$strong("Pertes"), " = refroidissement naturel (calibre)"),
              tags$li(tags$strong("Capacite"), " = volume x 0.001163 kWh/L/degre"))
          ),

          bslib::accordion_panel("3. COP", icon = icon("gauge-high"),
            tags$p("Ratio chaleur produite / electricite consommee. Varie avec T exterieure :"),
            tags$ul(tags$li("0C : COP = 2.5"), tags$li("7C : COP = 3.5 (nominal)"),
              tags$li("15C : COP = 4.3"), tags$li("20C : COP = 4.8")),
            tags$p("Chauffer en journee = surplus PV + meilleur COP.")
          ),

          bslib::accordion_panel("4. Modes d'optimisation", icon = icon("sliders"),
            tags$h6(style = sprintf("color:%s;", cl$success), "SMART (Rule-based)"), tags$p("Decision basee sur la valeur nette a chaque quart d'heure."),
            tags$h6(style = sprintf("color:%s;", cl$opti), "OPTIMIZER (MILP)"), tags$p("Resout un probleme d'optimisation mathematique (MILP).")
          ),

          bslib::accordion_panel("5. Types de decisions", icon = icon("code-branch"),
            tags$p("Voir la documentation complete dans l'app standalone (app.R).")
          ),

          bslib::accordion_panel("6. D'ou viennent les prix ?", icon = icon("coins"),
            tags$p("Marche day-ahead Belpex, publie par ENTSO-E Transparency.")
          ),

          bslib::accordion_panel("7. Prix, ecologie et optimisation", icon = icon("leaf"),
            tags$p("Prix bas = renouvelable abondant = reseau vert.")
          )
        ) # fin accordion
      ) # fin tags$div
    )) # fin modalDialog + showModal
  })

  # Description dynamique de la baseline selectionnee
  output$baseline_description <- renderUI({
    bt <- input$baseline_type
    descs <- list(
      reactif = list(
        txt = "Thermostat classique : allume quand T < T_min, eteint quand T > consigne. Completement aveugle du PV, des prix et de l'ECS futur. Represente une installation sans aucun pilotage.",
        ac = "~10-15%", marge = "maximale", col = cl$success),
      programmateur = list(
        txt = "L'installateur a programme la PAC entre 11h et 15h pour coincider avec le PV. En dehors de cette plage, thermostat reactif. Tres courant sur les installations recentes avec PV.",
        ac = "~40-50%", marge = "moderee", col = "#f59e0b"),
      surplus_pv = list(
        txt = "Onduleur avec sortie surplus (Fronius, SMA, Huawei) : la PAC s'allume quand le surplus PV depasse un seuil. Sinon thermostat reactif. ON/OFF sans modulation.",
        ac = "~30-50%", marge = "moderee", col = "#f59e0b"),
      ingenieur = list(
        txt = "Le mieux qu'on peut faire SANS signal prix. Module la PAC pour coller au surplus PV, anticipe le confort, pre-chauffe quand le COP est bon (T_ext favorable). Aveugle au Belpex. C'est la reference realiste pour mesurer la valeur ajoutee du pilotage par les prix spot.",
        ac = "~60-80%", marge = "faible -- gains = valeur du Belpex", col = cl$reel),
      proactif = list(
        txt = "Thermostat intelligent qui anticipe les chutes de temperature (regarde 1 pas en avant). N'utilise pas le PV ni les prix. Avantage la baseline et reduit les gains affiches.",
        ac = "~15-20%", marge = "elevee", col = cl$success)
    )
    d <- descs[[bt]]
    if (is.null(d)) return(NULL)
    tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:4px;", cl$text_muted),
      HTML(sprintf("%s<br><span style='color:%s;font-weight:600;'>Autoconso typique : %s</span> &middot; Marge d'optimisation : <b>%s</b>",
        d$txt, d$col, d$ac, d$marge)))
  })

  # Volume ballon : auto ou manuel
  volume_ballon_eff <- reactive({
    if (isTRUE(input$volume_auto)) {
      p_kw <- input$p_pac_kw
      cop <- input$cop_nominal
      tol <- input$t_tolerance
      delta_t <- 2 * tol
      heures_stockage <- 2
      energie_kwh <- p_kw * cop * heures_stockage
      vol <- energie_kwh / (delta_t * 0.001163)
      round(vol / 50) * 50
    } else {
      input$volume_ballon_manual
    }
  })

  output$volume_auto_display <- renderUI({
    vol <- volume_ballon_eff()
    p_kw <- input$p_pac_kw; cop <- input$cop_nominal; tol <- input$t_tolerance
    delta_t <- 2 * tol
    cap_kwh <- vol * 0.001163 * delta_t
    cap_elec <- round(cap_kwh / cop, 1)
    heures_flex <- round(cap_kwh / (p_kw * cop), 1)
    tags$div(style = sprintf("font-size:.85rem;color:%s;padding:4px 8px;background:%s;border-radius:4px;margin-bottom:6px;",
      cl$opti, cl$bg_input),
      HTML(sprintf("<b>%s L</b> &middot; stockage <b>%s kWh<sub>th</sub></b> (%s kWh<sub>e</sub>) &middot; <b>%sh</b> de flexibilite",
        formatC(vol, format = "d", big.mark = " "), round(cap_kwh, 1), cap_elec, heures_flex)))
  })

  # PV auto
  pv_kwc_eff <- reactive({
    if (isTRUE(input$pv_auto)) {
      p_pac <- input$p_pac_kw
      vol <- volume_ballon_eff()
      cop_moy <- input$cop_nominal

      if (p_pac <= 10) {
        pertes_jour_kwh <- 0.004 * (input$t_consigne - 20) * 24
        ecs_jour_kwh <- 6 * vol / 200
        conso_pac_an <- (ecs_jour_kwh + pertes_jour_kwh) / cop_moy * 365
      } else {
        heq_jour <- 5
        conso_pac_an <- p_pac * heq_jour * 365 / cop_moy
      }

      kwc <- conso_pac_an / 950
      round(kwc * 2) / 2
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
      curtailment_active = isTRUE(input$curtailment_active),
      curtail_kwh_per_qt = if (isTRUE(input$curtailment_active)) input$curtail_kw * 0.25 else Inf,
      optim_bloc_h = if (!is.null(input$optim_bloc_h)) input$optim_bloc_h else 4)
  })

  raw_data <- reactive({
    if (input$data_source == "csv") {
      req(input$csv_file)
      df <- readr::read_csv(input$csv_file$datapath, show_col_types = FALSE) %>% mutate(timestamp = lubridate::ymd_hms(timestamp))
    } else {
      req(input$date_range)
      df <- generer_demo(input$date_range[1], input$date_range[2],
        p_pac_kw = input$p_pac_kw, volume_ballon_l = volume_ballon_eff(),
        pv_kwc = pv_kwc_eff(),
        ecs_kwh_jour = input$ecs_kwh_jour,
        building_type = if (!is.null(input$building_type)) input$building_type else "standard")
    }

    # Injecter les vrais prix Belpex (CSV uniquement)
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
            datetime_bxl = lubridate::with_tz(datetime, tzone = "Europe/Brussels"),
            heure_join = lubridate::floor_date(datetime_bxl, unit = "hour"),
            prix_belpex = price_eur_mwh / 1000
          ) %>%
          distinct(heure_join, .keep_all = TRUE) %>%
          select(heure_join, prix_belpex)

        df <- df %>%
          mutate(heure_join = lubridate::floor_date(timestamp, unit = "hour")) %>%
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

      baseline_mode <- if (!is.null(input$baseline_type)) input$baseline_type else "reactif"
      setProgress(0.2, detail = paste0("Calcul baseline ", baseline_mode, "..."))
      df_prep <- run_baseline(df_prep, p, mode = baseline_mode)

      # Filet de securite
      guard_baseline <- function(sim, df_prep, p, mode_label) {
        facture_baseline <- sum(df_prep$offtake_kwh * df_prep$prix_offtake - df_prep$intake_kwh * df_prep$prix_injection, na.rm = TRUE)
        facture_opti <- sum(sim$sim_offtake * sim$prix_offtake - sim$sim_intake * sim$prix_injection, na.rm = TRUE)
        if (facture_opti > facture_baseline) {
          message(sprintf("[%s] Facture opti (%.1f) > baseline (%.1f) -- fallback baseline", mode_label, facture_opti, facture_baseline))
          sim$sim_t_ballon <- df_prep$t_ballon
          sim$sim_offtake <- df_prep$offtake_kwh
          sim$sim_intake <- df_prep$intake_kwh
          sim$sim_cop <- calc_cop(df_prep$t_ext, p$cop_nominal, p$t_ref_cop)
          sim$decision_raison <- "baseline_fallback"
          sim$mode_actif <- paste0(mode_label, "_baseline")
          showNotification(sprintf("%s fait pire que la baseline -- resultats baseline affiches", mode_label), type = "warning", duration = 8)
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
          showNotification("Optimisation MILP infaisable", type = "error")
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
          showNotification("Optimisation LP infaisable", type = "error")
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
          showNotification("Optimisation QP infaisable", type = "error")
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
    cr <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm=TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm=TRUE)
    co <- sum(sim$sim_offtake * sim$prix_offtake, na.rm=TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm=TRUE)
    jours <- round(as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days")), 1)
    thermostat <- if (!is.null(input$baseline_type)) input$baseline_type else "n/a"
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
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + lubridate::days(1)
    sim %>% filter(timestamp >= d1, timestamp < d2)
  })

  # ---- Onglet Comparaison ----
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

  compare_derived <- c("autoconso_baseline", "autoconso_opti", "facture_baseline", "facture_opti")

  observeEvent(sim_result(), {
    sim <- sim_result()$sim
    avail_native <- compare_vars[compare_vars %in% names(sim)]
    avail_derived <- compare_vars[compare_vars %in% compare_derived]
    avail <- c(avail_native, avail_derived)
    updateSelectInput(session, "compare_var1", choices = avail,
      selected = if ("pv_kwh" %in% avail) "pv_kwh" else avail[1])
    updateSelectInput(session, "compare_var2", choices = avail,
      selected = if ("prix_eur_kwh" %in% avail) "prix_eur_kwh" else avail[min(2, length(avail))])
    avail3 <- c("Aucune" = "", avail)
    updateSelectInput(session, "compare_var3", choices = avail3, selected = "")
  })

  get_unit <- function(var) {
    if (is.null(var) || var == "") return(NA_character_)
    label <- names(compare_vars)[compare_vars == var]
    if (length(label) == 0) return(NA_character_)
    m <- regmatches(label, regexpr("\\(([^)]+)\\)", label))
    if (length(m) == 0) return(NA_character_)
    gsub("[()]", "", m)
  }

  observeEvent(input$date_range, {
    req(input$date_range)
    updateDateRangeInput(session, "compare_range",
      start = input$date_range[1], end = input$date_range[2],
      min = input$date_range[1], max = input$date_range[2])
  })

  compare_data <- reactive({
    req(sim_result(), input$compare_range)
    sim <- sim_result()$sim
    d1 <- as.POSIXct(input$compare_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$compare_range[2], tz = "Europe/Brussels") + lubridate::days(1)
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
    if (!all(vars %in% names(df))) return(plotly::plot_ly())

    summable <- c("pv_kwh", "offtake_kwh", "sim_offtake", "intake_kwh", "sim_intake",
      "conso_hors_pac", "soutirage_estime_kwh", "sim_pac_on",
      "autoconso_baseline", "autoconso_opti",
      "facture_baseline", "facture_opti")

    nr <- nrow(df)
    level <- if (nr <= 14 * 96) "qt" else if (nr <= 60 * 96) "hour" else if (nr <= 180 * 96) "day" else "week"
    label <- c(qt = "15 min", hour = "Horaire", day = "Journalier", week = "Hebdomadaire")[level]

    df_work <- df %>% mutate(.w = case_when(
      level == "qt" ~ timestamp,
      level == "hour" ~ lubridate::floor_date(timestamp, "hour"),
      level == "day" ~ lubridate::floor_date(timestamp, "day"),
      level == "week" ~ lubridate::floor_date(timestamp, "week")
    ))
    agg_exprs <- lapply(vars, function(v) {
      if (v %in% summable) rlang::expr(sum(.data[[!!v]], na.rm = TRUE))
      else rlang::expr(mean(.data[[!!v]], na.rm = TRUE))
    })
    names(agg_exprs) <- vars
    df_agg <- df_work %>% group_by(.w) %>%
      summarise(!!!agg_exprs, .groups = "drop") %>%
      rename(timestamp = .w)

    label1 <- names(compare_vars)[compare_vars == v1]
    label2 <- names(compare_vars)[compare_vars == v2]
    unit1 <- get_unit(v1); unit2 <- get_unit(v2)

    add_smart_trace <- function(p, y_vals, var_name, label, color, yaxis, dash = NULL) {
      if (var_name %in% summable) {
        p %>% plotly::add_bars(y = y_vals, name = label,
          marker = list(color = color, opacity = 0.7), yaxis = yaxis)
      } else {
        p %>% plotly::add_trace(y = y_vals, type = "scatter", mode = "lines",
          name = label, line = list(color = color, width = 2, dash = dash), yaxis = yaxis)
      }
    }

    p <- plotly::plot_ly(df_agg, x = ~timestamp) %>%
      add_smart_trace(df_agg[[v1]], v1, label1, cl$opti, "y") %>%
      add_smart_trace(df_agg[[v2]], v2, label2, cl$accent3, "y2")

    if (!is.na(v3)) {
      label3 <- names(compare_vars)[compare_vars == v3]
      unit3 <- get_unit(v3)
      if (!is.na(unit3) && !is.na(unit1) && unit3 == unit1) {
        axe3 <- "y"; col3 <- cl$success
      } else if (!is.na(unit3) && !is.na(unit2) && unit3 == unit2) {
        axe3 <- "y2"; col3 <- cl$pv
      } else {
        axe3 <- "y"; col3 <- cl$success
        showNotification(sprintf("Serie 3 (unite %s) placee sur l'axe gauche par defaut", unit3),
          type = "warning", duration = 3)
      }
      p <- p %>% add_smart_trace(df_agg[[v3]], v3, label3, col3, axe3, dash = "dot")
    }

    p %>% plotly::layout(
      title = paste0("Agregation: ", label),
      yaxis = list(title = label1, tickfont = list(color = cl$opti),
        titlefont = list(color = cl$opti)),
      yaxis2 = list(title = label2, overlaying = "y", side = "right",
        tickfont = list(color = cl$accent3), titlefont = list(color = cl$accent3),
        gridcolor = "rgba(0,0,0,0)"),
      hovermode = "x unified",
      barmode = "group"
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

    thermostat <- if (!is.null(input$baseline_type)) input$baseline_type else "n/a"
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
      tags$span(HTML(sprintf("SIMULATION %s -- %.1f j &middot; %s pts &middot; GAIN <b style='color:%s'>%.1f EUR (%.1f%%)</b>",
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
      line_tag("CFG ", sprintf("Contrat=<b>%s</b> &middot; Batterie=<b>%s</b> &middot; Curtail=<b>%s</b> &middot; Bloc=<b>%s</b> &middot; Slack=<b>%s EUR/C</b> &middot; Baseline=<b>%s</b> &middot; Source=<b>%s</b> &middot; <b>%s</b> &rarr; <b>%s</b>",
        contrat, batt,
        if (isTRUE(input$curtailment_active)) paste0(input$curtail_kw, "kW") else "off",
        bloc, if (!is.null(input$slack_penalty)) input$slack_penalty else "n/a",
        thermostat, input$data_source,
        format(input$date_range[1], "%d/%m/%Y"), format(input$date_range[2], "%d/%m/%Y")))
    )
  })
  outputOptions(output, "status_bar", suspendWhenHidden = FALSE)

  # ---- KPIs ENERGIE ----
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
    conso_pac_base <- sum(sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac, na.rm = TRUE)
    conso_pac_base <- max(0, conso_pac_base)

    kpis <- list(
      kpi_card(formatC(round(pv_tot), big.mark = " ", format = "d"),
        "Production PV", "kWh", cl$pv,
        tooltip = "Production photovoltaique totale sur la periode."),
      kpi_card(paste0(ac_opti, "%"),
        "Autoconsommation", "", cl$success,
        baseline_val = ac_base, opti_val = ac_opti,
        gain_val = round(ac_opti - ac_base, 1), gain_unit = "pts",
        tooltip = "Part du PV consommee sur place."),
      kpi_card(formatC(round(offt_base - offt_opti), big.mark = " ", format = "d"),
        "Moins de soutirage", "kWh", cl$accent3,
        baseline_val = offt_base, opti_val = offt_opti, gain_invert = TRUE,
        gain_val = round(offt_base - offt_opti), gain_unit = "kWh",
        tooltip = "Reduction du soutirage reseau."),
      kpi_card(formatC(round(inj_base - inj_opti), big.mark = " ", format = "d"),
        "Moins d'injection", "kWh", cl$opti,
        baseline_val = inj_base, opti_val = inj_opti, gain_invert = TRUE,
        gain_val = round(inj_base - inj_opti), gain_unit = "kWh",
        tooltip = "Reduction de l'injection reseau."),
      kpi_card(formatC(round(conso_pac_opti), big.mark = " ", format = "d"),
        "Conso PAC", "kWh", cl$pac,
        baseline_val = conso_pac_base, opti_val = conso_pac_opti, gain_invert = TRUE,
        gain_val = round(conso_pac_opti - conso_pac_base), gain_unit = "kWh",
        tooltip = "Consommation electrique de la PAC.")
    )

    if (p$batterie_active && !is.null(sim$batt_flux)) {
      charge_tot <- sum(pmax(0, sim$batt_flux), na.rm = TRUE)
      cycles <- round(charge_tot / max(p$batt_kwh, 1), 1)
      kpis <- c(kpis, list(
        kpi_card(cycles, "Cycles batterie", "", cl$accent3,
          tooltip = "Cycles complets de charge/decharge.")))
    }

    do.call(tags$div, c(
      list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
      lapply(kpis, function(k) tags$div(style = "flex:1;", k))
    ))
  })

  # ---- KPIs FINANCES ----
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

    kpis <- list(
      kpi_card(paste0(round(facture_base), " EUR"),
        "Facture baseline", "", cl$reel,
        tooltip = "Cout net baseline."),
      kpi_card(paste0(round(facture_opti), " EUR"),
        "Facture optimisee", "", cl$opti,
        baseline_val = facture_base, opti_val = facture_opti, gain_invert = TRUE,
        tooltip = "Cout net optimise."),
      kpi_card(paste0(ifelse(gain >= 0, "+", ""), round(gain), " EUR"),
        "Economie nette", "", if (gain >= 0) cl$success else cl$danger,
        tooltip = "Economie = facture baseline - facture optimisee."),
      kpi_card(paste0(pct_gain, "%"),
        "Reduction facture", "", if (gain >= 0) cl$success else cl$danger,
        tooltip = "Reduction en %."),
      kpi_card(paste0(round(cout_sout_base - cout_sout_opti), " EUR"),
        "Eco. soutirage", "", cl$accent3,
        baseline_val = cout_sout_base, opti_val = cout_sout_opti, gain_invert = TRUE,
        tooltip = "Economie sur le soutirage."),
      kpi_card(paste0(round(rev_inj_opti - rev_inj_base), " EUR"),
        "Delta injection", "", cl$pv,
        tooltip = "Variation du revenu d'injection.")
    )
    do.call(tags$div, c(
      list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
      lapply(kpis, function(k) tags$div(style = "flex:1;", k))
    ))
  })

  # ---- Energy charts ----
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
    plotly::plot_ly(cd$data, x = ~timestamp) %>%
      plotly::add_bars(y = ~soutirage_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
      plotly::add_bars(y = ~soutirage_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
      plotly::layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })

  output$plot_injection <- renderPlotly({
    req(conso_data()); cd <- conso_data()
    plotly::plot_ly(cd$data, x = ~timestamp) %>%
      plotly::add_bars(y = ~injection_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
      plotly::add_bars(y = ~injection_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
      plotly::layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })

  output$plot_autoconso <- renderPlotly({
    req(conso_data()); cd <- conso_data()
    plotly::plot_ly(cd$data, x = ~timestamp) %>%
      plotly::add_bars(y = ~autoconso_baseline, name = "Baseline", marker = list(color = cl$pv, opacity = 0.6)) %>%
      plotly::add_bars(y = ~autoconso_opti, name = "Optimise", marker = list(color = cl$success)) %>%
      plotly::layout(barmode = "group", bargap = 0.1) %>%
      pl_layout(ylab = paste0("kWh (", cd$label, ")"))
  })

  output$plot_temperature <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    s <- sim %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(t_ballon = mean(t_ballon, na.rm = TRUE),
                sim_t_ballon = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h)
    plotly::plot_ly(s, x = ~timestamp) %>%
      plotly::add_trace(y = ~t_ballon, type = "scatter", mode = "lines", name = "Baseline", line = list(color = cl$reel, width = 1)) %>%
      plotly::add_trace(y = ~sim_t_ballon, type = "scatter", mode = "lines", name = "Optimise", line = list(color = cl$opti, width = 1.5)) %>%
      plotly::add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_min, yend = p$t_min, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      plotly::add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_max, yend = p$t_max, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
      pl_layout(ylab = "C")
  })

  output$plot_cop <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()
    d <- sim %>% filter(!is.na(sim_cop)) %>% mutate(jour = as.Date(timestamp)) %>%
      group_by(jour) %>% summarise(cop = mean(sim_cop, na.rm = TRUE), .groups = "drop")
    plotly::plot_ly(d, x = ~jour, y = ~cop, type = "scatter", mode = "lines", line = list(color = cl$pac, width = 1.5), fill = "tozeroy", fillcolor = "rgba(52,211,153,0.08)") %>% pl_layout(ylab = "COP")
  })

  # ---- FINANCES : Facture nette cumulee ----
  output$plot_cout_cumule <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()
    d <- sim %>%
      mutate(
        facture_reel_qt = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
        facture_opti_qt = sim_offtake * prix_offtake - sim_intake * prix_injection
      ) %>%
      mutate(
        cum_reel = cumsum(ifelse(is.na(facture_reel_qt), 0, facture_reel_qt)),
        cum_opti = cumsum(ifelse(is.na(facture_opti_qt), 0, facture_opti_qt))
      )
    d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
      group_by(h) %>% slice_tail(n = 1) %>% ungroup()
    plotly::plot_ly(d_h, x = ~timestamp) %>%
      plotly::add_trace(y = ~cum_reel, type = "scatter", mode = "lines", name = "Facture baseline",
        line = list(color = cl$reel, width = 2), fill = "tozeroy", fillcolor = "rgba(249,115,22,0.08)") %>%
      plotly::add_trace(y = ~cum_opti, type = "scatter", mode = "lines", name = "Facture optimisee",
        line = list(color = cl$opti, width = 2), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.08)") %>%
      pl_layout(ylab = "Facture nette cumulee (EUR)")
  })

  # ---- DETAILS : PAC timeline ----
  output$plot_pac_timeline <- renderPlotly({
    req(sim_filtered())
    sf <- sim_filtered()
    p <- if (!is.null(sim_result()$params)) sim_result()$params else params_r()
    pac_qt <- p$p_pac_kw * p$dt_h

    sf <- sf %>% mutate(
      pac_kwh_reel = ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0),
      pac_kwh_opti = sim_pac_on * pac_qt
    )

    agg <- auto_aggregate(sf)
    d <- agg$data

    plotly::plot_ly(d, x = ~timestamp) %>%
      plotly::add_trace(y = ~pv_kwh, type = "scatter", mode = "lines", name = "Production PV",
        fill = "tozeroy", fillcolor = "rgba(251,191,36,0.12)",
        line = list(color = cl$pv, width = 1)) %>%
      plotly::add_bars(y = ~pac_kwh_reel, name = "PAC baseline",
        marker = list(color = cl$reel, opacity = 0.4)) %>%
      plotly::add_bars(y = ~pac_kwh_opti, name = "PAC optimise",
        marker = list(color = cl$opti, opacity = 0.7)) %>%
      plotly::layout(barmode = "overlay", bargap = 0.05) %>%
      pl_layout(ylab = paste0("kWh (", agg$label, ")"))
  })

  # ---- DETAILS : Heatmap ----
  output$plot_heatmap <- renderPlotly({
    req(sim_filtered(), input$heatmap_var); sim <- sim_filtered()

    hm <- sim %>%
      mutate(jour = as.Date(timestamp), h = floor(lubridate::hour(timestamp) + lubridate::minute(timestamp) / 60)) %>%
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

    mat <- hm %>%
      select(jour, h, val = !!sym(v)) %>%
      tidyr::pivot_wider(names_from = h, values_from = val) %>%
      arrange(jour)

    jours <- mat$jour
    heures <- as.integer(colnames(mat)[-1])
    z_mat <- as.matrix(mat[, -1])

    txt_mat <- matrix(
      paste0(rep(format(jours, "%d %b %Y"), each = length(heures)), " ", rep(heures, length(jours)), "h\n",
             round(as.vector(t(z_mat)), 2), " ", zlab[v]),
      nrow = length(jours), ncol = length(heures), byrow = TRUE)

    plotly::plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
      colorscale = cs, hoverinfo = "text", text = txt_mat,
      colorbar = list(title = list(text = zlab[v], font = list(color = cl$text_muted, size = 9)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "Heure", ylab = NULL)
  })

  # ---- FINANCES : Waterfall ----
  output$plot_waterfall <- renderPlotly({
    req(sim_filtered()); sim <- sim_filtered()

    moins_soutirage_kwh <- sum(sim$offtake_kwh, na.rm = TRUE) - sum(sim$sim_offtake, na.rm = TRUE)
    moins_injection_kwh <- sum(sim$intake_kwh, na.rm = TRUE) - sum(sim$sim_intake, na.rm = TRUE)
    prix_moy_offt <- mean(sim$prix_offtake, na.rm = TRUE)
    prix_moy_inj <- mean(sim$prix_injection, na.rm = TRUE)
    eco_soutirage <- moins_soutirage_kwh * prix_moy_offt
    perte_injection <- moins_injection_kwh * prix_moy_inj
    facture_reel <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) - sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
    facture_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) - sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
    eco_totale <- facture_reel - facture_opti
    eco_arbitrage <- eco_totale - eco_soutirage + perte_injection

    labels <- c("Moins de soutirage", "Moins d'injection", "Arbitrage horaire", "Economie totale")
    values <- c(eco_soutirage, -perte_injection, eco_arbitrage, eco_totale)
    measures <- c("relative", "relative", "relative", "total")

    plotly::plot_ly(
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
      plotly::layout(xaxis = list(tickfont = list(size = 10)))
  })

  output$table_mensuel <- DT::renderDT({
    req(sim_filtered()); sim <- sim_filtered()
    m <- sim %>% mutate(mois = lubridate::floor_date(timestamp, "month")) %>% group_by(mois) %>%
      summarise(`PV` = round(sum(pv_kwh, na.rm = TRUE)),
        `Facture baseline` = round(sum(offtake_kwh * prix_offtake - intake_kwh * prix_injection, na.rm = TRUE)),
        `Facture opti` = round(sum(sim_offtake * prix_offtake - sim_intake * prix_injection, na.rm = TRUE)),
        .groups = "drop") %>%
      mutate(Mois = format(mois, "%b %Y"), Economie = `Facture baseline` - `Facture opti`, `EUR/j` = round(Economie / lubridate::days_in_month(mois), 2)) %>%
      select(Mois, PV, `Facture baseline`, `Facture opti`, Economie, `EUR/j`)
    DT::datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
      DT::formatStyle("Economie", color = DT::styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
  })

  # ---- IMPACT CO2 ----
  co2_prefetched <- reactiveVal(NULL)

  observeEvent(sim_result(), {
    res <- sim_result()
    sim <- res$sim
    start_d <- min(sim$timestamp, na.rm = TRUE)
    end_d   <- max(sim$timestamp, na.rm = TRUE)

    co2_future <- future::future({
      suppressPackageStartupMessages({
        library(dplyr)
        library(lubridate)
        library(httr)
      })
      source("R/co2_elia.R", local = TRUE)
      fetch_co2_intensity(start_d, end_d)
    }, seed = TRUE)

    promises::then(co2_future,
      onFulfilled = function(result) {
        co2_prefetched(result)
        message(sprintf("[CO2] Pre-fetch termine : %s (%d pts)",
          result$source, nrow(result$df)))
      },
      onRejected = function(err) {
        message(sprintf("[CO2] Pre-fetch echoue : %s -- fallback", err$message))
        source("R/co2_elia.R", local = TRUE)
        co2_prefetched(build_fallback_co2(start_d, end_d) |>
          (\(df) list(df = df, source = "fallback"))())
      }
    )
  }, priority = -1)  # lower priority so sim_result() processes first

  co2_data <- reactive({
    req(sim_filtered())
    prefetched <- co2_prefetched()
    if (!is.null(prefetched)) return(prefetched)
    sim <- sim_filtered()
    start_d <- min(sim$timestamp, na.rm = TRUE)
    end_d   <- max(sim$timestamp, na.rm = TRUE)
    fetch_co2_intensity(start_d, end_d)
  })

  co2_impact <- reactive({
    req(sim_filtered(), co2_data())
    sim <- sim_filtered()
    co2_raw <- co2_data()
    co2_15min <- interpolate_co2_15min(co2_raw$df, sim$timestamp)
    compute_co2_impact(sim, co2_15min)
  })

  output$co2_kpi_row <- renderUI({
    req(co2_impact())
    impact <- co2_impact()

    co2_base_kg <- sum(impact$co2_baseline_g, na.rm = TRUE) / 1000
    co2_opti_kg <- sum(impact$co2_opti_g, na.rm = TRUE) / 1000

    kpis <- list(
      kpi_card(sprintf("%.1f", impact$co2_saved_kg),
        "CO2 evite", "kg", cl$success,
        baseline_val = co2_base_kg, opti_val = co2_opti_kg, gain_invert = TRUE,
        gain_val = round(impact$co2_saved_kg, 1), gain_unit = "kg",
        tooltip = "Emissions evitees."),
      kpi_card(sprintf("%.0f", impact$intensity_before),
        "Intensite baseline", "gCO2/kWh", cl$reel,
        tooltip = "Intensite carbone moyenne ponderee par la consommation baseline."),
      kpi_card(sprintf("%.0f", impact$intensity_after),
        "Intensite optimisee", "gCO2/kWh", cl$opti,
        baseline_val = impact$intensity_before, opti_val = impact$intensity_after, gain_invert = TRUE,
        gain_val = round(impact$intensity_after - impact$intensity_before), gain_unit = "gCO2/kWh",
        tooltip = "Intensite carbone ponderee par la consommation optimisee."),
      kpi_card(sprintf("%.1f%%", impact$co2_pct_reduction),
        "Reduction intensite", "", cl$success,
        tooltip = "Reduction de l'intensite carbone."),
      kpi_card(sprintf("%.0f", impact$equiv_car_km),
        "Equiv. voiture", "km", "#22d3ee",
        tooltip = "Kilometres de voiture equivalents au CO2 evite."),
      kpi_card(sprintf("%.1f", impact$equiv_trees_year),
        "Equiv. arbres", "/an", "#fbbf24",
        tooltip = "Nombre d'arbres necessaires pour absorber le CO2 evite en 1 an.")
    )
    do.call(tags$div, c(
      list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
      lapply(kpis, function(k) tags$div(style = "flex:1;", k))
    ))
  })

  output$plot_co2_hourly <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(co2_saved_g = impact$co2_saved_g, co2_intensity = impact$co2_intensity,
        h = lubridate::floor_date(timestamp, "hour")) %>%
      group_by(h) %>%
      summarise(co2_saved_g = sum(co2_saved_g, na.rm = TRUE),
        co2_intensity = mean(co2_intensity, na.rm = TRUE), .groups = "drop") %>%
      rename(timestamp = h)

    bar_colors <- ifelse(d$co2_saved_g >= 0, cl$success, cl$danger)

    plotly::plot_ly(d, x = ~timestamp) %>%
      plotly::add_bars(y = ~co2_saved_g, name = "CO2 evite (g)",
        marker = list(color = bar_colors)) %>%
      plotly::add_trace(y = ~co2_intensity, type = "scatter", mode = "lines",
        name = "Intensite reseau (gCO2/kWh)", yaxis = "y2",
        line = list(color = cl$accent3, width = 1.5, dash = "dot")) %>%
      pl_layout(ylab = "CO2 evite (g)") %>%
      plotly::layout(
        yaxis2 = list(title = "gCO2eq/kWh", overlaying = "y", side = "right",
          gridcolor = "transparent", tickfont = list(size = 10, color = cl$accent3),
          titlefont = list(color = cl$accent3, size = 11)),
        barmode = "relative"
      )
  })

  output$plot_co2_cumul <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(co2_cumul_kg = impact$co2_saved_cumul_kg) %>%
      select(timestamp, co2_cumul_kg)

    plotly::plot_ly(d, x = ~timestamp, y = ~co2_cumul_kg, type = "scatter", mode = "lines",
      name = "CO2 evite cumule",
      fill = "tozeroy", fillcolor = "rgba(52,211,153,0.15)",
      line = list(color = cl$success, width = 2)) %>%
      pl_layout(ylab = "kg CO2eq evite")
  })

  output$plot_co2_heatmap <- renderPlotly({
    req(sim_filtered(), co2_impact())
    sim <- sim_filtered()
    impact <- co2_impact()

    d <- sim %>%
      mutate(co2_intensity = impact$co2_intensity,
        jour = as.Date(timestamp), h = lubridate::hour(timestamp)) %>%
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

    cs <- list(c(0, "#065f46"), c(0.3, "#34d399"), c(0.5, "#fbbf24"), c(0.8, "#f97316"), c(1, "#dc2626"))

    plotly::plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
      colorscale = cs, hoverinfo = "text", text = txt_mat,
      colorbar = list(title = list(text = "gCO2/kWh", font = list(color = cl$text_muted, size = 9)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "Heure", ylab = NULL)
  })

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
    if (!p$batterie_active || is.null(sim$batt_soc)) return(plotly::plot_ly() %>% pl_layout())

    plotly::plot_ly(sim, x = ~timestamp) %>%
      plotly::add_trace(y = ~batt_soc * 100, type = "scatter", mode = "lines", name = "SoC",
        fill = "tozeroy", fillcolor = "rgba(34,211,238,0.1)",
        line = list(color = cl$opti, width = 1.5)) %>%
      plotly::add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
        y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
        line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
      plotly::add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
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

    nodes <- list(
      label = c("PV", "Reseau", "PAC", "Conso residuelle", "Injection"),
      color = c(cl$pv, cl$danger, cl$pac, cl$text_muted, cl$reel),
      pad = 20, thickness = 20
    )

    links <- list(
      source = c(0, 0, 0, 1, 1),
      target = c(2, 3, 4, 2, 3),
      value = c(
        min(pv_auto, pac_elec),
        max(0, pv_auto - pac_elec),
        inj,
        max(0, pac_elec - pv_auto),
        max(0, off - max(0, pac_elec - pv_auto))
      ),
      color = c(
        "rgba(251,191,36,0.4)", "rgba(251,191,36,0.2)",
        "rgba(249,115,22,0.4)", "rgba(248,113,113,0.4)", "rgba(248,113,113,0.2)"
      )
    )

    mask <- links$value > 0.5
    links$source <- links$source[mask]
    links$target <- links$target[mask]
    links$value <- round(links$value[mask])
    links$color <- links$color[mask]

    plotly::plot_ly(type = "sankey", orientation = "h",
      node = list(
        label = paste0(nodes$label, " (", c(round(pv_tot), round(off), round(pac_elec), round(maison), round(inj)), " kWh)"),
        color = nodes$color, pad = nodes$pad, thickness = nodes$thickness,
        line = list(width = 0)
      ),
      link = list(source = links$source, target = links$target,
        value = links$value, color = links$color)
    ) %>% pl_layout()
  })

  # ---- CONTRAINTES : Scorecard ----
  output$cv_scorecard <- renderUI({
    req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
    pac_qt <- p$p_pac_kw * p$dt_h
    n_tot <- sum(!is.na(sim$sim_t_ballon))

    n_low  <- sum(sim$sim_t_ballon < p$t_min, na.rm = TRUE)
    n_high <- sum(sim$sim_t_ballon > p$t_max, na.rm = TRUE)
    pct_t <- round((1 - (n_low + n_high) / n_tot) * 100, 1)
    col_t <- if (pct_t >= 99) cl$success else if (pct_t >= 95) "#f59e0b" else cl$danger

    res_e <- sim$pv_kwh + sim$sim_offtake - sim$conso_hors_pac - sim$sim_pac_on * pac_qt - sim$sim_intake
    if (p$batterie_active && !is.null(sim$batt_flux)) {
      batt_eff <- sqrt(p$batt_rendement)
      res_e <- res_e + pmax(0, -sim$batt_flux) * batt_eff - pmax(0, sim$batt_flux)
    }
    max_e <- round(max(abs(res_e), na.rm = TRUE), 4)
    col_e <- if (max_e < 0.001) cl$success else if (max_e < 0.01) "#f59e0b" else cl$danger

    cap <- p$capacite_kwh_par_degre; k_perte <- 0.004 * p$dt_h; t_amb <- 20
    chaleur <- sim$sim_pac_on * pac_qt * sim$sim_cop
    t_pred <- (lag(sim$sim_t_ballon) * (cap - k_perte) + chaleur + k_perte * t_amb - sim$soutirage_estime_kwh) / cap
    res_th <- sim$sim_t_ballon - t_pred
    max_th <- round(max(abs(res_th), na.rm = TRUE), 3)
    col_th <- if (max_th < 0.01) cl$success else if (max_th < 0.5) "#f59e0b" else cl$danger

    batt_html <- ""
    if (p$batterie_active && !is.null(sim$batt_soc)) {
      n_soc_v <- sum(sim$batt_soc < p$batt_soc_min - 0.001 | sim$batt_soc > p$batt_soc_max + 0.001, na.rm = TRUE)
      n_simult <- sum(pmax(0, sim$batt_flux) > 0.001 & pmax(0, -sim$batt_flux) > 0.001, na.rm = TRUE)
      col_b <- if (n_soc_v + n_simult == 0) cl$success else cl$danger
      batt_html <- sprintf(" &middot; Batt : <b style='color:%s'>%d viol.</b>", col_b, n_soc_v + n_simult)
    }

    tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:.78rem;color:%s;", cl$text_muted),
      HTML(sprintf(
        "T confort : <b style='color:%s'>%s%%</b> (%d+%d qt) &middot; Bilan elec : <b style='color:%s'>%s</b> &middot; Bilan therm : <b style='color:%s'>%s C</b>%s",
        col_t, pct_t, n_low, n_high, col_e, max_e, col_th, max_th, batt_html)))
  })

  # ---- CONTRAINTES : Graphique unique conditionnel ----
  output$plot_cv_main <- renderPlotly({
    req(sim_filtered(), input$cv_check)
    sim <- sim_filtered(); p <- params_r()
    pac_qt <- p$p_pac_kw * p$dt_h
    check <- input$cv_check

    if (check == "marge_temp") {
      d <- sim %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>%
        summarise(t_bal = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h) %>%
        mutate(marge_min = t_bal - p$t_min, marge_max = p$t_max - t_bal)
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~marge_min, type = "scatter", mode = "lines", name = "Marge T_min",
          line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.06)") %>%
        plotly::add_trace(y = ~marge_max, type = "scatter", mode = "lines", name = "Marge T_max",
          line = list(color = "#f59e0b", width = 1), fill = "tozeroy", fillcolor = "rgba(245,158,11,0.06)") %>%
        plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp), y = 0, yend = 0,
          line = list(color = cl$danger, dash = "dash", width = 1), name = "Seuil violation") %>%
        pl_layout(ylab = "Marge (C)")

    } else if (check == "soc_bornes") {
      if (!p$batterie_active || is.null(sim$batt_soc)) return(plotly::plot_ly() %>% pl_layout(title = "Batterie non active"))
      d <- sim %>% mutate(soc_pct = batt_soc * 100)
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~soc_pct, type = "scatter", mode = "lines", name = "SoC",
          line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.08)") %>%
        plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
          y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
          line = list(color = cl$danger, dash = "dash", width = 1), name = "SoC min") %>%
        plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
          y = p$batt_soc_max * 100, yend = p$batt_soc_max * 100,
          line = list(color = "#f59e0b", dash = "dash", width = 1), name = "SoC max") %>%
        pl_layout(ylab = "SoC (%)")

    } else if (check == "simult") {
      if (!p$batterie_active || is.null(sim$batt_flux)) return(plotly::plot_ly() %>% pl_layout(title = "Batterie non active"))
      d <- sim %>% mutate(charge = pmax(0, batt_flux), decharge = pmax(0, -batt_flux),
        simult = pmin(charge, decharge))
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~charge, type = "scatter", mode = "lines", name = "Charge", line = list(color = cl$success, width = 1)) %>%
        plotly::add_trace(y = ~decharge, type = "scatter", mode = "lines", name = "Decharge", line = list(color = cl$reel, width = 1)) %>%
        plotly::add_bars(y = ~simult, name = "Simultanee", marker = list(color = cl$danger)) %>%
        pl_layout(ylab = "kWh/qt")

    } else if (check == "bilan_elec") {
      d <- sim %>% mutate(
        entrees = pv_kwh + sim_offtake,
        sorties = conso_hors_pac + sim_pac_on * pac_qt + sim_intake,
        residu  = entrees - sorties)
      if (p$batterie_active && !is.null(sim$batt_flux)) {
        batt_eff <- sqrt(p$batt_rendement)
        d <- d %>% mutate(entrees = entrees + pmax(0, -batt_flux) * batt_eff,
          sorties = sorties + pmax(0, batt_flux), residu = entrees - sorties)
      }
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% summarise(residu = sum(residu, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_bars(y = ~residu, name = "Residu",
          marker = list(color = ifelse(abs(d_h$residu) > 0.01, cl$danger, cl$success))) %>%
        pl_layout(ylab = "Residu electrique (kWh)")

    } else if (check == "bilan_therm") {
      cap <- p$capacite_kwh_par_degre; k_perte <- 0.004 * p$dt_h; t_amb <- 20
      d <- sim %>% mutate(
        chaleur_pac = sim_pac_on * pac_qt * sim_cop,
        t_predit = (lag(sim_t_ballon) * (cap - k_perte) + chaleur_pac + k_perte * t_amb - soutirage_estime_kwh) / cap,
        ecart = sim_t_ballon - t_predit) %>% filter(!is.na(ecart))
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% summarise(ecart = mean(ecart, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_bars(y = ~ecart, name = "Ecart T",
          marker = list(color = ifelse(abs(d_h$ecart) > 0.5, cl$danger, cl$success))) %>%
        pl_layout(ylab = "Ecart T simule - T predit (C)")

    } else if (check == "conserv_totale") {
      cap <- p$capacite_kwh_par_degre
      d <- sim %>% mutate(
        entrant_cum = cumsum(pv_kwh + sim_offtake),
        sortant_cum = cumsum(sim_intake + conso_hors_pac),
        pac_cum = cumsum(sim_pac_on * pac_qt),
        delta_stock = (sim_t_ballon - sim_t_ballon[1]) * cap,
        residu_cum = entrant_cum - sortant_cum - pac_cum)
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% slice_tail(n = 1) %>% ungroup() %>% rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_trace(y = ~entrant_cum, type = "scatter", mode = "lines", name = "Entrant cumule", line = list(color = cl$success, width = 1.5)) %>%
        plotly::add_trace(y = ~sortant_cum + pac_cum, type = "scatter", mode = "lines", name = "Sortant + PAC cumule", line = list(color = cl$reel, width = 1.5)) %>%
        pl_layout(ylab = "Energie cumulee (kWh)")

    } else if (check == "prix_kwh_th") {
      d <- sim %>% mutate(
        cout_qt = sim_offtake * prix_offtake - sim_intake * prix_injection,
        chaleur_th = sim_pac_on * pac_qt * sim_cop,
        prix_th = ifelse(chaleur_th > 0.01, cout_qt / chaleur_th, NA_real_)) %>%
        filter(!is.na(prix_th), prix_th > -1, prix_th < 2)
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~prix_th, type = "scatter", mode = "markers", name = "Prix kWh_th",
          marker = list(color = cl$opti, size = 3, opacity = 0.5)) %>%
        plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
          y = mean(d$prix_th, na.rm = TRUE), yend = mean(d$prix_th, na.rm = TRUE),
          line = list(color = cl$pv, dash = "dash", width = 1), name = sprintf("Moy: %.3f", mean(d$prix_th, na.rm = TRUE))) %>%
        pl_layout(ylab = "EUR/kWh_th")

    } else if (check == "cout_marginal") {
      d <- sim %>% mutate(
        cout_base_qt = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
        cout_opti_qt = sim_offtake * prix_offtake - sim_intake * prix_injection,
        eco_qt = cout_base_qt - cout_opti_qt)
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% summarise(eco = sum(eco_qt, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_bars(y = ~eco, name = "Economie/h",
          marker = list(color = ifelse(d_h$eco >= 0, cl$success, cl$danger))) %>%
        pl_layout(ylab = "Economie par heure (EUR)")

    } else if (check == "puissance_pac") {
      d <- sim %>% mutate(puissance_kw = sim_pac_on * p$p_pac_kw)
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~puissance_kw, type = "scatter", mode = "lines", name = "Puissance PAC",
          line = list(color = cl$pac, width = 1), fill = "tozeroy", fillcolor = "rgba(52,211,153,0.08)") %>%
        plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
          y = p$p_pac_kw, yend = p$p_pac_kw,
          line = list(color = cl$danger, dash = "dash", width = 1), name = sprintf("P_max = %s kW", p$p_pac_kw)) %>%
        pl_layout(ylab = "Puissance (kW)")

    } else if (check == "dt_dt") {
      d <- sim %>% mutate(
        dt_dt = (sim_t_ballon - lag(sim_t_ballon)) / p$dt_h) %>% filter(!is.na(dt_dt))
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% summarise(dt_dt = mean(dt_dt, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_bars(y = ~dt_dt, name = "dT/dt",
          marker = list(color = ifelse(abs(d_h$dt_dt) > 20, cl$danger, cl$opti))) %>%
        pl_layout(ylab = "Taux de variation T (C/h)")

    } else if (check == "cop_realise") {
      d <- sim %>% mutate(
        cop_theorique = calc_cop(t_ext, p$cop_nominal, p$t_ref_cop, t_ballon = sim_t_ballon),
        ecart_cop = sim_cop - cop_theorique) %>%
        filter(sim_pac_on > 0)
      if (nrow(d) == 0) return(plotly::plot_ly() %>% pl_layout(title = "Aucun qt PAC ON"))
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>% summarise(cop_sim = mean(sim_cop, na.rm = TRUE),
          cop_th = mean(cop_theorique, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_trace(y = ~cop_sim, type = "scatter", mode = "lines", name = "COP simule",
          line = list(color = cl$opti, width = 1.5)) %>%
        plotly::add_trace(y = ~cop_th, type = "scatter", mode = "lines", name = "COP theorique",
          line = list(color = cl$reel, width = 1, dash = "dot")) %>%
        pl_layout(ylab = "COP")

    } else if (check == "autoconso_pv") {
      d <- sim %>% mutate(
        conso_tot_base = conso_hors_pac + ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0),
        conso_tot_opti = conso_hors_pac + sim_pac_on * pac_qt,
        ac_base = pmin(pv_kwh, conso_tot_base),
        ac_opti = pmin(pv_kwh, conso_tot_opti))
      d_h <- d %>% mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        group_by(h) %>%
        summarise(ac_base = sum(ac_base, na.rm = TRUE), ac_opti = sum(ac_opti, na.rm = TRUE),
          pv = sum(pv_kwh, na.rm = TRUE), .groups = "drop") %>%
        rename(timestamp = h)
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_trace(y = ~ac_base, type = "scatter", mode = "lines", name = "Autoconso baseline",
          line = list(color = cl$reel, width = 1), fill = "tozeroy", fillcolor = "rgba(249,115,22,0.06)") %>%
        plotly::add_trace(y = ~ac_opti, type = "scatter", mode = "lines", name = "Autoconso optimise",
          line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.06)") %>%
        plotly::add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV total",
          line = list(color = cl$pv, width = 1, dash = "dot")) %>%
        pl_layout(ylab = "kWh/h")

    } else {
      plotly::plot_ly() %>% pl_layout(title = "Selectionnez une verification")
    }
  })

  # ---- AUTOMAGIC : grid search ----
  automagic_results <- reactiveVal(NULL)

  output$has_automagic <- reactive({ !is.null(automagic_results()) })
  outputOptions(output, "has_automagic", suspendWhenHidden = FALSE)

  observeEvent(input$run_automagic, {
    p <- params_r()
    df_raw <- raw_data()

    pv_range   <- seq(max(1, p$pv_kwc - 3), p$pv_kwc + 3, by = 1)
    batt_range <- c(0, 5, 10, 15, 20)
    modes      <- c("smart", "optimizer", "optimizer_lp", "optimizer_qp")
    contrats   <- c("fixe", "dynamique")

    total <- length(pv_range) * length(batt_range) * length(modes) * length(contrats)

    withProgress(message = "Automagic en cours...", value = 0, {
      resultats <- list()
      k <- 0

      for (ct in contrats) {
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
          ratio <- pv_kwc / p$pv_kwc_ref
          df_prep$pv_kwh <- df_raw$pv_kwh * ratio
          baseline_mode_am <- if (!is.null(input$baseline_type)) input$baseline_type else "reactif"
          df_prep <- run_baseline(df_prep, p_ct, mode = baseline_mode_am)

          for (bkwh in batt_range) {
            p_sim <- p_ct
            p_sim$batterie_active <- bkwh > 0
            p_sim$batt_kwh <- bkwh
            p_sim$batt_kw <- min(bkwh / 2, 5)

            for (m in modes) {
              k <- k + 1
              setProgress(k / total, detail = sprintf("%d/%d -- PV %dkWc Batt %dkWh %s %s",
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

                resultats[[k]] <- tibble::tibble(
                  PV_kWc = pv_kwc, Batterie_kWh = bkwh,
                  Mode = m, Contrat = ct,
                  Cout_EUR = round(cout_net),
                  Autoconso_pct = round(autoconso, 1),
                  Injection_kWh = round(inj_tot),
                  Soutirage_kWh = round(off_tot)
                )
              }, error = function(e) {
                resultats[[k]] <<- tibble::tibble(
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

    all_res <- dplyr::bind_rows(resultats) %>% filter(!is.na(Cout_EUR)) %>% arrange(Cout_EUR)
    automagic_results(all_res)

    bslib::updateNavsetCardTab(session, "main_tabs", selected = "Dimensionnement")
    showNotification(
      sprintf("Automagic termine! %d combinaisons testees. Meilleur cout: %d EUR/an",
              nrow(all_res), all_res$Cout_EUR[1]),
      type = "message", duration = 8)
  })

  output$automagic_best <- renderUI({
    req(automagic_results())
    best <- automagic_results() %>% slice(1)

    tags$div(style = sprintf("background:%s;border-radius:8px;padding:16px;margin-bottom:16px;", cl$bg_input),
      bslib::layout_columns(col_widths = c(2, 2, 2, 2, 2, 2),
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

  output$plot_automagic_heatmap <- renderPlotly({
    req(automagic_results())
    res <- automagic_results()
    best_per_combo <- res %>%
      group_by(PV_kWc, Batterie_kWh) %>%
      slice_min(Cout_EUR, n = 1, with_ties = FALSE) %>%
      ungroup()
    plotly::plot_ly(best_per_combo, x = ~factor(PV_kWc), y = ~factor(Batterie_kWh),
      z = ~Cout_EUR, type = "heatmap",
      text = ~paste0(Cout_EUR, " EUR\n", Mode, " / ", Contrat, "\nAC: ", Autoconso_pct, "%"),
      hoverinfo = "text",
      colorscale = list(c(0, cl$success), c(0.5, cl$pv), c(1, cl$danger)),
      colorbar = list(title = list(text = "EUR/an", font = list(color = cl$text_muted, size = 10)),
        tickfont = list(color = cl$text_muted, size = 9))) %>%
      pl_layout(xlab = "PV installe (kWc)", ylab = "Batterie (kWh)")
  })

  output$table_automagic <- DT::renderDT({
    req(automagic_results())
    res <- automagic_results() %>%
      rename(`PV (kWc)` = PV_kWc, `Batt (kWh)` = Batterie_kWh,
             `Facture (EUR)` = Cout_EUR, `AC (%)` = Autoconso_pct,
             `Inj (kWh)` = Injection_kWh, `Offt (kWh)` = Soutirage_kWh) %>%
      head(30)
    DT::datatable(res, rownames = FALSE,
      options = list(dom = "tip", pageLength = 10, order = list(list(4, "asc"))),
      class = "compact",
      caption = "Top 30 configurations (triees par facture croissante)") %>%
      DT::formatStyle("Facture (EUR)", fontWeight = "bold",
        color = DT::styleInterval(
          quantile(res$`Facture (EUR)`, c(0.33, 0.66), na.rm = TRUE),
          c(cl$success, cl$pv, cl$danger)))
  })

  # ---- Dimensionnement PV ----
  output$plot_dim_pv <- renderPlotly({
    req(sim_result(), input$date_range); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + lubridate::days(1)
    df_base <- res$df %>% filter(timestamp >= d1, timestamp < d2)

    kwc_ref <- p$pv_kwc
    kwc_range <- seq(max(1, kwc_ref - 2), kwc_ref + 2, by = 1)

    scenarii <- dplyr::bind_rows(lapply(kwc_range, function(kwc) {
      p_sc <- p; p_sc$pv_kwc <- kwc; p_sc$pv_kwc_ref <- p$pv_kwc
      df_sc <- df_base %>% mutate(pv_kwh = pv_kwh * kwc / kwc_ref)
      sim_sc <- run_simulation(df_sc, p_sc, "smart", 0.5)
      tibble::tibble(
        kWc = kwc,
        `Injection (kWh)` = round(sum(sim_sc$sim_intake, na.rm = TRUE)),
        `Soutirage (kWh)` = round(sum(sim_sc$sim_offtake, na.rm = TRUE)),
        `Autoconso (%)` = round((1 - sum(sim_sc$sim_intake, na.rm = TRUE) / max(sum(sim_sc$pv_kwh, na.rm = TRUE), 1)) * 100, 1),
        `Facture nette (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))

    is_current <- scenarii$kWc == kwc_ref
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)

    plotly::plot_ly() %>%
      plotly::add_bars(data = scenarii, x = ~factor(kWc), y = ~`Facture nette (EUR)`, name = "Facture nette",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
        textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
      plotly::add_trace(data = scenarii, x = ~factor(kWc), y = ~`Autoconso (%)`, name = "Autoconso %",
        type = "scatter", mode = "lines+markers", yaxis = "y2",
        line = list(color = cl$success, width = 2),
        marker = list(color = cl$success, size = 8)) %>%
      plotly::layout(
        yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
          gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
          titlefont = list(color = cl$success)),
        barmode = "group"
      ) %>%
      pl_layout(xlab = "kWc installe", ylab = "Facture nette (EUR/an)")
  })

  # ---- Dimensionnement batterie ----
  output$plot_dim_batt <- renderPlotly({
    req(sim_result(), input$date_range); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
    if (!p$batterie_active) return(plotly::plot_ly() %>% pl_layout())
    d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
    d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + lubridate::days(1)
    df_base <- res$df %>% filter(timestamp >= d1, timestamp < d2)

    cap_range <- c(0, 5, 10, 15, 20)

    scenarii <- dplyr::bind_rows(lapply(cap_range, function(cap) {
      p_sc <- p
      p_sc$batterie_active <- cap > 0
      p_sc$batt_kwh <- cap
      sim_sc <- run_simulation(df_base, p_sc, "smart", 0.5)
      tibble::tibble(
        `Batterie (kWh)` = cap,
        `Injection (kWh)` = round(sum(sim_sc$sim_intake, na.rm = TRUE)),
        `Soutirage (kWh)` = round(sum(sim_sc$sim_offtake, na.rm = TRUE)),
        `Autoconso (%)` = round((1 - sum(sim_sc$sim_intake, na.rm = TRUE) / max(sum(sim_sc$pv_kwh, na.rm = TRUE), 1)) * 100, 1),
        `Facture nette (EUR)` = round(sum(sim_sc$sim_offtake * sim_sc$prix_offtake - sim_sc$sim_intake * sim_sc$prix_injection, na.rm = TRUE))
      )
    }))

    is_current <- scenarii$`Batterie (kWh)` == p$batt_kwh
    bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)

    plotly::plot_ly() %>%
      plotly::add_bars(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Facture nette (EUR)`, name = "Facture nette",
        marker = list(color = bar_colors, line = list(width = 0)),
        text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
        textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
      plotly::add_trace(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Autoconso (%)`, name = "Autoconso %",
        type = "scatter", mode = "lines+markers", yaxis = "y2",
        line = list(color = cl$success, width = 2),
        marker = list(color = cl$success, size = 8)) %>%
      plotly::layout(
        yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
          gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
          titlefont = list(color = cl$success)),
        barmode = "group"
      ) %>%
      pl_layout(xlab = "Capacite batterie (kWh)", ylab = "Facture nette (EUR/an)")
  })

  # ---- CSV Export ----
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
