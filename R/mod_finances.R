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
        card_header_tip("Decomposition de l'economie",
          "Cascade partant de la facture reelle (sans optimisation) jusqu'a la facture optimisee. Chaque barre intermediaire montre une composante de l'economie : reduction du soutirage, perte d'injection, et arbitrage horaire."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_waterfall"), height = "300px"))),
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
      plot_cumulative(d, ylab = "Facture nette cumulee (EUR)", unit = "EUR",
        baseline_label = "Facture baseline", opti_label = "Facture optimisee",
        delta_label = "Economie cumulee")
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
