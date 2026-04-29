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

    # ---- KPIs ----
    output$finance_kpi_row <- shiny::renderUI({
      shiny::req(sidebar$kpis_r())
      k <- sidebar$kpis_r()

      # Format PAC price in c€/kWh
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
            tooltip = "Prix moyen pondere du kWh consomme par la PAC. Baseline: PAC sans pilotage. Optimise: PAC pilotee par l'EMS.")
        }
      )
      kpis <- Filter(Negate(is.null), kpis)
      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Cumulative bill ----
    output$plot_cout_cumule <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      d <- compute_cumulative_bill(sim_filtered())
      plot_cumulative(d, ylab = "Facture nette cumulee (EUR)", unit = "EUR",
        baseline_label = "Facture baseline", opti_label = "Facture optimisee",
        delta_label = "Economie cumulee")
    })

    # ---- PAC par tranche horaire ----
    output$plot_pac_tranches <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim <- sim_filtered()
      p_r <- sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r

      kpi <- KPICalculator$new()
      bl <- kpi$get_pac_par_tranche(sim, params, "baseline")
      op <- kpi$get_pac_par_tranche(sim, params, "optimized")

      bl$scenario <- "Baseline"
      op$scenario <- "Optimise"
      df <- rbind(bl, op)

      bl_rgba <- paste0("rgba(",
        paste(grDevices::col2rgb(cl$reel), collapse = ","), ",",
        cl$scenarios$baseline$bar_opacity, ")")
      op_rgba <- paste0("rgba(",
        paste(grDevices::col2rgb(cl$opti), collapse = ","), ",",
        cl$scenarios$optimise$bar_opacity, ")")

      p <- plotly::plot_ly() %>%
        plotly::add_bars(
          data = bl, x = ~tranche, y = ~kwh, name = "Baseline",
          text = ~paste0(pct, "%"), textposition = "outside",
          textfont = list(size = 10, family = "JetBrains Mono"),
          marker = list(color = bl_rgba),
          hovertemplate = "<b>%{x}</b><br>Baseline: %{y:.0f} kWh (%{text})<br>Prix moyen: %{customdata:.0f} EUR/MWh<extra></extra>",
          customdata = ~prix_moyen) %>%
        plotly::add_bars(
          data = op, x = ~tranche, y = ~kwh, name = "Optimise",
          text = ~paste0(pct, "%"), textposition = "outside",
          textfont = list(size = 10, family = "JetBrains Mono"),
          marker = list(color = op_rgba),
          hovertemplate = "<b>%{x}</b><br>Optimise: %{y:.0f} kWh (%{text})<br>Prix moyen: %{customdata:.0f} EUR/MWh<extra></extra>",
          customdata = ~prix_moyen)

      # Add price annotations on baseline bars
      for (i in seq_len(nrow(bl))) {
        p <- p %>% plotly::add_annotations(
          x = bl$tranche[i], y = bl$kwh[i] + max(bl$kwh) * 0.12,
          text = paste0(round(bl$prix_moyen[i]), " EUR/MWh"),
          showarrow = FALSE, font = list(size = 9, color = cl$text_muted))
      }

      p %>%
        plotly::layout(barmode = "group", bargap = 0.15) %>%
        pl_layout(ylab = "kWh")
    })

    # ---- Waterfall ----
    output$plot_waterfall <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      wf <- compute_waterfall(sim_filtered())

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
      m <- compute_monthly_summary(sim_filtered())
      DT::datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
        DT::formatStyle("Economie", color = DT::styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
    })
  })
}
