#' Sidebar Module UI
#'
#' Contains all parameter inputs: data source, baseline type, optimization
#' approach, PAC, ballon, tarification, PV, curtailment, batterie, and
#' the run/automagic/doc buttons.
#'
#' @param id module id
#' @noRd
mod_sidebar_ui <- function(id) {
  ns <- shiny::NS(id)
  ui_cfg <- get_ui_config()

  shiny::tagList(
    shiny::tags$div(style = "padding:8px 0 16px 0;text-align:center;",
      shiny::tags$img(src = "www/logo-wise.svg", style = "width:120px;margin-bottom:8px;"),
      shiny::tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:1.1rem;font-weight:700;color:%s;letter-spacing:.1em", cl$accent), shiny::HTML("&#9889; PAC OPTIMIZER")),
      shiny::tags$div(style = sprintf("font-size:.65rem;color:%s;margin-top:2px;letter-spacing:.15em;text-transform:uppercase", cl$text_muted), "Pilotage predictif")),

    # ---- Data source ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Source de donn\u00e9es", tip("Mode Demo : donnees synthetiques generees automatiquement. Mode CSV : importez vos propres mesures (compteur + PAC + PV).")),
      shiny::radioButtons(ns("data_source"), NULL, choices = c("Demo" = "demo", "CSV" = "csv"), selected = "demo", inline = TRUE),
      shiny::conditionalPanel(sprintf("input['%s']=='csv'", ns("data_source")),
        shiny::fileInput(ns("csv_file"), NULL, accept = ".csv", buttonLabel = "Parcourir", placeholder = "data.csv"),
        shiny::downloadButton(ns("download_template"), "T\u00e9l\u00e9charger le template CSV", class = "btn-outline-secondary btn-sm w-100 mb-2"),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.4;", cl$text_muted),
          shiny::HTML(paste0(
            "<b>Colonnes requises :</b><br>",
            "<code>timestamp</code> &mdash; horodatage ISO 8601 (pas de 15 min)<br>",
            "<code>pv_kwh</code> &mdash; production PV mesur\u00e9e (onduleur)<br>",
            "<code>pac_kwh</code> &mdash; conso \u00e9lectrique PAC (sous-compteur)<br>",
            "<code>offtake_kwh</code> &mdash; soutirage r\u00e9seau (compteur)<br>",
            "<code>feedin_kwh</code> &mdash; injection r\u00e9seau (compteur)<br>",
            "<br><b>Optionnelles :</b> <code>t_ext</code> (\u00b0C ext\u00e9rieure)<br>",
            "<br>La colonne <code>pac_kwh</code> permet de d\u00e9duire exactement la consommation hors PAC ",
            "(<code>conso_hors_pac = offtake + pv - injection - pac</code>). ",
            "Sans elle, l'app <b>estime</b> la r\u00e9partition (moins pr\u00e9cis).")))),
    shiny::tags$div(style = "display:none;",
      shiny::selectInput(ns("baseline_type"), NULL,
        choices = c("parametric", "reactif", "programmateur", "surplus_pv", "ingenieur", "proactif"),
        selected = "parametric")),

    # ---- PAC ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Pompe a chaleur", tip("Caracteristiques electriques de votre PAC. Le COP varie avec la temperature exterieure ; la valeur nominale est celle a 7C.")),
      shiny::numericInput(ns("p_pac_kw"), "Puissance (kW)", 60, min = 0.5, max = 100, step = 0.5),
      shiny::numericInput(ns("cop_nominal"), "COP nominal", 3.5, min = 1.5, max = 6, step = 0.1),
      shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "COP = Coefficient de Performance. Un COP de 3.5 signifie que 1 kWh electrique produit 3.5 kWh de chaleur.")),

    # ---- Ballon ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Ballon thermique", tip("Le ballon sert de batterie thermique. Plus il est gros, plus on peut stocker de chaleur pour decaler la consommation.")),
      shiny::checkboxInput(ns("volume_auto"), "Volume auto", value = TRUE),
      shiny::conditionalPanel(sprintf("input['%s']", ns("volume_auto")),
        shiny::uiOutput(ns("volume_auto_display")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;", cl$text_muted),
          shiny::HTML(paste0(
            "Dimensionne le ballon pour stocker <b>2h de chaleur PAC</b> dans la plage de tolerance. ",
            "Formule : V = P<sub>PAC</sub> &times; COP &times; 2h / (tolerance &times; 2 &times; 0.001163). ",
            "Plus le ballon est gros, plus l'optimiseur peut decaler la consommation vers les heures creuses ou le surplus PV. ",
            "Un ballon trop petit (ratio stockage/puissance faible) limite fortement les economies possibles.")))),
      shiny::conditionalPanel(sprintf("!input['%s']", ns("volume_auto")),
        shiny::numericInput(ns("volume_ballon_manual"), "Volume (L)", 200, min = 50, max = 100000, step = 50)),
      shiny::numericInput(ns("t_consigne"), "Consigne (C)", 50, min = 35, max = 65, step = 1),
      shiny::sliderInput(ns("t_tolerance"), "Tolerance +/-C", 1, 10, 5, step = 1),
      shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Plage autorisee = consigne +/- tolerance. L'algo ne laissera jamais la temperature sortir de cette plage."),
      shiny::numericInput(ns("ecs_kwh_jour"), shiny::tags$span("ECS (kWh_th/jour)", tip("Demande en eau chaude sanitaire par jour en kWh thermiques. Reference : 6 kWh/jour pour un menage, 50-200 kWh/jour pour un immeuble ou une industrie. Si vide, estime automatiquement a partir de la puissance PAC.")),
        NULL, min = 1, max = 5000, step = 1),
      shiny::conditionalPanel(sprintf("input['%s'] > 10", ns("p_pac_kw")),
        shiny::selectInput(ns("building_type"), shiny::tags$span("Type de batiment", tip("Influence le coefficient de deperdition thermique (G) pour le chauffage d'ambiance. Passif = tres bien isole, Standard = construction recente, Ancien = peu isole.")),
          choices = c("Passif (G faible)" = "passif", "Standard (RT2012)" = "standard", "Ancien (peu isole)" = "ancien"),
          selected = "standard"))),

    # ---- Tarification ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Tarification", tip("Le type de contrat change fondamentalement la strategie optimale. En dynamique, le prix varie chaque heure selon le marche Belpex.")),
      shiny::radioButtons(ns("type_contrat"), "Contrat", choices = c("Dynamique (spot)" = "dynamique", "Fixe" = "fixe"), selected = "dynamique", inline = TRUE),
      shiny::conditionalPanel(sprintf("input['%s']=='fixe'", ns("type_contrat")),
        shiny::numericInput(ns("prix_fixe_offtake"), "Prix soutirage (EUR/kWh)", 0.30, min = 0, max = 1, step = 0.01),
        shiny::numericInput(ns("prix_fixe_injection"), "Prix injection (EUR/kWh)", 0.03, min = -0.05, max = 0.5, step = 0.005),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted), "Prix constants sur toute la periode. En contrat fixe, le mode 'cout' perd son avantage car il n'y a pas de variation de prix a exploiter.")),
      shiny::conditionalPanel(sprintf("input['%s']=='dynamique'", ns("type_contrat")),
        shiny::numericInput(ns("taxe_transport"), "Taxes reseau (EUR/kWh)", 0.15, min = 0, max = 0.5, step = 0.01),
        shiny::numericInput(ns("coeff_injection"), "Coeff. injection / spot", 1.0, min = 0, max = 1.5, step = 0.05),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          "Soutirage = spot + taxes. Injection = spot x coeff. Les prix negatifs signifient que vous PAYEZ pour injecter (surplus renouvelable sur le reseau)."))),

    # ---- PV ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Dimensionnement PV", tip("Simulez l'impact d'une installation PV plus grande ou plus petite. Les donnees sont mises a l'echelle proportionnellement.")),
      {
        all_pv <- c("Synth\u00e9tique" = "synthetic",
                     "R\u00e9el Elia (Namur)" = "real_elia",
                     "R\u00e9el Delaunoy (2024)" = "real_delaunoy")
        pv_choices <- all_pv[all_pv %in% ui_cfg$pv_sources]
        pv_selected <- if (ui_cfg$pv_sources[1] %in% pv_choices) ui_cfg$pv_sources[1] else pv_choices[1]
        shiny::radioButtons(ns("pv_data_source"), "Source PV",
          choices = pv_choices, selected = pv_selected, inline = FALSE)
      },
      shiny::conditionalPanel(sprintf("input['%s']=='real_elia'", ns("pv_data_source")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;margin-bottom:6px;", cl$text_muted),
          shiny::HTML("Production PV r\u00e9elle du parc namurois (Elia ODS032), mise \u00e0 l'\u00e9chelle selon votre kWc."))),
      shiny::conditionalPanel(sprintf("input['%s']=='real_delaunoy'", ns("pv_data_source")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;margin-bottom:6px;", cl$text_muted),
          shiny::HTML("Donn\u00e9es mesur\u00e9es d'une installation r\u00e9elle en Wallonie (16 kWc, 2024), mises \u00e0 l'\u00e9chelle selon votre kWc."))),
      shiny::checkboxInput(ns("pv_auto"), "PV auto (couvre la PAC)", value = TRUE),
      shiny::conditionalPanel(sprintf("input['%s']", ns("pv_auto")),
        shiny::uiOutput(ns("pv_auto_display"))),
      shiny::conditionalPanel(sprintf("!input['%s']", ns("pv_auto")),
        shiny::sliderInput(ns("pv_kwc_manual"), "Puissance crete (kWc)", 1, 200, 6, step = 0.5)),
      shiny::conditionalPanel(sprintf("input['%s']=='csv'", ns("data_source")),
        shiny::numericInput(ns("pv_kwc_ref"), "kWc reference (donnees CSV)", 6, min = 1, max = 200, step = 0.5),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          "Taille du PV dans vos donnees CSV. Le ratio kWc/ref rescale la production."))),

    # ---- Baseline ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Baseline", tip("Scenario de reference sans EMS. Par defaut : thermostat pur (aquastat ON/OFF). Activez le suivi PV si l'installation a deja un pilotage basique du surplus.")),
      shiny::checkboxInput(ns("pv_tracking"), "Suivi PV existant (avance)", value = FALSE),
      shiny::conditionalPanel(sprintf("input['%s']", ns("pv_tracking")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:8px;", cl$text_muted),
          shiny::HTML("Simule deux baselines (alpha=0 et alpha=1) sur les donn\u00e9es r\u00e9elles pour d\u00e9terminer la plage d'autoconsommation atteignable. Cliquez ci-dessous apr\u00e8s avoir configur\u00e9 vos param\u00e8tres.")),
        shiny::actionButton(ns("calibrate_ac"), "Calibrer les bornes", class = "btn-outline-secondary btn-sm w-100",
          icon = shiny::icon("crosshairs")),
        shiny::uiOutput(ns("autoconso_panel_calibrated"))),
      shiny::conditionalPanel(sprintf("!input['%s']", ns("pv_tracking")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;", cl$text_muted),
          shiny::HTML("Thermostat pur : la PAC s'allume quand T<sub>ballon</sub> &lt; T<sub>min</sub> et s'arrete a T<sub>consigne</sub>. Aucune conscience du PV ni des prix.")))),

    # ---- Batterie (conditionnel via config) ----
    if (isTRUE(ui_cfg$show_battery)) shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Batterie", tip("Ajout d'une batterie electrochimique. Elle absorbe le surplus que le ballon ne peut plus stocker et le restitue en soiree.")),
      shiny::checkboxInput(ns("batterie_active"), "Activer la batterie", FALSE),
      shiny::conditionalPanel(sprintf("input['%s']", ns("batterie_active")),
        shiny::numericInput(ns("batt_kwh"), "Capacite (kWh)", 10, min = 1, max = 50, step = 1),
        shiny::numericInput(ns("batt_kw"), "Puissance charge/decharge (kW)", 5, min = 0.5, max = 25, step = 0.5),
        shiny::sliderInput(ns("batt_rendement"), "Rendement aller-retour (%)", 70, 100, 90, step = 1),
        shiny::sliderInput(ns("batt_soc_range"), "Plage SoC (%)", 0, 100, c(10, 90), step = 5),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          "Rendement = part de l'energie recuperee apres un cycle charge/decharge (pertes thermiques). Plage SoC = limites min/max pour proteger la duree de vie."))),

    # ---- Optimisation ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Optimisation", tip("Choisissez l'approche de resolution et les strategies d'optimisation a activer.")),
      {
        all_optim <- c("MILP" = "optimiseur", "LP" = "optimiseur_lp", "QP" = "optimiseur_qp")
        optim_choices <- all_optim[all_optim %in% ui_cfg$optimizers]
        optim_selected <- if (ui_cfg$optimizers[1] %in% optim_choices) ui_cfg$optimizers[1] else optim_choices[1]
        shiny::radioButtons(ns("approche"), "Approche", choices = optim_choices, selected = optim_selected, inline = TRUE)
      },
      shiny::conditionalPanel(sprintf("input['%s']=='optimiseur'", ns("approche")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
          shiny::HTML("<b>MILP</b> : la PAC est soit allumee soit eteinte (on/off). L'optimiseur planifie les creneaux ou la PAC chauffe le ballon pour minimiser le cout total, en respectant les limites de temperature du ballon.")),
        shiny::sliderInput(ns("optim_bloc_h"), shiny::tags$span("Horizon bloc", tip("Nombre d'heures que l'optimiseur voit en avance pour planifier les cycles de la PAC. 4h : il anticipe les prix et le PV sur 4h, rapide a calculer. 24h : il planifie la journee complete (pre-chauffe le ballon quand le PV est fort, evite la pointe du soir), mais plus lent.")),
          1, 24, 4, step = 1, post = "h"),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          shiny::HTML("4h = rapide (~1s/bloc) | 12h = equilibre | 24h = optimal mais lent"))),
      shiny::conditionalPanel(sprintf("input['%s']=='optimiseur_lp'", ns("approche")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
          shiny::HTML("<b>LP</b> : la PAC module sa puissance en continu (0-100%%). L'optimiseur choisit a chaque quart d'heure le niveau de charge optimal du ballon en fonction des prix, du PV et du COP. Ideal pour les PAC inverter qui modulant naturellement.")),
        shiny::sliderInput(ns("optim_bloc_h_lp"), shiny::tags$span("Horizon bloc", tip("Nombre d'heures que l'optimiseur voit en avance. Le LP etant rapide, on peut planifier sur 24h : il anticipe le surplus PV de l'apres-midi pour eviter de chauffer le ballon le matin au prix fort.")),
          1, 24, 24, step = 1, post = "h"),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          shiny::HTML("LP = rapide, des blocs de 24h sont recommandes"))),
      shiny::conditionalPanel(sprintf("input['%s']=='optimiseur' || input['%s']=='optimiseur_lp'", ns("approche"), ns("approche")),
        shiny::sliderInput(ns("slack_penalty"), shiny::tags$span("Penalite T_min (EUR/C)", tip("Cout fictif par degre sous T_min du ballon. Plus bas : l'optimiseur laisse le ballon refroidir pres de T_min (meilleur COP car moins d'ecart avec l'exterieur, plus d'economies). Plus haut : la PAC maintient le ballon au-dessus de T_min strictement. A 2.5 EUR/C : bon compromis entre economies et confort.")),
          0.5, 20, 2.5, step = 0.5, post = " EUR/C")),
      shiny::conditionalPanel(sprintf("input['%s']=='optimiseur_qp'", ns("approche")),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:6px;", cl$text_muted),
          shiny::HTML("<b>QP</b> : comme le LP, la PAC module en continu, mais l'optimiseur penalise aussi les ecarts de temperature du ballon par rapport a la consigne et les variations brusques de puissance PAC. Le ballon reste plus stable, la PAC cycle moins.")),
        shiny::sliderInput(ns("optim_bloc_h_qp"), shiny::tags$span("Horizon bloc", tip("Nombre d'heures que l'optimiseur voit en avance pour planifier la charge du ballon. 12-24h recommande : il peut anticiper le surplus PV et les prix de la journee pour lisser le profil de charge de la PAC.")),
          1, 24, 24, step = 1, post = "h"),
        shiny::sliderInput(ns("qp_w_comfort"), shiny::tags$span("Poids confort", tip("Penalite sur l'ecart entre la temperature du ballon et la consigne. Plus eleve : le ballon reste proche de la consigne (plus de confort ECS), mais la PAC tourne plus souvent.")),
          0, 1, 0.1, step = 0.01),
        shiny::sliderInput(ns("qp_w_smooth"), shiny::tags$span("Poids lissage", tip("Penalite sur les changements brusques de puissance PAC d'un quart d'heure a l'autre. Plus eleve : la PAC monte et descend progressivement (moins de cycling, moins d'usure). A 0 : la PAC peut passer de 0 a 100%% instantanement.")),
          0, 1, 0.05, step = 0.01),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
          shiny::HTML("Poids a 0 = LP pur. Augmenter pour plus de confort/lissage au detriment du cout."))),
      shiny::tags$div(style = sprintf("border-top:1px solid %s;padding-top:8px;margin-top:8px;", cl$grid),
        shiny::tags$div(style = sprintf("font-size:.7rem;text-transform:uppercase;letter-spacing:.1em;color:%s;margin-bottom:6px;", cl$text_muted), "Strategies d'optimisation"),
        if (isTRUE(ui_cfg$strategies$tou)) shiny::tagList(
          shiny::checkboxInput(ns("tou_active"), shiny::tags$span("TOU (Time of Use)", tip("Exploite les variations de prix Belpex pour decaler la consommation PAC vers les heures les moins cheres. Desactivez pour optimiser uniquement l'autoconsommation PV, sans tenir compte des prix.")),
            TRUE),
          shiny::conditionalPanel(sprintf("input['%s']", ns("tou_active")),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;margin-bottom:6px;", cl$text_muted),
              shiny::HTML("L'optimiseur exploite les variations de prix Belpex pour minimiser le cout."))),
          shiny::conditionalPanel(sprintf("!input['%s']", ns("tou_active")),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;margin-bottom:6px;", cl$text_muted),
              shiny::HTML("Prix aplatis : l'optimiseur maximise l'autoconsommation PV sans signal prix.")))),
        if (isTRUE(ui_cfg$strategies$curtailment)) shiny::tagList(
          shiny::checkboxInput(ns("curtailment_active"), shiny::tags$span("Curtailment (limiter l'injection)", tip("Ajoute une contrainte de puissance maximale d'injection. L'optimiseur decale alors la consommation PAC vers les periodes de surplus PV pour eviter de perdre l'energie ecretee. La baseline n'est PAS affectee -- elle injecte librement. Le gain du curtailment = energie recuperee qui aurait ete perdue.")),
            FALSE),
          shiny::conditionalPanel(sprintf("input['%s']", ns("curtailment_active")),
            shiny::numericInput(ns("curtail_kw"), "Puissance max injection (kW)", 5, min = 0, max = 100, step = 0.5),
            shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
              "0 kW = zero injection. 5 kW = limite prosumer typique."))))),

    # ---- Periode ----
    shiny::tags$div(class = "sidebar-section",
      shiny::tags$div(class = "section-title", "Periode", tip("Selectionnez la periode a simuler. En mode PV reel, la periode est contrainte a 2024.")),
      shiny::dateRangeInput(ns("date_range"), NULL, start = Sys.Date() - 60, end = Sys.Date() - 5, language = "fr",
        min = as.Date("2020-01-01"), max = Sys.Date()),
      shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
        shiny::HTML("Prix Belpex reels (ENTSO-E) utilises automatiquement.<br>Source : CSV locaux + API si besoin."))),

    # ---- Buttons ----
    shiny::actionButton(ns("run_sim"), "Lancer la simulation", class = "btn-primary w-100 mt-2", icon = shiny::icon("play")),
    shiny::conditionalPanel(sprintf("output['%s']", ns("has_sim_result")),
      ns = function(x) x,
      shiny::downloadButton(ns("download_csv"), "Exporter CSV", class = "btn-outline-primary w-100 mt-1", icon = shiny::icon("download"))),
    # Automagic button (masque temporairement)
    # shiny::tags$hr(style = sprintf("border-color:%s;margin:12px 0 8px 0;", cl$grid)),
    # shiny::tags$div(style = "margin-top:8px;",
    #   shiny::actionButton(ns("run_automagic"), "Trouver la meilleure config", class = "w-100 mt-1",
    #     icon = shiny::icon("wand-magic-sparkles"),
    #     style = sprintf("background:linear-gradient(135deg,%s,%s);border:none;font-family:'JetBrains Mono',monospace;font-size:.78rem;letter-spacing:.05em;color:%s;",
    #       cl$accent2, cl$accent, cl$text_light)),
    #   shiny::tags$div(class = "form-text text-center mt-1", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
    #     "Grid search sur toutes les combinaisons")),
  )
}

