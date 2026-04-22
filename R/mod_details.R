#' Details Tab Module UI
#'
#' Contains PAC timeline, temperature, COP, heatmap, battery SoC charts.
#'
#' @param id module id
#' @noRd
mod_details_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("PAC -- baseline vs optimise (timeline)"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_pac_timeline"), height = "350px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE, bslib::card_header("Temperature ballon"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_temperature"), height = "280px"))),
      bslib::card(full_screen = TRUE, bslib::card_header("COP journalier"),
        bslib::card_body(plotly::plotlyOutput(ns("plot_cop"), height = "280px")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("Heatmap"),
        bslib::card_body(
          bslib::layout_columns(col_widths = c(4, 8),
            shiny::selectInput(ns("heatmap_var"), NULL, choices = c(
              "Moins d'injection" = "inj_evitee", "Surplus PV" = "surplus",
              "PAC ON (optimise)" = "pac_on", "Temperature ballon" = "t_ballon",
              "Prix spot" = "prix"), selected = "inj_evitee"),
            shiny::tags$div()),
          plotly::plotlyOutput(ns("plot_heatmap"), height = "350px")))),
    shiny::conditionalPanel(
      condition = sprintf("input['%s']", shiny::NS("sidebar", "batterie_active")),
      ns = function(x) x,
      bslib::layout_columns(col_widths = 12,
        bslib::card(full_screen = TRUE, bslib::card_header("Batterie -- SoC"),
          bslib::card_body(plotly::plotlyOutput(ns("plot_batterie"), height = "250px")))))
  )
}

