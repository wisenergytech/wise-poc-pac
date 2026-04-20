#' The application User-Interface
#'
#' @param request Internal parameter for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_ui <- function(request) {
  # Colors (cl) and helpers (tip, kpi_card, explainer, pac_theme, pl_layout)

  # are loaded from R/fct_ui_theme.R by Golem's R/ sourcing.

  shiny::tagList(
    golem_add_external_resources(),

    bslib::page_fillable(
      theme = pac_theme(),

      # Inline CSS (legacy from app.R -- will be migrated to custom.css in Phase 6)
      shiny::tags$head(shiny::tags$style(shiny::HTML(sprintf("
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

      bslib::layout_sidebar(fillable = TRUE,
        sidebar = bslib::sidebar(width = 300, bg = cl$bg_card,
          shiny::tags$div(style = "padding:8px 0 16px 0;text-align:center;",
            shiny::tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:1.1rem;font-weight:700;color:%s;letter-spacing:.1em", cl$accent), shiny::HTML("&#9889; PAC OPTIMIZER")),
            shiny::tags$div(style = sprintf("font-size:.65rem;color:%s;margin-top:2px;letter-spacing:.15em;text-transform:uppercase", cl$text_muted), "Pilotage predictif")),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Periode", tip("Selectionnez la periode a simuler. Demo : donnees synthetiques. CSV : vos propres donnees.")),
            shiny::radioButtons("data_source", NULL, choices = c("Demo" = "demo", "CSV" = "csv"), selected = "demo", inline = TRUE),
            shiny::conditionalPanel("input.data_source=='csv'", shiny::fileInput("csv_file", NULL, accept = ".csv", buttonLabel = "Parcourir", placeholder = "data.csv")),
            shiny::selectInput("baseline_type", shiny::tags$span("Baseline (votre situation actuelle)", tip("Choisissez le mode de pilotage qui correspond a votre installation actuelle. L'economie affichee sera l'ecart entre cette baseline et l'optimiseur.")),
              choices = c(
                "Thermostat reactif (ON/OFF bete)" = "reactif",
                "Programmateur horaire (11h-15h)" = "programmateur",
                "Surplus PV (chauffe quand surplus)" = "surplus_pv",
                "Ingenieur (max autoconso, sans prix)" = "ingenieur",
                "Thermostat proactif (anticipe)" = "proactif"),
              selected = "ingenieur"),
            shiny::uiOutput("baseline_description"),
            shiny::dateRangeInput("date_range", NULL, start = as.Date("2025-07-01"), end = as.Date("2025-08-31"), language = "fr",
              min = as.Date("2025-01-01"), max = as.Date("2025-12-31")),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
              shiny::HTML("Prix Belpex reels (ENTSO-E) utilises automatiquement.<br>Source : CSV locaux (2024-2025) + API si besoin."))),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Optimisation", tip("Quatre approches : Rule-based (heuristique), MILP (on/off optimal), LP (charge continue lineaire) ou QP (charge continue + confort lisse, via CVXR).")),
            shiny::radioButtons("approche", "Approche", choices = c("Rule-based" = "rulebased", "MILP" = "optimiseur", "LP" = "optimiseur_lp", "QP" = "optimiseur_qp"), selected = "rulebased", inline = TRUE),
            shiny::conditionalPanel("input.approche=='rulebased'",
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
                shiny::HTML("Mode <b>Smart</b> : decision basee sur la valeur nette a chaque quart d'heure. Compare le cout de chauffer maintenant vs plus tard en tenant compte du surplus PV, des prix spot et du COP."))),
            shiny::conditionalPanel("input.approche=='optimiseur'",
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
                shiny::HTML("Resout un probleme MILP (Mixed Integer Linear Programming) : decisions <b>on/off</b> binaires. Trouve la solution optimale bloc par bloc.")),
              shiny::sliderInput("optim_bloc_h", shiny::tags$span("Horizon bloc", tip("Taille du bloc d'optimisation en heures. Plus court = plus rapide mais moins de vision. Plus long = meilleur resultat mais plus lent. 4h est un bon compromis : assez pour voir les tendances de prix et de PV, assez court pour resoudre en <1s.")),
                1, 24, 4, step = 1, post = "h"),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                shiny::HTML("4h = rapide (~1s/bloc) | 12h = equilibre | 24h = optimal mais lent"))),
            shiny::conditionalPanel("input.approche=='optimiseur_lp'",
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
                shiny::HTML("Optimisation <b>LP</b> (lineaire pur) : la PAC module sa puissance en continu (0-100%%). Probleme convexe, resolution rapide, optimum global garanti. Ideal pour PAC inverter.")),
              shiny::sliderInput("optim_bloc_h_lp", shiny::tags$span("Horizon bloc", tip("Taille du bloc en heures. Le LP etant plus rapide que le MILP, des blocs plus grands (12-24h) sont recommandes.")),
                1, 24, 24, step = 1, post = "h"),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                shiny::HTML("LP = rapide, des blocs de 24h sont recommandes"))),
            shiny::conditionalPanel("input.approche=='optimiseur' || input.approche=='optimiseur_lp'",
              shiny::sliderInput("slack_penalty", shiny::tags$span("Penalite T_min (EUR/C)", tip("Cout de violation de T_min par degre par quart d'heure. Plus bas = l'optimiseur explore des temperatures proches de T_min (meilleur COP, plus d'economies). Plus haut = respect strict de T_min. A 2.5 EUR/C, l'optimiseur accepte de descendre legerement sous T_min si le gain economique le justifie.")),
                0.5, 20, 2.5, step = 0.5, post = " EUR/C")),
            shiny::tags$div(style = sprintf("border-top:1px solid %s;padding-top:8px;margin-top:8px;", cl$grid),
              shiny::tags$div(style = sprintf("font-size:.7rem;text-transform:uppercase;letter-spacing:.1em;color:%s;margin-bottom:6px;", cl$text_muted), "Strategies d'optimisation"),
              shiny::tags$div(style = sprintf("font-size:.65rem;color:%s;margin-bottom:6px;", cl$text_muted),
                shiny::HTML("<b>TOU</b> (Time of Use) est toujours actif : l'optimiseur exploite les variations de prix Belpex. Activez le <b>curtailment</b> pour aussi limiter l'injection reseau.")),
              shiny::checkboxInput("curtailment_active", shiny::tags$span("Curtailment (limiter l'injection)", tip("Ajoute une contrainte de puissance maximale d'injection. L'optimiseur decale alors la consommation PAC vers les periodes de surplus PV pour eviter de perdre l'energie ecretee. La baseline n'est PAS affectee -- elle injecte librement. Le gain du curtailment = energie recuperee qui aurait ete perdue.")),
                FALSE),
              shiny::conditionalPanel("input.curtailment_active",
                shiny::numericInput("curtail_kw", "Puissance max injection (kW)", 5, min = 0, max = 100, step = 0.5),
                shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                  "0 kW = zero injection. 5 kW = limite prosumer typique."))),
            shiny::conditionalPanel("input.approche=='optimiseur_qp'",
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
                shiny::HTML("Optimisation <b>QP</b> (quadratique convexe, CVXR) : minimise le cout <i>et</i> penalise les ecarts de temperature a la consigne + les variations brusques de charge PAC. Resultat plus confortable et plus lisse.")),
              shiny::sliderInput("optim_bloc_h_qp", shiny::tags$span("Horizon bloc", tip("Taille du bloc en heures. CVXR gere bien des blocs de 12-24h.")),
                1, 24, 24, step = 1, post = "h"),
              shiny::sliderInput("qp_w_comfort", shiny::tags$span("Poids confort", tip("Penalite sur l'ecart a la consigne. Plus eleve = temperature plus stable autour de la consigne, mais cout potentiellement plus eleve.")),
                0, 1, 0.1, step = 0.01),
              shiny::sliderInput("qp_w_smooth", shiny::tags$span("Poids lissage", tip("Penalite sur les variations brusques de charge PAC. Plus eleve = charge plus lisse, moins de cycling.")),
                0, 1, 0.05, step = 0.01),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                shiny::HTML("Poids a 0 = LP pur. Augmenter pour plus de confort/lissage au detriment du cout.")))),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Pompe a chaleur", tip("Caracteristiques electriques de votre PAC. Le COP varie avec la temperature exterieure ; la valeur nominale est celle a 7C.")),
            shiny::numericInput("p_pac_kw", "Puissance (kW)", 60, min = 0.5, max = 100, step = 0.5),
            shiny::numericInput("cop_nominal", "COP nominal", 3.5, min = 1.5, max = 6, step = 0.1),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "COP = Coefficient de Performance. Un COP de 3.5 signifie que 1 kWh electrique produit 3.5 kWh de chaleur.")),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Ballon thermique", tip("Le ballon sert de batterie thermique. Plus il est gros, plus on peut stocker de chaleur pour decaler la consommation.")),
            shiny::checkboxInput("volume_auto", "Volume auto", value = TRUE),
            shiny::conditionalPanel("input.volume_auto",
              shiny::uiOutput("volume_auto_display"),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;", cl$text_muted),
                shiny::HTML(paste0(
                  "Dimensionne le ballon pour stocker <b>2h de chaleur PAC</b> dans la plage de tolerance. ",
                  "Formule : V = P<sub>PAC</sub> &times; COP &times; 2h / (tolerance &times; 2 &times; 0.001163). ",
                  "Plus le ballon est gros, plus l'optimiseur peut decaler la consommation vers les heures creuses ou le surplus PV. ",
                  "Un ballon trop petit (ratio stockage/puissance faible) limite fortement les economies possibles.")))),
            shiny::conditionalPanel("!input.volume_auto",
              shiny::numericInput("volume_ballon_manual", "Volume (L)", 200, min = 50, max = 100000, step = 50)),
            shiny::numericInput("t_consigne", "Consigne (C)", 50, min = 35, max = 65, step = 1),
            shiny::sliderInput("t_tolerance", "Tolerance +/-C", 1, 10, 5, step = 1),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Plage autorisee = consigne +/- tolerance. L'algo ne laissera jamais la temperature sortir de cette plage."),
            shiny::numericInput("ecs_kwh_jour", shiny::tags$span("ECS (kWh_th/jour)", tip("Demande en eau chaude sanitaire par jour en kWh thermiques. Reference : 6 kWh/jour pour un menage, 50-200 kWh/jour pour un immeuble ou une industrie. Si vide, estime automatiquement a partir de la puissance PAC.")),
              NULL, min = 1, max = 5000, step = 1),
            shiny::conditionalPanel("input.p_pac_kw > 10",
              shiny::selectInput("building_type", shiny::tags$span("Type de batiment", tip("Influence le coefficient de deperdition thermique (G) pour le chauffage d'ambiance. Passif = tres bien isole, Standard = construction recente, Ancien = peu isole.")),
                choices = c("Passif (G faible)" = "passif", "Standard (RT2012)" = "standard", "Ancien (peu isole)" = "ancien"),
                selected = "standard"))),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Tarification", tip("Le type de contrat change fondamentalement la strategie optimale. En dynamique, le prix varie chaque heure selon le marche Belpex.")),
            shiny::radioButtons("type_contrat", "Contrat", choices = c("Dynamique (spot)" = "dynamique", "Fixe" = "fixe"), selected = "dynamique", inline = TRUE),
            shiny::conditionalPanel("input.type_contrat=='fixe'",
              shiny::numericInput("prix_fixe_offtake", "Prix soutirage (EUR/kWh)", 0.30, min = 0, max = 1, step = 0.01),
              shiny::numericInput("prix_fixe_injection", "Prix injection (EUR/kWh)", 0.03, min = -0.05, max = 0.5, step = 0.005),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Prix constants sur toute la periode. En contrat fixe, le mode 'cout' perd son avantage car il n'y a pas de variation de prix a exploiter.")),
            shiny::conditionalPanel("input.type_contrat=='dynamique'",
              shiny::numericInput("taxe_transport", "Taxes reseau (EUR/kWh)", 0.15, min = 0, max = 0.5, step = 0.01),
              shiny::numericInput("coeff_injection", "Coeff. injection / spot", 1.0, min = 0, max = 1.5, step = 0.05),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                "Soutirage = spot + taxes. Injection = spot x coeff. Les prix negatifs signifient que vous PAYEZ pour injecter (surplus renouvelable sur le reseau)."))),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Dimensionnement PV", tip("Simulez l'impact d'une installation PV plus grande ou plus petite. Les donnees sont mises a l'echelle proportionnellement.")),
            shiny::checkboxInput("pv_auto", "PV auto (couvre la PAC)", value = TRUE),
            shiny::conditionalPanel("input.pv_auto",
              shiny::uiOutput("pv_auto_display")),
            shiny::conditionalPanel("!input.pv_auto",
              shiny::sliderInput("pv_kwc_manual", "Puissance crete (kWc)", 1, 200, 6, step = 0.5)),
            shiny::conditionalPanel("input.data_source=='csv'",
              shiny::numericInput("pv_kwc_ref", "kWc reference (donnees CSV)", 6, min = 1, max = 200, step = 0.5),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                "Taille du PV dans vos donnees CSV. Le ratio kWc/ref rescale la production."))),
          shiny::tags$div(class = "sidebar-section",
            shiny::tags$div(class = "section-title", "Batterie", tip("Ajout d'une batterie electrochimique. Elle absorbe le surplus que le ballon ne peut plus stocker et le restitue en soiree.")),
            shiny::checkboxInput("batterie_active", "Activer la batterie", FALSE),
            shiny::conditionalPanel("input.batterie_active",
              shiny::numericInput("batt_kwh", "Capacite (kWh)", 10, min = 1, max = 50, step = 1),
              shiny::numericInput("batt_kw", "Puissance charge/decharge (kW)", 5, min = 0.5, max = 25, step = 0.5),
              shiny::sliderInput("batt_rendement", "Rendement aller-retour (%)", 70, 100, 90, step = 1),
              shiny::sliderInput("batt_soc_range", "Plage SoC (%)", 0, 100, c(10, 90), step = 5),
              shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
                "Rendement = part de l'energie recuperee apres un cycle charge/decharge (pertes thermiques). Plage SoC = limites min/max pour proteger la duree de vie."))),
          shiny::actionButton("run_sim", "Lancer la simulation", class = "btn-primary w-100 mt-2", icon = shiny::icon("play")),
          shiny::conditionalPanel("output.has_sim_result",
            shiny::downloadButton("download_csv", "Exporter CSV", class = "btn-outline-primary w-100 mt-1", icon = shiny::icon("download"))),
          shiny::tags$hr(style = sprintf("border-color:%s;margin:12px 0 8px 0;", cl$grid)),
          shiny::tags$div(style = "margin-top:8px;",
            shiny::actionButton("run_automagic", "Trouver la meilleure config", class = "w-100 mt-1",
              icon = shiny::icon("wand-magic-sparkles"),
              style = sprintf("background:linear-gradient(135deg,%s,%s);border:none;font-family:'JetBrains Mono',monospace;font-size:.78rem;letter-spacing:.05em;color:%s;",
                cl$accent3, "#6366f1", cl$text)),
            shiny::tags$div(class = "form-text text-center mt-1", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
              "Grid search sur toutes les combinaisons")),
          shiny::tags$hr(style = sprintf("border-color:%s;margin:12px 0 8px 0;", cl$grid)),
          shiny::actionButton("show_guide", "Documentation", class = "w-100",
            icon = shiny::icon("book-open"),
            style = sprintf("background:transparent;border:1px solid %s;color:%s;font-family:'JetBrains Mono',monospace;font-size:.78rem;letter-spacing:.05em;",
              cl$grid, cl$text_muted))),

        shiny::uiOutput("status_bar"),

        bslib::navset_card_tab(id = "main_tabs",
          bslib::nav_panel(title = "Energie", icon = shiny::icon("bolt"),
            shiny::uiOutput("energy_kpi_row"),
            bslib::layout_columns(col_widths = c(4, 4, 4),
              bslib::card(full_screen = TRUE, bslib::card_header("Soutirage reseau"),
                bslib::card_body(plotly::plotlyOutput("plot_soutirage", height = "300px"))),
              bslib::card(full_screen = TRUE, bslib::card_header("Injection reseau"),
                bslib::card_body(plotly::plotlyOutput("plot_injection", height = "300px"))),
              bslib::card(full_screen = TRUE, bslib::card_header("Autoconsommation PV"),
                bslib::card_body(plotly::plotlyOutput("plot_autoconso", height = "300px")))),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Flux d'energie"),
                bslib::card_body(
                  shiny::radioButtons("sankey_scenario", NULL, choices = c("Baseline" = "reel", "Optimise" = "optimise"), selected = "reel", inline = TRUE),
                  plotly::plotlyOutput("plot_sankey", height = "350px"))))),
          bslib::nav_panel(title = "Finances", icon = shiny::icon("euro-sign"),
            shiny::uiOutput("finance_kpi_row"),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Facture nette cumulee -- baseline vs optimise"),
                bslib::card_body(plotly::plotlyOutput("plot_cout_cumule", height = "320px")))),
            bslib::layout_columns(col_widths = c(6, 6),
              bslib::card(full_screen = TRUE, bslib::card_header("Decomposition de l'economie"),
                bslib::card_body(plotly::plotlyOutput("plot_waterfall", height = "300px"))),
              bslib::card(full_screen = TRUE, bslib::card_header("Bilan mensuel"),
                bslib::card_body(DT::DTOutput("table_mensuel"))))),
          bslib::nav_panel(title = "Impact CO2", icon = shiny::icon("leaf"),
            bslib::layout_columns(col_widths = 12,
              shiny::uiOutput("co2_kpi_row")),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Impact CO2 horaire -- baseline vs optimise"),
                bslib::card_body(plotly::plotlyOutput("plot_co2_hourly", height = "350px")))),
            bslib::layout_columns(col_widths = c(6, 6),
              bslib::card(full_screen = TRUE, bslib::card_header("CO2 evite cumule"),
                bslib::card_body(plotly::plotlyOutput("plot_co2_cumul", height = "300px"))),
              bslib::card(full_screen = TRUE, bslib::card_header("Heatmap intensite CO2 du reseau"),
                bslib::card_body(plotly::plotlyOutput("plot_co2_heatmap", height = "300px")))),
            bslib::layout_columns(col_widths = 12,
              shiny::tags$div(style = sprintf("font-size:.75rem;color:%s;padding:4px 8px;", cl$text_muted),
                shiny::uiOutput("co2_data_source")))),
          bslib::nav_panel(title = "Details", icon = shiny::icon("magnifying-glass"),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("PAC -- baseline vs optimise (timeline)"),
                bslib::card_body(plotly::plotlyOutput("plot_pac_timeline", height = "350px")))),
            bslib::layout_columns(col_widths = c(6, 6),
              bslib::card(full_screen = TRUE, bslib::card_header("Temperature ballon"),
                bslib::card_body(plotly::plotlyOutput("plot_temperature", height = "280px"))),
              bslib::card(full_screen = TRUE, bslib::card_header("COP journalier"),
                bslib::card_body(plotly::plotlyOutput("plot_cop", height = "280px")))),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Heatmap"),
                bslib::card_body(
                  bslib::layout_columns(col_widths = c(4, 8),
                    shiny::selectInput("heatmap_var", NULL, choices = c(
                      "Moins d'injection" = "inj_evitee", "Surplus PV" = "surplus",
                      "PAC ON (optimise)" = "pac_on", "Temperature ballon" = "t_ballon",
                      "Prix spot" = "prix"), selected = "inj_evitee"),
                    shiny::tags$div()),
                  plotly::plotlyOutput("plot_heatmap", height = "350px")))),
            shiny::conditionalPanel("input.batterie_active",
              bslib::layout_columns(col_widths = 12,
                bslib::card(full_screen = TRUE, bslib::card_header("Batterie -- SoC"),
                  bslib::card_body(plotly::plotlyOutput("plot_batterie", height = "250px")))))),
          bslib::nav_panel(title = "Dimensionnement", icon = shiny::icon("solar-panel"),
            explainer(
              shiny::tags$summary("Comprendre le dimensionnement"),
              shiny::tags$p("Outil d'aide a la decision pour ", shiny::tags$strong("dimensionner votre installation"), "."),
              shiny::tags$ul(
                shiny::tags$li(shiny::tags$strong("Scenarii PV :"), " compare automatiquement votre taille PV actuelle avec +/- 2 kWc. Le graphique montre le cout net annuel (barres) et le taux d'autoconsommation (ligne). Un PV plus grand produit plus mais injecte aussi plus -- le point optimal depend de votre profil."),
                shiny::tags$li(shiny::tags$strong("Scenarii Batterie :"), " compare 5 tailles de batterie (0 a 20 kWh). Une batterie absorbe le surplus que le ballon ne peut plus stocker. Le cout diminue mais le retour sur investissement depend du prix de la batterie (non modelise ici)."),
                shiny::tags$li(shiny::tags$strong("Automagic :"), " teste ", shiny::tags$code("140 combinaisons"), " (7 tailles PV x 5 batteries x 2 modes x 2 contrats) et identifie la meilleure. La heatmap permet de voir les zones de cout optimal et les rendements decroissants.")
              ),
              shiny::tags$p(shiny::tags$strong("Conseil :"), " regardez le tableau des top 30. Parfois la 2e meilleure config coute 5 EUR de plus mais necessite une batterie beaucoup plus petite -- ce qui peut etre plus rentable vu le cout d'achat.")),
            shiny::conditionalPanel("output.has_automagic",
              bslib::layout_columns(col_widths = 12,
                bslib::card(full_screen = TRUE, bslib::card_header(shiny::HTML("&#10024; Resultat Automagic -- meilleure configuration")),
                  bslib::card_body(
                    shiny::uiOutput("automagic_best"),
                    plotly::plotlyOutput("plot_automagic_heatmap", height = "350px"),
                    DT::DTOutput("table_automagic"))))),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Scenarii PV -- impact du dimensionnement"),
                bslib::card_body(
                  shiny::tags$div(class = "form-text mb-2", style = sprintf("color:%s;font-size:.8rem;", cl$text_muted),
                    "Compare automatiquement le scenario actuel avec +/- 2 kWc par pas de 1 kWc."),
                  plotly::plotlyOutput("plot_dim_pv", height = "350px")))),
            shiny::conditionalPanel("input.batterie_active",
              bslib::layout_columns(col_widths = 12,
                bslib::card(full_screen = TRUE, bslib::card_header("Scenarii Batterie -- impact de la capacite"),
                  bslib::card_body(plotly::plotlyOutput("plot_dim_batt", height = "350px")))))),
          bslib::nav_panel(title = "Comparaison", icon = shiny::icon("right-left"),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE, bslib::card_header("Comparer 2 ou 3 series temporelles"),
                bslib::card_body(
                  bslib::layout_columns(col_widths = c(3, 3, 3, 3),
                    shiny::selectInput("compare_var1", "Serie 1 (axe gauche)",
                      choices = NULL, selected = NULL),
                    shiny::selectInput("compare_var2", "Serie 2 (axe droit)",
                      choices = NULL, selected = NULL),
                    shiny::selectInput("compare_var3", "Serie 3 (optionnelle)",
                      choices = NULL, selected = NULL),
                    shiny::dateRangeInput("compare_range", "Zoom periode",
                      start = Sys.Date() - 7, end = Sys.Date(), language = "fr")),
                  plotly::plotlyOutput("plot_compare", height = "480px"))))),
          bslib::nav_panel(title = "Contraintes", icon = shiny::icon("check-circle"),
            bslib::layout_columns(col_widths = 12,
              bslib::card(bslib::card_body(shiny::uiOutput("cv_scorecard")))),
            bslib::layout_columns(col_widths = 12,
              bslib::card(full_screen = TRUE,
                bslib::card_header(
                  bslib::layout_columns(col_widths = c(6, 6),
                    shiny::selectInput("cv_check", NULL, choices = list(
                      "Contraintes" = c(
                        "Marge temperature vs bornes" = "marge_temp",
                        "SOC batterie vs bornes" = "soc_bornes",
                        "Charge/decharge simultanees" = "simult"),
                      "Conservation (smoke tests)" = c(
                        "Bilan electrique (residu)" = "bilan_elec",
                        "Bilan thermique (residu)" = "bilan_therm",
                        "Conservation energie totale" = "conserv_totale"),
                      "Qualite optimisation" = c(
                        "Prix effectif kWh thermique" = "prix_kwh_th",
                        "Cout marginal baseline vs opti" = "cout_marginal"),
                      "Validite physique" = c(
                        "Puissance PAC vs capacite" = "puissance_pac",
                        "Taux de variation T (dT/dt)" = "dt_dt",
                        "COP realise vs theorique" = "cop_realise",
                        "Autoconsommation PV" = "autoconso_pv")
                    ), selected = "bilan_elec"),
                    shiny::tags$div())),
                bslib::card_body(plotly::plotlyOutput("plot_cv_main", height = "400px"))))) # fin navset_card_tab
        ) # fin navset_card_tab
      ) # fin layout_sidebar
    ) # fin page_fillable
  ) # fin tagList
}

#' Add external Resources to the Application
#'
#' This function is internally used to allow you to add external
#' resources inside the Shiny application.
#'
#' @noRd
golem_add_external_resources <- function() {
  golem::add_resource_path("www", app_sys("app/www"))

  shiny::tags$head(
    golem::favicon(),
    shiny::tags$link(rel = "stylesheet", type = "text/css", href = "www/custom.css")
  )
}
