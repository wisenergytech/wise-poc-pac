#' CO2 Impact Tab Module UI
#'
#' Contains CO2 KPIs, hourly impact chart, cumulative CO2, and heatmap.
#'
#' @param id module id
#' @noRd
mod_co2_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("co2_kpi_row")),
    bslib::card(full_screen = TRUE, bslib::card_header("Impact CO2 horaire -- baseline vs optimise"),
      bslib::card_body(plotly::plotlyOutput(ns("plot_co2_hourly"), height = "350px"))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE, bslib::card_header("CO2 evite cumule"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_co2_cumul"), height = "300px"))),
      bslib::card(full_screen = TRUE, bslib::card_header("Heatmap intensite CO2 du reseau"),
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
    sim_result   <- sidebar$sim_result

    # ---- CO2 data (CSV local = instantane, fallback API si besoin) ----
    co2_data <- shiny::reactive({
      shiny::req(sim_filtered())
      sim <- sim_filtered()
      start_d <- min(sim$timestamp, na.rm = TRUE)
      end_d   <- max(sim$timestamp, na.rm = TRUE)
      fetch_co2_intensity(start_d, end_d)
    })

    co2_impact <- shiny::reactive({
      shiny::req(sim_filtered(), co2_data())
      sim <- sim_filtered()
      co2_raw <- co2_data()
      co2_15min <- interpolate_co2_15min(co2_raw$df, sim$timestamp)
      compute_co2_impact(sim, co2_15min)
    })

    # ---- KPIs ----
    output$co2_kpi_row <- shiny::renderUI({
      shiny::req(co2_impact())
      impact <- co2_impact()

      co2_base_kg <- sum(impact$co2_baseline_g, na.rm = TRUE) / 1000
      co2_opti_kg <- sum(impact$co2_opti_g, na.rm = TRUE) / 1000

      kpis <- list(
        kpi_card(sprintf("%.1f", impact$co2_saved_kg),
          "CO2 evite", "kg", cl$success,
          baseline_val = co2_base_kg, opti_val = co2_opti_kg, gain_invert = TRUE,
          gain_val = round(impact$co2_saved_kg, 1), gain_unit = "kg",
          tooltip = "Emissions evitees."),
        kpi_card(sprintf("%.0f", impact$intensity_before),
          "Intensite baseline", "gCO2/kWh", cl$reel,
          tooltip = "Intensite carbone moyenne ponderee par la consommation baseline."),
        kpi_card(sprintf("%.0f", impact$intensity_after),
          "Intensite optimisee", "gCO2/kWh", cl$opti,
          baseline_val = impact$intensity_before, opti_val = impact$intensity_after, gain_invert = TRUE,
          gain_val = round(impact$intensity_after - impact$intensity_before), gain_unit = "gCO2/kWh",
          tooltip = "Intensite carbone ponderee par la consommation optimisee."),
        kpi_card(sprintf("%.1f%%", impact$co2_pct_reduction),
          "Reduction intensite", "", cl$success,
          tooltip = "Reduction de l'intensite carbone."),
        kpi_card(sprintf("%.0f", impact$equiv_car_km),
          "Equiv. voiture", "km", "#22d3ee",
          tooltip = "Kilometres de voiture equivalents au CO2 evite."),
        kpi_card(sprintf("%.1f", impact$equiv_trees_year),
          "Equiv. arbres", "/an", "#fbbf24",
          tooltip = "Nombre d'arbres necessaires pour absorber le CO2 evite en 1 an.")
      )
      do.call(shiny::tags$div, c(
        list(style = "display:flex;justify-content:space-evenly;gap:8px;margin-bottom:12px;"),
        lapply(kpis, function(k) shiny::tags$div(style = "flex:1;", k))
      ))
    })

    # ---- Hourly chart ----
    output$plot_co2_hourly <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact())
      sim <- sim_filtered()
      impact <- co2_impact()

      d <- sim %>%
        dplyr::mutate(co2_saved_g = impact$co2_saved_g, co2_intensity = impact$co2_intensity,
          h = lubridate::floor_date(timestamp, "hour")) %>%
        dplyr::group_by(h) %>%
        dplyr::summarise(co2_saved_g = sum(co2_saved_g, na.rm = TRUE),
          co2_intensity = mean(co2_intensity, na.rm = TRUE), .groups = "drop") %>%
        dplyr::rename(timestamp = h)

      bar_colors <- ifelse(d$co2_saved_g >= 0, cl$success, cl$danger)

      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_bars(y = ~co2_saved_g, name = "CO2 evite (g)",
          marker = list(color = bar_colors)) %>%
        plotly::add_trace(y = ~co2_intensity, type = "scatter", mode = "lines",
          name = "Intensite reseau (gCO2/kWh)", yaxis = "y2",
          line = list(color = cl$accent3, width = 1.5, dash = "dot")) %>%
        pl_layout(ylab = "CO2 evite (g)") %>%
        plotly::layout(
          yaxis2 = list(title = "gCO2eq/kWh", overlaying = "y", side = "right",
            gridcolor = "transparent", tickfont = list(size = 10, color = cl$accent3),
            titlefont = list(color = cl$accent3, size = 11)),
          barmode = "relative"
        )
    })

    # ---- Cumulative ----
    output$plot_co2_cumul <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact())
      sim <- sim_filtered()
      impact <- co2_impact()

      d <- sim %>%
        dplyr::mutate(co2_cumul_kg = impact$co2_saved_cumul_kg) %>%
        dplyr::select(timestamp, co2_cumul_kg)

      plotly::plot_ly(d, x = ~timestamp, y = ~co2_cumul_kg, type = "scatter", mode = "lines",
        name = "CO2 evite cumule",
        fill = "tozeroy", fillcolor = "rgba(52,211,153,0.15)",
        line = list(color = cl$success, width = 2)) %>%
        pl_layout(ylab = "kg CO2eq evite")
    })

    # ---- Heatmap ----
    output$plot_co2_heatmap <- plotly::renderPlotly({
      shiny::req(sim_filtered(), co2_impact())
      sim <- sim_filtered()
      impact <- co2_impact()

      d <- sim %>%
        dplyr::mutate(co2_intensity = impact$co2_intensity,
          jour = as.Date(timestamp), h = lubridate::hour(timestamp)) %>%
        dplyr::group_by(jour, h) %>%
        dplyr::summarise(co2 = mean(co2_intensity, na.rm = TRUE), .groups = "drop")

      mat <- d %>%
        tidyr::pivot_wider(names_from = h, values_from = co2) %>%
        dplyr::arrange(jour)

      jours  <- mat$jour
      heures <- as.integer(colnames(mat)[-1])
      z_mat  <- as.matrix(mat[, -1])

      txt_mat <- matrix(
        paste0(rep(format(jours, "%d %b"), each = length(heures)), " ", rep(heures, length(jours)), "h\n",
               round(as.vector(t(z_mat)), 0), " gCO2/kWh"),
        nrow = length(jours), ncol = length(heures), byrow = TRUE)

      cs <- list(c(0, "#065f46"), c(0.3, "#34d399"), c(0.5, "#fbbf24"), c(0.8, "#f97316"), c(1, "#dc2626"))

      plotly::plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
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
    shiny::outputOptions(output, "plot_co2_hourly", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "plot_co2_cumul", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "plot_co2_heatmap", suspendWhenHidden = FALSE)
    shiny::outputOptions(output, "co2_data_source", suspendWhenHidden = FALSE)
  })
}
