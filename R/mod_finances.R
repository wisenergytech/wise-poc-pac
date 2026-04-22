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

    # ---- KPIs ----
    output$finance_kpi_row <- shiny::renderUI({
      shiny::req(sidebar$kpis_r())
      k <- sidebar$kpis_r()

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
          tooltip = "Revenu de l'electricite injectee dans le reseau.")
      )
      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Cumulative bill ----
    output$plot_cout_cumule <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      d <- compute_cumulative_bill(sim_filtered())
      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~cum_baseline, type = "scatter", mode = "lines", name = "Facture baseline",
          line = list(color = cl$reel, width = 2), fill = "tozeroy", fillcolor = "rgba(249,115,22,0.08)") %>%
        plotly::add_trace(y = ~cum_opti, type = "scatter", mode = "lines", name = "Facture optimisee",
          line = list(color = cl$opti, width = 2), fill = "tozeroy", fillcolor = "rgba(34,211,238,0.08)") %>%
        pl_layout(ylab = "Facture nette cumulee (EUR)")
    })

    # ---- Waterfall ----
    output$plot_waterfall <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      wf <- compute_waterfall(sim_filtered())
      eco_totale <- wf$value[wf$measure == "total"]

      plotly::plot_ly(
        x = wf$label, y = wf$value,
        type = "waterfall",
        measure = wf$measure,
        text = paste0(ifelse(wf$value >= 0, "+", ""), round(wf$value, 1), " EUR"),
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
      shiny::req(sim_filtered())
      m <- compute_monthly_summary(sim_filtered())
      DT::datatable(m, rownames = FALSE, options = list(dom = "t", pageLength = 13), class = "compact") %>%
        DT::formatStyle("Economie", color = DT::styleInterval(0, c(cl$danger, cl$success)), fontWeight = "bold")
    })
  })
}