#' Sidebar Module Server
#'
#' Handles parameter reactives, volume/PV auto-sizing, raw data loading,
#' simulation execution, and writes results to sim_state.
#'
#' @param id module id
#' @param sim_state reactiveVal to write simulation results to
#' @return A list of reactives: params_r, raw_data, sim_result, sim_running,
#'   volume_ballon_eff, pv_kwc_eff, sim_filtered, automagic_results, and
#'   a reactive for each relevant input.
#' @noRd
mod_sidebar_server <- function(id, sim_state) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # ---- AC bounds computation (triggered by button click only) ----
    ac_bounds <- shiny::reactiveVal(NULL)
    ac_bounds_stale <- shiny::reactiveVal(FALSE)

    # Track params that affect bounds — mark stale when they change
    shiny::observe({
      # Touch all inputs that affect ac_bounds
      input$p_pac_kw; input$cop_nominal; input$t_consigne; input$t_tolerance
      input$pv_data_source; input$date_range; input$type_contrat
      volume_ballon_eff(); pv_kwc_eff()
      # Only mark stale if bounds were previously calibrated
      if (!is.null(shiny::isolate(ac_bounds()))) {
        ac_bounds_stale(TRUE)
      }
    })

    shiny::observeEvent(input$calibrate_ac, {
      vol <- volume_ballon_eff()
      kwc <- pv_kwc_eff()
      p_base <- list(
        t_consigne = input$t_consigne, t_tolerance = input$t_tolerance,
        t_min = input$t_consigne - input$t_tolerance,
        t_max = input$t_consigne + input$t_tolerance,
        p_pac_kw = input$p_pac_kw, cop_nominal = input$cop_nominal, t_ref_cop = 7,
        volume_ballon_l = vol, capacite_kwh_par_degre = vol * 0.001163,
        dt_h = 0.25, pv_kwc = kwc,
        pv_kwc_ref = if (input$data_source == "csv") input$pv_kwc_ref else kwc,
        perte_kwh_par_qt = 0.05,
        horizon_qt = 16, seuil_surplus_pct = 0.3,
        type_contrat = input$type_contrat,
        taxe_transport_eur_kwh = ifelse(input$type_contrat == "dynamique", input$taxe_transport, 0),
        coeff_injection = ifelse(input$type_contrat == "dynamique", input$coeff_injection, 1),
        prix_fixe_offtake = ifelse(input$type_contrat == "fixe", input$prix_fixe_offtake, 0.30),
        prix_fixe_injection = ifelse(input$type_contrat == "fixe", input$prix_fixe_injection, 0.03),
        batterie_active = FALSE, batt_kwh = 0, batt_kw = 0,
        batt_rendement = 0.9, batt_soc_min = 0.1, batt_soc_max = 0.9,
        curtailment_active = FALSE, curtail_kwh_per_qt = Inf,
        slack_penalty = 2.5, optim_bloc_h = 4, poids_cout = 0.5,
        qp_w_comfort = 0.001, qp_w_smooth = 0.01
      )

      shiny::withProgress(message = "Calibrage des bornes AC...", value = 0.3, {
        df <- raw_data()
        shiny::setProgress(0.6, detail = "Simulation baseline alpha=0/1...")
        bounds <- compute_ac_bounds(df, p_base)
        shiny::setProgress(1, detail = "Termine!")
      })

      ac_bounds(bounds)
      ac_bounds_stale(FALSE)
    }, ignoreInit = TRUE)

    # ---- Baseline alpha from AC target ----
    baseline_alpha <- shiny::reactive({
      bounds <- ac_bounds()  # reactiveVal, NULL until calibrated
      target <- input$autoconso_cible
      if (is.null(bounds) || is.null(target)) return(0.5)
      span <- bounds$ac_ceiling - bounds$ac_floor
      if (span < 1) return(0.5)
      clamped <- max(bounds$ac_floor, min(bounds$ac_ceiling, target))
      alpha <- (clamped - bounds$ac_floor) / span
      max(0, min(1, alpha))
    })

    # ---- Update date range when PV data source changes ----
    shiny::observeEvent(input$pv_data_source, {
      if (input$pv_data_source == "real_delaunoy") {
        shiny::updateDateRangeInput(session, "date_range",
          min = as.Date("2024-01-01"), max = as.Date("2024-12-31"),
          start = as.Date("2024-06-01"), end = as.Date("2024-09-30"))
      } else if (input$pv_data_source == "real_elia") {
        shiny::updateDateRangeInput(session, "date_range",
          min = as.Date("2020-04-01"), max = Sys.Date(),
          start = Sys.Date() - 60, end = Sys.Date() - 5)
      } else {
        shiny::updateDateRangeInput(session, "date_range",
          min = as.Date("2020-01-01"), max = Sys.Date(),
          start = Sys.Date() - 60, end = Sys.Date() - 5)
      }
    }, ignoreInit = TRUE)

    # ---- Autoconso: update slider + show info after calibration ----
    output$autoconso_panel_calibrated <- shiny::renderUI({
      bounds <- ac_bounds()
      stale <- ac_bounds_stale()
      current <- input$autoconso_cible
      ns <- session$ns

      # Not yet calibrated
      if (is.null(bounds)) {
        return(shiny::tags$div(style = "margin-top:8px;",
          shiny::sliderInput(ns("autoconso_cible"),
            shiny::tags$span("Autoconsommation actuelle (%)", tip("Estimez le taux d'autoconsommation de votre installation actuelle. Le simulateur construira une baseline avec suivi PV correspondant.")),
            min = 10, max = 90, value = 35, step = 5, post = "%"),
          shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;", cl$text_muted),
            "Cliquez sur \"Calibrer les bornes\" pour ajuster la plage.")))
      }

      # No PV case
      if (bounds$ac_ceiling < 1 && bounds$ac_floor < 1) {
        return(shiny::tags$div(style = "margin-top:8px;",
          shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;", cl$text_muted),
            shiny::HTML("Sans PV, la baseline est un thermostat pur. L'autoconsommation est nulle."))))
      }

      # Calibrated: show slider with proper bounds
      new_min <- floor(bounds$ac_floor)
      new_max <- ceiling(bounds$ac_ceiling)
      if (new_max <= new_min) new_max <- new_min + 1
      if (is.null(current)) current <- round((new_min + new_max) / 2)
      new_val <- max(new_min, min(new_max, current))

      span <- bounds$ac_ceiling - bounds$ac_floor
      alpha <- if (span < 1) 0.5 else max(0, min(1, (new_val - bounds$ac_floor) / span))
      qual <- if (alpha < 0.2) {
        list(txt = "Thermostat aveugle", col = cl$success, marge = "maximale")
      } else if (alpha < 0.45) {
        list(txt = "Pilotage leger", col = "#f59e0b", marge = "elevee")
      } else if (alpha < 0.7) {
        list(txt = "Bon suivi PV", col = "#f59e0b", marge = "moderee")
      } else {
        list(txt = "Suivi PV intensif", col = cl$reel, marge = "faible -- gains = valeur du Belpex")
      }

      stale_warning <- if (stale) {
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;font-weight:600;margin-bottom:4px;", cl$danger),
          shiny::HTML("&#9888; Param\u00e8tres modifi\u00e9s depuis le dernier calibrage &mdash; recalibrez pour mettre \u00e0 jour."))
      } else NULL

      shiny::tags$div(style = "margin-top:8px;",
        stale_warning,
        shiny::sliderInput(ns("autoconso_cible"),
          shiny::tags$span("Autoconsommation actuelle (%)", tip("Estimez le taux d'autoconsommation de votre installation actuelle. Le simulateur construira une baseline avec suivi PV correspondant.")),
          min = new_min, max = new_max, value = new_val, step = 5, post = "%"),
        shiny::tags$div(class = "form-text", style = sprintf("font-size:.65rem;color:%s;line-height:1.3;margin-bottom:4px;", cl$text_muted),
          shiny::HTML(sprintf(
            "Plage atteignable : <b>%d%%</b> &ndash; <b>%d%%</b><br><span style='color:%s;font-weight:600;'>%s (AC ~%d%%)</span> &middot; Marge d'optimisation : <b>%s</b>",
            round(bounds$ac_floor), round(bounds$ac_ceiling),
            qual$col, qual$txt, round(new_val),
            qual$marge))))
    })

    # ---- Volume ballon auto/manual ----
    volume_ballon_eff <- shiny::reactive({
      if (isTRUE(input$volume_auto)) {
        calculate_ballon_volume_auto(input$p_pac_kw, input$cop_nominal, input$t_tolerance)
      } else {
        input$volume_ballon_manual
      }
    })

    output$volume_auto_display <- shiny::renderUI({
      vol <- volume_ballon_eff()
      p_kw <- input$p_pac_kw; cop <- input$cop_nominal; tol <- input$t_tolerance
      delta_t <- 2 * tol
      cap_kwh <- vol * 0.001163 * delta_t
      cap_elec <- round(cap_kwh / cop, 1)
      heures_flex <- round(cap_kwh / (p_kw * cop), 1)
      shiny::tags$div(style = sprintf("font-size:.85rem;color:%s;padding:4px 8px;background:%s;border-radius:4px;margin-bottom:6px;",
        cl$opti, cl$bg_input),
        shiny::HTML(sprintf("<b>%s L</b> &middot; stockage <b>%s kWh<sub>th</sub></b> (%s kWh<sub>e</sub>) &middot; <b>%sh</b> de flexibilite",
          formatC(vol, format = "d", big.mark = " "), round(cap_kwh, 1), cap_elec, heures_flex)))
    })
    shiny::outputOptions(output, "volume_auto_display", suspendWhenHidden = FALSE)

    # ---- PV auto ----
    pv_kwc_eff <- shiny::reactive({
      if (isTRUE(input$pv_auto)) {
        calculate_pv_auto(input$p_pac_kw, volume_ballon_eff(),
                          input$cop_nominal, input$t_consigne)
      } else {
        input$pv_kwc_manual
      }
    })

    output$pv_auto_display <- shiny::renderUI({
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
      shiny::tags$div(style = sprintf("font-size:.85rem;color:%s;padding:4px 8px;background:%s;border-radius:4px;margin-bottom:6px;",
        cl$opti, cl$bg_input),
        shiny::HTML(sprintf("<b>%.1f kWc</b> (%d kWh/an &mdash; %s)", kwc, conso, detail)))
    })
    shiny::outputOptions(output, "pv_auto_display", suspendWhenHidden = FALSE)

    # ---- params_r ----
    params_r <- shiny::reactive({
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
        pv_data_source = input$pv_data_source,
        batterie_active = if (!is.null(input$batterie_active)) input$batterie_active else FALSE,
        batt_kwh = if (!is.null(input$batt_kwh)) input$batt_kwh else 0,
        batt_kw = if (!is.null(input$batt_kw)) input$batt_kw else 0,
        batt_rendement = if (!is.null(input$batt_rendement)) input$batt_rendement / 100 else 0.9,
        batt_soc_min = if (!is.null(input$batt_soc_range)) input$batt_soc_range[1] / 100 else 0.1,
        batt_soc_max = if (!is.null(input$batt_soc_range)) input$batt_soc_range[2] / 100 else 0.9,
        autoconso_cible = if (!is.null(input$autoconso_cible)) input$autoconso_cible else 35,
        poids_cout = 0.5,
        slack_penalty = if (!is.null(input$slack_penalty)) input$slack_penalty else 2.5,
        curtailment_active = if (!is.null(input$curtailment_active)) isTRUE(input$curtailment_active) else FALSE,
        curtail_kwh_per_qt = if (!is.null(input$curtailment_active) && isTRUE(input$curtailment_active)) input$curtail_kw * 0.25 else Inf,
        optim_bloc_h = if (!is.null(input$optim_bloc_h)) input$optim_bloc_h else 4)
    })

    # ---- raw_data ----
    # Compute raw_data from current inputs. Also triggers once at boot
    # via the observe below (ignoreInit = FALSE on input$date_range).
    compute_raw_data <- function() {
      if (input$data_source == "csv") {
        shiny::req(input$csv_file)
        df <- readr::read_csv(input$csv_file$datapath, show_col_types = FALSE) %>% dplyr::mutate(timestamp = lubridate::ymd_hms(timestamp))

        # Validate required columns
        required <- c("timestamp", "pv_kwh", "offtake_kwh")
        feedin_col <- if ("feedin_kwh" %in% names(df)) "feedin_kwh" else "intake_kwh"
        required <- c(required, feedin_col)
        missing <- setdiff(required, names(df))
        if (length(missing) > 0) {
          shiny::showNotification(
            sprintf("Colonnes manquantes dans le CSV : %s", paste(missing, collapse = ", ")),
            type = "error", duration = 10)
          shiny::req(FALSE)
        }

        if ("pac_kwh" %in% names(df)) {
          shiny::showNotification("Colonne pac_kwh d\u00e9tect\u00e9e : conso hors PAC sera calcul\u00e9e exactement", type = "message", duration = 5)
        } else {
          shiny::showNotification("Pas de colonne pac_kwh : la r\u00e9partition PAC/autre sera estim\u00e9e (moins pr\u00e9cis)", type = "warning", duration = 8)
        }

        # Fetch external temperature if not in CSV
        if (!"t_ext" %in% names(df)) {
          dp <- DataProvider$new()
          t_ext_meteo <- tryCatch({
            df_temp <- dp$get_temperature(min(as.Date(df$timestamp)), max(as.Date(df$timestamp)))
            if (!is.null(df_temp) && nrow(df_temp) > 0) {
              dp$interpolate_temperature(df_temp, df$timestamp)
            } else NULL
          }, error = function(e) NULL)
          if (!is.null(t_ext_meteo)) {
            df$t_ext <- t_ext_meteo
            message("[CSV] Temperatures Open-Meteo injectees")
          } else {
            df$t_ext <- 10
            shiny::showNotification("Temp\u00e9ratures ext\u00e9rieures indisponibles, valeur par d\u00e9faut (10\u00b0C)", type = "warning", duration = 5)
          }
        }
      } else {
        shiny::req(input$date_range)
        gen <- DataGenerator$new()
        pv_src <- input$pv_data_source
        delaunoy_path <- "../delaunoy/data/inverters_data_delaunoy.xlsx"
        if (!is.null(pv_src) && pv_src == "real_delaunoy" && !file.exists(delaunoy_path)) {
          shiny::showNotification("Fichier Delaunoy introuvable \u2014 donn\u00e9es synth\u00e9tiques utilis\u00e9es", type = "warning", duration = 8)
          pv_src <- "synthetic"
        }
        df <- gen$generate_demo(
          date_start = input$date_range[1], date_end = input$date_range[2],
          p_pac_kw = input$p_pac_kw, volume_ballon_l = volume_ballon_eff(),
          pv_kwc = pv_kwc_eff(),
          ecs_kwh_jour = input$ecs_kwh_jour,
          building_type = if (!is.null(input$building_type)) input$building_type else "standard",
          pv_data_source = if (!is.null(pv_src)) pv_src else "synthetic",
          delaunoy_file_path = if (!is.null(pv_src) && pv_src == "real_delaunoy") delaunoy_path else NULL,
          solar_region = "Namur")
      }

      # Inject real Belpex prices (CSV only)
      if (input$data_source == "csv") {
        api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
        df_with_belpex <- inject_belpex_prices(df, api_key = api_key, data_dir = "data")
        n_matched <- sum(!is.na(df_with_belpex$prix_eur_kwh) & df_with_belpex$prix_eur_kwh != 0)
        if (n_matched > 0) {
          message(sprintf("[Belpex] %d/%d quarts d'heure avec prix reels", n_matched, nrow(df)))
          df <- df_with_belpex
        } else {
          shiny::showNotification("Prix Belpex indisponibles, prix synthetiques utilises", type = "warning", duration = 5)
        }
      }
      df
    }

    raw_data <- shiny::reactive({ compute_raw_data() })

    # Trigger raw_data computation at boot (once inputs are initialized)
    boot_done <- shiny::reactiveVal(FALSE)
    shiny::observe({
      shiny::req(input$date_range, !boot_done())
      message("[Boot] Pre-computing raw_data with default inputs...")
      raw_data()
      boot_done(TRUE)
      message("[Boot] raw_data ready.")
    })

    # ---- Simulation ----
    sim_running <- shiny::reactiveVal(FALSE)
    shiny::observeEvent(input$run_sim, { sim_running(TRUE) }, ignoreInit = TRUE)

    sim_result <- shiny::eventReactive(input$run_sim, {
      on.exit(sim_running(FALSE), add = TRUE)
      p <- params_r(); df <- raw_data()
      p$tou_active <- isTRUE(input$tou_active)
      approche <- input$approche

      # Baseline mode: thermostat (default) or pv_tracking (advanced)
      baseline_mode_r <- if (isTRUE(input$pv_tracking)) {
        p$baseline_alpha <- baseline_alpha()
        "pv_tracking"
      } else {
        "thermostat"
      }

      # Flatten prices when TOU is disabled
      if (!isTRUE(input$tou_active) && "prix_eur_kwh" %in% names(df)) {
        df$prix_eur_kwh <- mean(df$prix_eur_kwh, na.rm = TRUE)
      }

      # Map sidebar approche to R6 optimization mode
      r6_mode <- switch(approche,
        optimiseur = "milp", optimiseur_lp = "lp", optimiseur_qp = "qp",
        "lp")

      # Set mode-specific params
      if (approche == "optimiseur_lp") p$optim_bloc_h <- input$optim_bloc_h_lp
      if (approche == "optimiseur_qp") {
        p$optim_bloc_h <- input$optim_bloc_h_qp
        p$qp_w_comfort <- input$qp_w_comfort
        p$qp_w_smooth <- input$qp_w_smooth
      }

      shiny::withProgress(message = "Preparation...", value = 0.1, {
        bl_detail <- if (baseline_mode_r == "pv_tracking") {
          sprintf("Baseline PV tracking (AC %d%%)...", input$autoconso_cible %||% 35)
        } else {
          "Baseline thermostat..."
        }
        shiny::setProgress(0.2, detail = bl_detail)
        shiny::setProgress(0.3, detail = sprintf("Optimisation %s en cours...", toupper(r6_mode)))

        result <- run_simulation(df, p, mode = r6_mode,
                                 baseline_mode = baseline_mode_r)

        shiny::setProgress(1, detail = "Termine!")
        list(sim = result$sim, candidats = NULL, modes = NULL,
             df = result$df, params = result$params, mode = result$mode)
      })
    })

    # Log results and update date range
    shiny::observeEvent(sim_result(), {
      res <- sim_result()
      sim <- res$sim
      p <- res$params
      mode <- res$mode
      k <- KPICalculator$new()$compute(sim, sim, p)
      cr <- k$facture_baseline
      co <- k$facture_opti
      jours <- round(k$n_days, 1)
      thermostat <- if (isTRUE(input$pv_tracking)) {
        sprintf("pv_tracking(AC=%d%%)", input$autoconso_cible %||% 35)
      } else {
        "thermostat"
      }
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
      shiny::updateDateRangeInput(session, "date_range",
        start = as.Date(min(sim$timestamp)), end = as.Date(max(sim$timestamp)))
    })

    # ---- sim_filtered ----
    sim_filtered <- shiny::reactive({
      shiny::req(sim_result(), input$date_range)
      sim <- sim_result()$sim
      d1 <- as.POSIXct(input$date_range[1], tz = "Europe/Brussels")
      d2 <- as.POSIXct(input$date_range[2], tz = "Europe/Brussels") + lubridate::days(1)
      sim %>% dplyr::filter(timestamp >= d1, timestamp < d2)
    })

    # ---- Shared KPIs (computed once, consumed by all modules) ----
    kpis_r <- shiny::reactive({
      shiny::req(sim_filtered())
      sim <- sim_filtered(); p <- params_r()
      KPICalculator$new()$compute(sim, sim, p)
    })

    # ---- Automagic ----
    automagic_results <- shiny::reactiveVal(NULL)

    shiny::observeEvent(input$run_automagic, {
      p <- params_r()
      p$baseline_alpha <- baseline_alpha()
      df_raw <- raw_data()

      # Flatten prices when TOU is disabled
      if (!isTRUE(input$tou_active) && "prix_eur_kwh" %in% names(df_raw)) {
        df_raw$prix_eur_kwh <- mean(df_raw$prix_eur_kwh, na.rm = TRUE)
      }

      pv_range   <- seq(max(1, p$pv_kwc - 3), p$pv_kwc + 3, by = 1)
      batt_range <- c(0, 5, 10, 15, 20)

      shiny::withProgress(message = "Automagic en cours...", value = 0, {
        all_res <- run_grid_search(
          df_raw, p,
          pv_range = pv_range, batt_range = batt_range,
          progress_fn = function(k, total, detail) {
            shiny::setProgress(k / total, detail = detail)
          }
        )
        automagic_results(all_res)
      })

      shiny::showNotification(
        sprintf("Automagic termine! %d combinaisons testees. Meilleur cout: %d EUR/an",
                nrow(automagic_results()), automagic_results()$Cout_EUR[1]),
        type = "message", duration = 8)
    })

    # ---- Sim result flag for conditionalPanel ----
    output$has_sim_result <- shiny::reactive({ !is.null(tryCatch(sim_result(), error = function(e) NULL)) })
    shiny::outputOptions(output, "has_sim_result", suspendWhenHidden = FALSE)

    # ---- CSV Template Download ----
    output$download_template <- shiny::downloadHandler(
      filename = function() "pac_optimizer_template.csv",
      content = function(file) {
        template_path <- system.file("csv_template.csv", package = "wisepocpac")
        if (template_path == "") {
          template_path <- file.path("inst", "csv_template.csv")
        }
        file.copy(template_path, file)
      }
    )

    # ---- CSV Export ----
    output$download_csv <- shiny::downloadHandler(
      filename = function() {
        paste0("pac_optimizer_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv")
      },
      content = function(file) {
        shiny::req(sim_filtered())
        sim <- sim_filtered()
        export_cols <- c("timestamp", "t_ext", "pv_kwh", "prix_offtake", "prix_injection",
          "conso_hors_pac", "soutirage_estime_kwh")
        if ("pac_kwh" %in% names(sim)) export_cols <- c(export_cols, "pac_kwh")
        export <- sim %>% dplyr::select(
          dplyr::all_of(export_cols),
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

    # Return reactives for consumption by other modules
    list(
      params_r = params_r,
      raw_data = raw_data,
      sim_result = sim_result,
      sim_running = sim_running,
      sim_filtered = sim_filtered,
      kpis_r = kpis_r,
      volume_ballon_eff = volume_ballon_eff,
      pv_kwc_eff = pv_kwc_eff,
      automagic_results = automagic_results,
      autoconso_cible = shiny::reactive(input$autoconso_cible),
      pv_tracking = shiny::reactive(input$pv_tracking),
      baseline_alpha = baseline_alpha,
      ac_bounds = ac_bounds,
      # Expose individual inputs needed by other modules/status bar
      date_range = shiny::reactive(input$date_range),
      data_source = shiny::reactive(input$data_source),
      pv_data_source = shiny::reactive(input$pv_data_source),
      baseline_type = shiny::reactive(input$baseline_type),
      approche = shiny::reactive(input$approche),
      optim_bloc_h = shiny::reactive(input$optim_bloc_h),
      optim_bloc_h_lp = shiny::reactive(input$optim_bloc_h_lp),
      optim_bloc_h_qp = shiny::reactive(input$optim_bloc_h_qp),
      slack_penalty = shiny::reactive(input$slack_penalty),
      tou_active = shiny::reactive(if (!is.null(input$tou_active)) input$tou_active else TRUE),
      curtailment_active = shiny::reactive(if (!is.null(input$curtailment_active)) input$curtailment_active else FALSE),
      curtail_kw = shiny::reactive(if (!is.null(input$curtail_kw)) input$curtail_kw else 5),
      batterie_active = shiny::reactive(input$batterie_active),
      run_automagic = shiny::reactive(input$run_automagic),
      apply_best = shiny::reactive(input$apply_best),
      # Expose session for tab switching etc.
      session = session,
      parent_session = session
    )
  })
}
