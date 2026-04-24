#' Energy Tab Module UI
#'
#' Contains energy KPIs, consumption bar charts (soutirage, injection,
#' autoconsommation, autosuffisance), and Sankey diagram.
#'
#' @param id module id
#' @noRd
mod_energie_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("energy_kpi_row")),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("Soutirage reseau",
          "Electricite achetee au reseau par periode. La partie commune (cyan) montre le soutirage optimise ; l'excedent (orange) montre le surplus evite par l'optimisation."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_soutirage"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Injection reseau",
          "Electricite injectee dans le reseau par periode. La partie commune (cyan) montre l'injection optimisee ; l'excedent (orange) montre le surplus d'injection evite (autoconsomme a la place)."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_injection"), height = "300px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("Autoconsommation PV",
          "Production PV consommee sur place par periode. La partie commune (orange) montre l'autoconsommation baseline ; l'excedent (cyan) montre le gain d'autoconsommation apporte par l'optimisation."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_autoconso"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Autosuffisance",
          "Part de la consommation totale couverte par le PV, en kWh. La partie commune (orange) montre l'autosuffisance baseline ; l'excedent (cyan) montre le gain apporte par l'optimisation."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_autosuffisance"), height = "300px")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("Flux d'energie"),
        bslib::card_body(
          shiny::radioButtons(ns("sankey_scenario"), NULL, choices = c("Baseline" = "baseline", "Optimise" = "optimise"), selected = "baseline", inline = TRUE),
          plotly::plotlyOutput(ns("plot_sankey"), height = "350px"))))
  )
}

#' Energy Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_energie_server <- function(id, sidebar) {
  moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered
    params_r <- sidebar$params_r

    # ---- KPIs ----
    output$energy_kpi_row <- shiny::renderUI({
      shiny::req(sidebar$kpis_r())
      k <- sidebar$kpis_r()

      kpis <- list(
        kpi_card(formatC(round(k$pv_total), big.mark = " ", format = "d"),
          "Production PV", "kWh", cl$pv,
          tooltip = "Production photovoltaique totale sur la periode."),
        kpi_card(paste0(k$ac_opti, "%"),
          "Autoconsommation", "", cl$success,
          baseline_val = k$ac_baseline, opti_val = k$ac_opti,
          gain_val = round(k$ac_opti - k$ac_baseline, 1), gain_unit = "pts",
          tooltip = "Part du PV consommee sur place.", is_percentage = TRUE),
        kpi_card(paste0(k$as_opti, "%"),
          "Autosuffisance", "", cl$accent3,
          baseline_val = k$as_baseline, opti_val = k$as_opti,
          gain_val = round(k$as_opti - k$as_baseline, 1), gain_unit = "pts",
          tooltip = "Part de la consommation couverte par le PV.", is_percentage = TRUE),
        kpi_card(formatC(round(k$soutirage_opti), big.mark = " ", format = "d"),
          "Soutirage reseau", "kWh", cl$accent3,
          baseline_val = k$soutirage_baseline, opti_val = k$soutirage_opti, gain_invert = TRUE,
          gain_val = round(k$soutirage_opti - k$soutirage_baseline), gain_unit = "kWh",
          tooltip = "Electricite soutiree du reseau."),
        kpi_card(formatC(round(k$injection_opti), big.mark = " ", format = "d"),
          "Injection reseau", "kWh", cl$opti,
          baseline_val = k$injection_baseline, opti_val = k$injection_opti, gain_invert = TRUE,
          gain_val = round(k$injection_opti - k$injection_baseline), gain_unit = "kWh",
          tooltip = "Electricite injectee dans le reseau."),
        kpi_card(formatC(round(k$conso_pac_opti), big.mark = " ", format = "d"),
          "Conso PAC", "kWh", cl$pac,
          baseline_val = k$conso_pac_baseline, opti_val = k$conso_pac_opti, gain_invert = TRUE,
          gain_val = round(k$conso_pac_opti - k$conso_pac_baseline), gain_unit = "kWh",
          tooltip = "Consommation electrique de la PAC.")
      )

      if (!is.null(k$batt_cycles)) {
        kpis <- c(kpis, list(
          kpi_card(k$batt_cycles, "Cycles batterie", "", cl$accent3,
            tooltip = "Cycles complets de charge/decharge.")))
      }

      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Charts ----
    conso_data <- shiny::reactive({
      shiny::req(sim_filtered())
      prepare_energy_timeseries(sim_filtered())
    })

    output$plot_soutirage <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plot_overlay_bar(cd$data, "soutirage_baseline", "soutirage_opti",
        paste0("kWh (", cd$label, ")"))
    })

    output$plot_injection <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plot_overlay_bar(cd$data, "injection_baseline", "injection_opti",
        paste0("kWh (", cd$label, ")"))
    })

    output$plot_autoconso <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plot_overlay_bar(cd$data, "autoconso_baseline", "autoconso_opti",
        paste0("kWh (", cd$label, ")"))
    })

    output$plot_autosuffisance <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plot_overlay_bar(cd$data, "autosuff_baseline", "autosuff_opti",
        paste0("% (", cd$label, ")"))
    })

    # ---- Sankey ----
    output$plot_sankey <- plotly::renderPlotly({
      shiny::req(sim_filtered(), input$sankey_scenario)
      flows <- compute_sankey_flows(sim_filtered(), input$sankey_scenario)

      plotly::plot_ly(type = "sankey", orientation = "h",
        node = list(
          label = paste0(flows$nodes$label, " (", flows$nodes$value, " kWh)"),
          color = c(cl$pv, cl$danger, cl$pac, cl$text_muted, cl$reel),
          pad = 20, thickness = 20, line = list(width = 0)
        ),
        link = flows$links
      ) %>% pl_layout()
    })
  })
}
