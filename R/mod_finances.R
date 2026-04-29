#' Finances Tab Module UI
#'
#' Contains finance KPIs, cumulative bill chart, waterfall decomposition,
#' and monthly billing table.
#'
#' @param id module id
#' @noRd
mod_finances_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("finance_kpi_row")),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Facture nette cumulee -- baseline vs optimise",
          "Evolution de la facture nette cumulee (soutirage - injection) au fil du temps. L'ecart entre les deux courbes represente l'economie cumulee a chaque instant."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_cout_cumule"), height = "320px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("Conso PAC par tranche horaire",
          "Repartition de la consommation PAC par tranche horaire (nuit, solaire, pointe soir, transition). Compare baseline vs optimise. Le prix spot moyen est annote par tranche."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_pac_tranches"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Decomposition de l'economie",
          "Cascade partant de la facture reelle (sans optimisation) jusqu'a la facture optimisee. Chaque barre intermediaire montre une composante de l'economie : reduction du soutirage, perte d'injection, et arbitrage horaire."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_waterfall"), height = "300px")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Bilan mensuel",
          "Recapitulatif mois par mois : production PV, factures baseline et optimisee, economie en EUR et en EUR/jour."),
        bslib::card_body(DT::DTOutput(ns("table_mensuel")))))
  )
}

