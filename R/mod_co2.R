#' CO2 Impact Tab Module UI
#'
#' Contains CO2 KPIs, emissions overlay bar chart, cumulative CO2, and heatmap.
#'
#' @param id module id
#' @noRd
mod_co2_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("co2_kpi_row")),
    bslib::card(full_screen = TRUE,
      card_header_tip("Emissions CO2",
        "Emissions CO2 liees au soutirage reseau par periode. La partie commune (cyan) montre les emissions optimisees ; l'excedent (orange) montre les emissions evitees par l'optimisation."),
      bslib::card_body(plotly::plotlyOutput(ns("plot_co2_emissions"), height = "350px"))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("Emissions CO2 cumulees -- baseline vs optimise",
          "Evolution des emissions CO2 cumulees (liees au soutirage reseau) au fil du temps. L'ecart entre les deux courbes represente le CO2 evite a chaque instant."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_co2_cumul"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Heatmap intensite CO2 du reseau",
          "Intensite carbone du reseau electrique belge par heure et par jour (gCO2eq/kWh). Les zones rouges/oranges indiquent les heures les plus carbonees, les zones vertes les plus propres."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_co2_heatmap"), height = "300px")))),
    shiny::tags$div(style = sprintf("font-size:.75rem;color:%s;padding:4px 8px;", cl$text_muted),
      shiny::uiOutput(ns("co2_data_source")))
  )
}

