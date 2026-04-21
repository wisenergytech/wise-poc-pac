#' Energy Tab Module UI
#'
#' Contains energy KPIs, consumption bar charts (soutirage, injection,
#' autoconsommation), and Sankey diagram.
#'
#' @param id module id
#' @noRd
mod_energie_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("energy_kpi_row")),
    bslib::layout_columns(col_widths = c(4, 4, 4),
      bslib::card(full_screen = TRUE, bslib::card_header("Soutirage reseau"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_soutirage"), height = "300px"))),
      bslib::card(full_screen = TRUE, bslib::card_header("Injection reseau"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_injection"), height = "300px"))),
      bslib::card(full_screen = TRUE, bslib::card_header("Autoconsommation PV"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_autoconso"), height = "300px")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("Flux d'energie"),
        bslib::card_body(
          shiny::radioButtons(ns("sankey_scenario"), NULL, choices = c("Baseline" = "reel", "Optimise" = "optimise"), selected = "reel", inline = TRUE),
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

    # ---- KPIs ENERGIE ----
    output$energy_kpi_row <- shiny::renderUI({
      shiny::req(sim_filtered()); sim <- sim_filtered(); p <- params_r()

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

      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Consumption data ----
    conso_data <- shiny::reactive({
      shiny::req(sim_filtered())
      sf <- sim_filtered()
      agg <- auto_aggregate(sf)
      d <- agg$data %>% dplyr::mutate(
        soutirage_baseline = offtake_kwh,
        soutirage_opti = sim_offtake,
        injection_baseline = intake_kwh,
        injection_opti = sim_intake,
        autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
        autoconso_opti = pmax(0, pv_kwh - sim_intake)
      )
      list(data = d, label = agg$label)
    })

    output$plot_soutirage <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plotly::plot_ly(cd$data, x = ~timestamp) %>%
        plotly::add_bars(y = ~soutirage_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
        plotly::add_bars(y = ~soutirage_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
        plotly::layout(barmode = "group", bargap = 0.1) %>%
        pl_layout(ylab = paste0("kWh (", cd$label, ")"))
    })

    output$plot_injection <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plotly::plot_ly(cd$data, x = ~timestamp) %>%
        plotly::add_bars(y = ~injection_baseline, name = "Baseline", marker = list(color = cl$reel, opacity = 0.6)) %>%
        plotly::add_bars(y = ~injection_opti, name = "Optimise", marker = list(color = cl$opti)) %>%
        plotly::layout(barmode = "group", bargap = 0.1) %>%
        pl_layout(ylab = paste0("kWh (", cd$label, ")"))
    })

    output$plot_autoconso <- plotly::renderPlotly({
      shiny::req(conso_data()); cd <- conso_data()
      plotly::plot_ly(cd$data, x = ~timestamp) %>%
        plotly::add_bars(y = ~autoconso_baseline, name = "Baseline", marker = list(color = cl$pv, opacity = 0.6)) %>%
        plotly::add_bars(y = ~autoconso_opti, name = "Optimise", marker = list(color = cl$success)) %>%
        plotly::layout(barmode = "group", bargap = 0.1) %>%
        pl_layout(ylab = paste0("kWh (", cd$label, ")"))
    })

    # ---- Sankey ----
    output$plot_sankey <- plotly::renderPlotly({
      shiny::req(sim_filtered(), input$sankey_scenario)
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
  })
}
