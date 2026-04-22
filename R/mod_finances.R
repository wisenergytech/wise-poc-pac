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
      bslib::card(full_screen = TRUE, bslib::card_header("Facture nette cumulee -- baseline vs optimise"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_cout_cumule"), height = "320px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE, bslib::card_header("Decomposition de l'economie"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_waterfall"), height = "300px"))),
      bslib::card(full_screen = TRUE, bslib::card_header("Bilan mensuel"),
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

    # ---- KPIs FINANCES ----
    output$finance_kpi_row <- shiny::renderUI({
      shiny::req(sim_filtered()); sim <- sim_filtered()

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
      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Cumulative bill ----
    output$plot_cout_cumule <- plotly::renderPlotly({
      shiny::req(sim_filtered()); sim <- sim_filtered()
      d <- sim %>%
        dplyr::mutate(
          facture_reel_qt = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
          facture_opti_qt = sim_offtake * prix_offtake - sim_intake * prix_injection
        ) %>%
        dplyr::mutate(
          cum_reel = cumsum(ifelse(is.na(facture_reel_qt), 0, facture_reel_qt)),
          cum_opti = cumsum(ifelse(is.na(facture_opti_qt), 0, facture_opti_qt))
        )
      d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        dplyr::group_by(h) %>% dplyr::slice_tail(n = 1) %>% dplyr::ungroup()
      plotly::plot_ly(d_h, x = ~timestamp) %>%
        plotly::add_trace(y = ~cum_reel, type = "scatter", mode = "lines", name = "Facture baseline",
          line = list(color = cl$reel, width = 2), fill = "tozeroy", fillcolor = "rgba(249,115,22,0.08)") %>%
        plotly::add_trace(y = ~cum_opti, type = "scatter", mode = "lines", name = "Facture optimisee",
          line = list(color = cl$opti, width = 2), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.08)") %>%
        pl_layout(ylab = "Facture nette cumulee (EUR)")
    })

    # ---- Waterfall ----
    output$plot_waterfall <- plotly::renderPlotly({
      shiny::req(sim_filtered()); sim <- sim_filtered()

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

    # ---- Monthly table ----
    output$table_mensuel <- DT::renderDT({
      shiny::req(sim_filtered()); sim <- sim_filtered()
      m <- sim %>% dplyr::mutate(mois = lubridate::floor_date(timestamp, "month")) %>% dplyr::group_by(mois) %>%
        dplyr::summarise(`PV` = round(sum(pv_kwh, na.rm = TRUE)),
          `Facture baseline` = round(sum(offtake_kwh * prix_offtake - intake_kwh * prix_injection, na.rm = TRUE)),
          `Facture opti` = round(sum(sim_offtake * prix_offtake - sim_intake * prix_injection, na.rm = TRUE)),
          .groups = "drop") %>%
        dplyr::mutate(Mois = format(mois, "%b %Y"), Economie = `Facture baseline` - `Facture opti`, `EUR/j` = round(Economie / lubridate::days_in_month(mois), 2)) %>%
        dplyr::select(Mois, PV, `Facture baseline`, `Facture opti`, Economie, `EUR/j`)
      DT::datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
        DT::formatStyle("Economie", color = DT::styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
    })
  })
}