#' CO2 Impact Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_co2_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered

    # ---- CO2 data (CSV local = instantane, fallback API si besoin) ----
    co2_data <- shiny::reactive({
      shiny::req(sim_filtered())
      sim <- sim_filtered()
      fetch_co2_intensity(
        min(sim$timestamp, na.rm = TRUE),
        max(sim$timestamp, na.rm = TRUE)
      )
    })

    co2_15min_r <- shiny::reactive({
      shiny::req(sim_filtered(), co2_data())
      interpolate_co2_15min(co2_data()$df, sim_filtered()$timestamp)
    })

    co2_impact_r <- shiny::reactive({
      shiny::req(sim_filtered(), co2_15min_r())
      compute_co2_impact(sim_filtered(), co2_15min_r())
    })

    # ---- KPIs ----
    output$co2_kpi_row <- shiny::renderUI({
      shiny::req(co2_impact_r(), co2_15min_r(), sidebar$kpis_r())
      sim <- sim_filtered(); p <- sidebar$params_r()

      k <- KPICalculator$new()$compute(sim, sim, p, co2_15min = co2_15min_r())

      kpis <- list(
        kpi_card(sprintf("%.1f", k$co2_opti_kg),
          "Emissions CO2", "kg", cl$opti,
          baseline_val = k$co2_baseline_kg, opti_val = k$co2_opti_kg, gain_invert = TRUE,
          gain_val = round(k$co2_opti_kg - k$co2_baseline_kg, 1), gain_unit = "kg",
          tooltip = "Emissions CO2 liees au soutirage reseau."),
        kpi_card(sprintf("%.0f", k$co2_intensity_opti),
          "Intensite carbone", "gCO2/kWh", cl$opti,
          baseline_val = k$co2_intensity_baseline, opti_val = k$co2_intensity_opti, gain_invert = TRUE,
          gain_val = round(k$co2_intensity_opti - k$co2_intensity_baseline), gain_unit = "gCO2/kWh",
          tooltip = "Intensite carbone moyenne ponderee par la consommation."),
        kpi_card(sprintf("%.0f", k$co2_equiv_car_km),
          "Equiv. voiture", "km", cl$opti,
          tooltip = "Kilometres de voiture equivalents au CO2 evite."),
        kpi_card(sprintf("%.1f", k$co2_equiv_trees_year),
          "Equiv. arbres", "/an", cl$pv,
          tooltip = "Nombre d'arbres necessaires pour absorber le CO2 evite en 1 an.")
      )
      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Emissions overlay bar chart (auto-aggregated, same as energy tab) ----
    output$plot_co2_emissions <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact_r())
      impact <- co2_impact_r()
      d <- data.frame(
        timestamp      = sim_filtered()$timestamp,
        co2_baseline   = impact$co2_baseline_g,
        co2_opti       = impact$co2_opti_g
      )
      agg <- auto_aggregate(d)
      plot_overlay_bar(agg$data, "co2_baseline", "co2_opti",
        paste0("gCO2 (", agg$label, ")"), agg_level = agg$level)
    })

    # ---- Cumulative (baseline vs opti, same pattern as facture cumulee) ----
    output$plot_co2_cumul <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact_r())
      impact <- co2_impact_r()
      d <- data.frame(
        timestamp    = sim_filtered()$timestamp,
        cum_baseline = cumsum(ifelse(is.na(impact$co2_baseline_g), 0, impact$co2_baseline_g)) / 1000,
        cum_opti     = cumsum(ifelse(is.na(impact$co2_opti_g), 0, impact$co2_opti_g)) / 1000
      )
      # Downsample to hourly
      d <- d %>%
        dplyr::mutate(.h = lubridate::floor_date(timestamp, "hour")) %>%
        dplyr::group_by(.h) %>%
        dplyr::slice_tail(n = 1) %>%
        dplyr::ungroup() %>%
        dplyr::select(timestamp, cum_baseline, cum_opti)
      plot_cumulative(d, ylab = "Emissions CO2 cumulees (kg)", unit = "kg",
        baseline_label = "CO2 baseline", opti_label = "CO2 optimise",
        delta_label = "CO2 evite")
    })

    # ---- Heatmap ----
    output$plot_co2_heatmap <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact_r())
      hm <- prepare_co2_heatmap(sim_filtered(), co2_impact_r())

      txt_mat <- matrix(
        paste0(rep(format(hm$jours, "%d %b"), each = length(hm$heures)), " ",
               rep(hm$heures, length(hm$jours)), "h\n",
               round(as.vector(t(hm$z_mat)), 0), " gCO2/kWh"),
        nrow = length(hm$jours), ncol = length(hm$heures), byrow = TRUE)

      cs <- list(c(0, "#065f46"), c(0.3, "#34d399"), c(0.5, "#fbbf24"),
                 c(0.8, "#f97316"), c(1, "#dc2626"))

      plotly::plot_ly(x = hm$heures, y = hm$jours, z = hm$z_mat, type = "heatmap",
        colorscale = cs, hoverinfo = "text", text = txt_mat,
        colorbar = list(title = list(text = "gCO2/kWh", font = list(color = cl$text_muted, size = 9)),
          tickfont = list(color = cl$text_muted, size = 9))) %>%
        pl_layout(xlab = "Heure", ylab = NULL)
    })

    # ---- Data source ----
    output$co2_data_source <- shiny::renderUI({
      shiny::req(co2_data())
      src <- co2_data()$source
      label <- switch(src,
        local              = "CSV local (Elia ODS192 pre-telecharge)",
        api_historical     = "Elia ODS192 (historique, consumption-based)",
        api_realtime       = "Elia ODS191 (temps reel, consumption-based)",
        api_generation_mix = "Elia ODS201 (calcule depuis le mix de generation)",
        fallback           = "Profil synthetique (moyennes belges 2024)"
      )
      icon_name <- if (src == "fallback") "triangle-exclamation" else "circle-check"
      icon_col  <- if (src == "fallback") cl$danger else cl$success
      shiny::tags$span(
        shiny::tags$i(class = paste0("fa fa-", icon_name), style = sprintf("color:%s;", icon_col)),
        sprintf(" Source CO2 : %s", label)
      )
    })

    # Force outputs to render even when tab is hidden (bslib lazy tabs)
    shiny::outputOptions(output, "co2_kpi_row", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "plot_co2_emissions", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "plot_co2_cumul", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "plot_co2_heatmap", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "co2_data_source", suspendWhenHidden = FALSE)
  })
}