#' Finances Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_finances_server <- function(id, sidebar) {
  moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered

    # ---- Helper: format contract label ----
    label_contrat <- function(p) {
      if (p$type_contrat == "belix") {
        "BELIX"
      } else if (p$type_contrat == "fixe") {
        "Fixe"
      } else {
        "Dynamique"
      }
    }

    # ---- KPIs ----
    output$finance_kpi_row <- shiny::renderUI({
      shiny::req(sidebar$kpis_r())
      k <- sidebar$kpis_r()
      k_cible <- sidebar$kpis_cible_r()
      has_cible <- !is.null(k_cible)

      if (has_cible) {
        # ---- DUAL CONTRACT MODE ----
        p_actuel <- sidebar$params_r()
        res <- sidebar$sim_result()
        p_cible <- res$params_cible
        lbl_actuel <- label_contrat(p_actuel)
        lbl_cible <- label_contrat(p_cible)

        fa <- k$facture_baseline        # A: baseline actuel
        fb <- k$facture_opti            # B: optimise actuel
        fd <- k_cible$facture_opti      # D: optimise cible
        levier1 <- fa - fb              # gain pilotage seul
        levier2 <- fb - fd              # gain changement contrat (les 2 pilotes)
        gain_total <- fa - fd           # gain total
        pct_total <- if (abs(fa) > 0.001) gain_total / abs(fa) * 100 else 0

        col_fn <- function(g) if (g > 0) cl$success else if (g < 0) cl$danger else cl$text_muted
        pct1 <- if (abs(fa) > 0.001) round(levier1 / abs(fa) * 100, 1) else 0
        pct2 <- if (abs(fa) > 0.001) round(levier2 / abs(fa) * 100, 1) else 0

        # -- Row 1: Decomposition (4 cards) --
        # All % are relative to situation actuelle (fa) so they are additive
        row1 <- list(
          kpi_card(paste0(formatC(round(fa), big.mark = " ", format = "d"), " EUR"),
            "Situation actuelle", "", cl$reel,
            tooltip = sprintf("Votre facture actuelle en contrat %s, sans pilotage intelligent. C'est le point de depart : ce que vous payez aujourd'hui.", lbl_actuel)),
          kpi_card(paste0(formatC(round(levier1), big.mark = " ", format = "d"), " EUR"),
            "Levier 1 : Pilotage", "", cl$opti,
            baseline_val = fa, opti_val = fa - levier1, gain_invert = TRUE,
            tooltip = sprintf("%d EUR = facture actuelle (%d) - facture %s pilotee (%d). Soit %.1f%% de votre facture actuelle. Le pilotage intelligent chauffe aux moments les plus avantageux, sans changer de contrat.",
              round(levier1), round(fa), lbl_actuel, round(fb), pct1)),
          kpi_card(paste0(formatC(round(levier2), big.mark = " ", format = "d"), " EUR"),
            "Levier 2 : + Contrat", "", cl$accent3,
            baseline_val = fa, opti_val = fa - levier2, gain_invert = TRUE,
            tooltip = sprintf("%d EUR = facture %s pilotee (%d) - facture %s pilotee (%d). Soit %.1f%% de votre facture actuelle. Les deux scenarios sont pilotes, seul le contrat change.",
              round(levier2), lbl_actuel, round(fb), lbl_cible, round(fd), pct2)),
          kpi_card(paste0(formatC(round(fd), big.mark = " ", format = "d"), " EUR"),
            "Resultat final", "", col_fn(gain_total),
            baseline_val = fa, opti_val = fd, gain_invert = TRUE,
            gain_val = round(fd - fa), gain_unit = "EUR",
            tooltip = sprintf("Votre facture avec contrat %s + pilotage intelligent : %d EUR. Economie totale : %d EUR (%.1f%%) = levier 1 (%d) + levier 2 (%d).",
              lbl_cible, round(fd), round(gain_total), pct_total, round(levier1), round(levier2)))
        )

        row1_div <- do.call(shiny::tags$div, c(
          list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:8px;"),
          lapply(row1, function(k) shiny::tags$div(style = "flex:1;", k))
        ))

        # -- Row 2: Detail du resultat final (vs situation actuelle A) --
        prix_pac_a <- if (!is.null(k$prix_kwh_pac_baseline) && !is.na(k$prix_kwh_pac_baseline)) {
          round(k$prix_kwh_pac_baseline * 100, 1)
        } else NA
        prix_pac_d <- if (!is.null(k_cible$prix_kwh_pac_opti) && !is.na(k_cible$prix_kwh_pac_opti)) {
          round(k_cible$prix_kwh_pac_opti * 100, 1)
        } else NA

        row2 <- list(
          kpi_card(paste0(formatC(round(k_cible$cout_soutirage_opti), big.mark = " ", format = "d"), " EUR"),
            "Cout soutirage", "", cl$accent3,
            baseline_val = k$cout_soutirage_baseline, opti_val = k_cible$cout_soutirage_opti, gain_invert = TRUE,
            gain_val = round(k_cible$cout_soutirage_opti - k$cout_soutirage_baseline), gain_unit = "EUR",
            tooltip = sprintf("Cout de l'electricite achetee au reseau. Compare le contrat %s pilote a votre situation actuelle (%s).", lbl_cible, lbl_actuel)),
          kpi_card(paste0(formatC(round(k_cible$rev_injection_opti), big.mark = " ", format = "d"), " EUR"),
            "Revenu injection", "", cl$pv,
            baseline_val = k$rev_injection_baseline, opti_val = k_cible$rev_injection_opti,
            gain_val = round(k_cible$rev_injection_opti - k$rev_injection_baseline), gain_unit = "EUR",
            tooltip = sprintf("Revenu de l'electricite revendue au reseau. En contrat %s, le prix d'injection peut differer du %s.", lbl_cible, lbl_actuel)),
          if (!is.na(prix_pac_d)) {
            kpi_card(paste0(prix_pac_d, " c/kWh"),
              "Prix moyen kWh PAC", "", cl$pac,
              baseline_val = prix_pac_a, opti_val = prix_pac_d, gain_invert = TRUE,
              gain_val = if (!is.na(prix_pac_a)) round(prix_pac_d - prix_pac_a, 1) else NULL,
              gain_unit = "c/kWh",
              tooltip = sprintf("Prix effectif moyen du kWh consomme par la PAC (kWh PV comptes a 0). En %s pilote, la PAC profite des creux de prix et du PV gratuit.", lbl_cible))
          }
        )
        row2 <- Filter(Negate(is.null), row2)

        row2_div <- do.call(shiny::tags$div, c(
          list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
          lapply(row2, function(k) shiny::tags$div(style = "flex:1;", k))
        ))

        shiny::tagList(row1_div, row2_div)

      } else {
        # ---- SINGLE CONTRACT MODE (unchanged) ----
        prix_pac_bl <- if (!is.null(k$prix_kwh_pac_baseline) && !is.na(k$prix_kwh_pac_baseline)) {
          round(k$prix_kwh_pac_baseline * 100, 1)
        } else NA
        prix_pac_op <- if (!is.null(k$prix_kwh_pac_opti) && !is.na(k$prix_kwh_pac_opti)) {
          round(k$prix_kwh_pac_opti * 100, 1)
        } else NA

        kpis <- list(
          kpi_card(paste0(round(k$facture_opti), " EUR"),
            "Facture nette", "", cl$opti,
            baseline_val = k$facture_baseline, opti_val = k$facture_opti, gain_invert = TRUE,
            gain_val = round(k$facture_opti - k$facture_baseline), gain_unit = "EUR",
            tooltip = "Cout net (soutirage - injection). Baseline vs optimise."),
          kpi_card(paste0(round(k$cout_soutirage_opti), " EUR"),
            "Cout soutirage", "", cl$accent3,
            baseline_val = k$cout_soutirage_baseline, opti_val = k$cout_soutirage_opti, gain_invert = TRUE,
            gain_val = round(k$cout_soutirage_opti - k$cout_soutirage_baseline), gain_unit = "EUR",
            tooltip = "Cout de l'electricite soutiree du reseau."),
          kpi_card(paste0(round(k$rev_injection_opti), " EUR"),
            "Revenu injection", "", cl$pv,
            baseline_val = k$rev_injection_baseline, opti_val = k$rev_injection_opti,
            gain_val = round(k$rev_injection_opti - k$rev_injection_baseline), gain_unit = "EUR",
            tooltip = "Revenu de l'electricite injectee dans le reseau."),
          if (!is.na(prix_pac_op)) {
            kpi_card(paste0(prix_pac_op, " c/kWh"),
              "Prix moyen kWh PAC", "", cl$pac,
              baseline_val = prix_pac_bl, opti_val = prix_pac_op, gain_invert = TRUE,
              gain_val = if (!is.na(prix_pac_bl)) round(prix_pac_op - prix_pac_bl, 1) else NULL,
              gain_unit = "c/kWh",
              tooltip = "Prix effectif moyen du kWh consomme par la PAC (kWh PV comptes a 0). Baseline: PAC sans pilotage. Optimise: PAC pilotee par l'EMS.")
          }
        )
        kpis <- Filter(Negate(is.null), kpis)
        do.call(shiny::tags$div, c(
          list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
          lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
        ))
      }
    })

    # ---- Cumulative bill ----
    output$plot_cout_cumule <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      if (!is.null(sim_c)) {
        # Cross-contract: baseline from current contract (A), optimised from target (D)
        d <- compute_cumulative_bill(sim_filtered(), sim_opti = sim_c)
        plot_cumulative(d, ylab = "Facture nette cumulee (EUR)", unit = "EUR",
          baseline_label = "Facture actuelle", opti_label = "Facture optimisee",
          delta_label = "Economie totale cumulee")
      } else {
        d <- compute_cumulative_bill(sim_filtered())
        plot_cumulative(d, ylab = "Facture nette cumulee (EUR)", unit = "EUR",
          baseline_label = "Facture baseline", opti_label = "Facture optimisee",
          delta_label = "Economie cumulee")
      }
    })

    # ---- PAC par tranche horaire ----
    output$plot_pac_tranches <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      # Use target contract sim if available
      sim_c <- sidebar$sim_filtered_cible()
      sim <- if (!is.null(sim_c)) sim_c else sim_filtered()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r

      kpi <- KPICalculator$new()
      bl <- kpi$get_pac_par_tranche(sim, params, "baseline")
      op <- kpi$get_pac_par_tranche(sim, params, "optimized")

      bl$scenario <- "Baseline"
      op$scenario <- "Optimise"
      tranche_data <- rbind(bl, op)

      plot_pac_tranches(tranche_data)
    })

    # ---- Waterfall ----
    output$plot_waterfall <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      sim <- if (!is.null(sim_c)) sim_c else sim_filtered()
      wf <- compute_waterfall(sim)

      plotly::plot_ly(
        x = ~label, y = ~value, data = wf,
        type = "waterfall",
        measure = ~measure,
        text = paste0(round(wf$value, 1), " EUR"),
        textposition = "outside",
        textfont = list(color = cl$text, size = 10, family = "JetBrains Mono"),
        customdata = ~detail,
        hovertemplate = paste0(
          "<b>%{x}</b><br>",
          "%{text}<br>",
          "<i>%{customdata}</i>",
          "<extra></extra>"),
        connector = list(line = list(color = cl$text_muted, width = 2, dash = "dot")),
        increasing = list(marker = list(color = "#d62728")),
        decreasing = list(marker = list(color = "#2ca02c")),
        totals = list(marker = list(color = "#1f77b4"))
      ) %>%
        pl_layout(ylab = "EUR") %>%
        plotly::layout(
          xaxis = list(
            tickfont = list(size = 10),
            categoryorder = "array",
            categoryarray = wf$label
          )
        )
    })

    # ---- Monthly table ----
    output$table_mensuel <- DT::renderDT({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      cross <- !is.null(sim_c)

      m <- if (cross) {
        compute_monthly_summary(sim_filtered(), sim_opti = sim_c)
      } else {
        compute_monthly_summary(sim_filtered())
      }

      # Custom header with tooltips — labels adapt to cross-contract mode
      tip_style <- "cursor:help;border-bottom:1px dotted;text-decoration:none;"

      if (cross) {
        bl_label <- "Facture actuelle"
        bl_tip <- "Votre facture actuelle avec votre contrat en place, sans pilotage intelligent (EUR)"
        op_label <- "Facture optimisee"
        op_tip <- "Facture avec le nouveau contrat + pilotage intelligent. Combine les deux leviers : meilleur contrat et chauffage aux meilleurs moments (EUR)"
        eco_tip <- "Economie totale : difference entre votre facture actuelle et la facture optimisee avec le nouveau contrat. Combine le gain du pilotage et du changement de contrat (EUR)"
      } else {
        bl_label <- "Facture baseline"
        bl_tip <- "Facture nette sans pilotage intelligent : cout du soutirage reseau moins revenu d'injection (EUR)"
        op_label <- "Facture opti"
        op_tip <- "Facture nette avec pilotage intelligent : la PAC chauffe aux moments les plus avantageux (EUR)"
        eco_tip <- "Difference entre facture baseline et optimisee. Positif = vous economisez (EUR)"
      }

      header <- htmltools::withTags(table(
        class = "display",
        thead(tr(
          th(shiny::tags$span(style = tip_style, title = "Mois de la periode simulee", "Mois")),
          th(shiny::tags$span(style = tip_style, title = "Production photovoltaique totale du mois (kWh)", "PV")),
          th(shiny::tags$span(style = tip_style, title = bl_tip, bl_label)),
          th(shiny::tags$span(style = tip_style, title = op_tip, op_label)),
          th(shiny::tags$span(style = tip_style, title = eco_tip, "Economie")),
          th(shiny::tags$span(style = tip_style, title = "Economie moyenne par jour sur ce mois. Utile pour comparer des mois de durees differentes (EUR/jour)", "EUR/j"))
        ))
      ))

      DT::datatable(m, rownames = FALSE, container = header,
        options = list(dom = "t", pageLength = 13), class = "compact") %>%
        DT::formatStyle("Economie", color = DT::styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
    })
  })
}