#' Details Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_details_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered
    params_r     <- sidebar$params_r
    sim_result   <- sidebar$sim_result

    # ---- Temperature ----
    output$plot_temperature <- plotly::renderPlotly({
      shiny::req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
      s <- sim %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
        dplyr::group_by(h) %>%
        dplyr::summarise(t_ballon = mean(t_ballon, na.rm = TRUE),
                  sim_t_ballon = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
        dplyr::rename(timestamp = h)
      plotly::plot_ly(s, x = ~timestamp) %>%
        plotly::add_trace(y = ~t_ballon, type = "scatter", mode = "lines", name = "Baseline", line = list(color = cl$reel, width = 1)) %>%
        plotly::add_trace(y = ~sim_t_ballon, type = "scatter", mode = "lines", name = "Optimise", line = list(color = cl$opti, width = 1.5)) %>%
        plotly::add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_min, yend = p$t_min, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
        plotly::add_segments(x = min(s$timestamp), xend = max(s$timestamp), y = p$t_max, yend = p$t_max, line = list(color = cl$text_muted, dash = "dash", width = .8), showlegend = FALSE) %>%
        pl_layout(ylab = "C")
    })

    # ---- COP ----
    output$plot_cop <- plotly::renderPlotly({
      shiny::req(sim_filtered()); sim <- sim_filtered()
      d <- sim %>% dplyr::filter(!is.na(sim_cop)) %>% dplyr::mutate(jour = as.Date(timestamp)) %>%
        dplyr::group_by(jour) %>% dplyr::summarise(cop = mean(sim_cop, na.rm = TRUE), .groups = "drop")
      plotly::plot_ly(d, x = ~jour, y = ~cop, type = "scatter", mode = "lines", line = list(color = cl$pac, width = 1.5), fill = "tozeroy", fillcolor = "rgba(5,150,105,0.08)") %>% pl_layout(ylab = "COP")
    })

    # ---- PAC timeline ----
    output$plot_pac_timeline <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sf <- sim_filtered()
      p <- if (!is.null(sim_result()$params)) sim_result()$params else params_r()
      pac_qt <- p$p_pac_kw * p$dt_h

      sf <- sf %>% dplyr::mutate(
        pac_kwh_reel = ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0),
        pac_kwh_opti = sim_pac_on * pac_qt
      )

      agg <- auto_aggregate(sf)
      d <- agg$data

      plotly::plot_ly(d, x = ~timestamp) %>%
        plotly::add_trace(y = ~pv_kwh, type = "scatter", mode = "lines", name = "Production PV",
          fill = "tozeroy", fillcolor = "rgba(245,158,11,0.12)",
          line = list(color = cl$pv, width = 1)) %>%
        plotly::add_bars(y = ~pac_kwh_reel, name = "PAC baseline",
          marker = list(color = cl$reel, opacity = 0.4)) %>%
        plotly::add_bars(y = ~pac_kwh_opti, name = "PAC optimise",
          marker = list(color = cl$opti, opacity = 0.7)) %>%
        plotly::layout(barmode = "overlay", bargap = 0.05) %>%
        pl_layout(ylab = paste0("kWh (", agg$label, ")"))
    })

    # ---- Heatmap ----
    output$plot_heatmap <- plotly::renderPlotly({
      shiny::req(sim_filtered(), input$heatmap_var); sim <- sim_filtered()

      hm <- sim %>%
        dplyr::mutate(jour = as.Date(timestamp), h = floor(lubridate::hour(timestamp) + lubridate::minute(timestamp) / 60)) %>%
        dplyr::group_by(jour, h) %>%
        dplyr::summarise(
          inj_evitee = sum(intake_kwh - sim_intake, na.rm = TRUE),
          surplus = sum(pmax(0, pv_kwh - conso_hors_pac), na.rm = TRUE),
          pac_on = sum(sim_pac_on, na.rm = TRUE) / 4,
          t_ballon = mean(sim_t_ballon, na.rm = TRUE),
          prix = mean(prix_eur_kwh, na.rm = TRUE) * 100,
          .groups = "drop"
        )

      v <- input$heatmap_var
      zlab <- c(inj_evitee = "Moins d'injection (kWh)", surplus = "Surplus PV (kWh)",
                pac_on = "PAC ON (frac.)", t_ballon = "T ballon (C)", prix = "Prix (cEUR/kWh)")

      cs <- if (v == "inj_evitee") list(c(0, cl$danger), c(0.5, "#F6F7F8"), c(1, cl$success))
            else if (v == "prix") list(c(0, cl$success), c(0.5, cl$pv), c(1, cl$danger))
            else if (v == "t_ballon") list(c(0, cl$opti), c(0.5, cl$pv), c(1, cl$danger))
            else list(c(0, "#F6F7F8"), c(1, cl$opti))

      mat <- hm %>%
        dplyr::select(jour, h, val = !!rlang::sym(v)) %>%
        tidyr::pivot_wider(names_from = h, values_from = val) %>%
        dplyr::arrange(jour)

      jours <- mat$jour
      heures <- as.integer(colnames(mat)[-1])
      z_mat <- as.matrix(mat[, -1])

      txt_mat <- matrix(
        paste0(rep(format(jours, "%d %b %Y"), each = length(heures)), " ", rep(heures, length(jours)), "h\n",
               round(as.vector(t(z_mat)), 2), " ", zlab[v]),
        nrow = length(jours), ncol = length(heures), byrow = TRUE)

      plotly::plot_ly(x = heures, y = jours, z = z_mat, type = "heatmap",
        colorscale = cs, hoverinfo = "text", text = txt_mat,
        colorbar = list(title = list(text = zlab[v], font = list(color = cl$text_muted, size = 9)),
          tickfont = list(color = cl$text_muted, size = 9))) %>%
        pl_layout(xlab = "Heure", ylab = NULL)
    })

    # ---- Batterie SoC ----
    output$plot_batterie <- plotly::renderPlotly({
      shiny::req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
      if (!p$batterie_active || is.null(sim$batt_soc)) return(plotly::plot_ly() %>% pl_layout())

      plotly::plot_ly(sim, x = ~timestamp) %>%
        plotly::add_trace(y = ~batt_soc * 100, type = "scatter", mode = "lines", name = "SoC",
          fill = "tozeroy", fillcolor = "rgba(29,67,69,0.1)",
          line = list(color = cl$opti, width = 1.5)) %>%
        plotly::add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
          y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
          line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
        plotly::add_segments(x = min(sim$timestamp), xend = max(sim$timestamp),
          y = p$batt_soc_max * 100, yend = p$batt_soc_max * 100,
          line = list(color = cl$danger, dash = "dash", width = .8), showlegend = FALSE) %>%
        pl_layout(ylab = "SoC (%)")
    })
  })
}
