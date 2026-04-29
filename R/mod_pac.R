#' PAC Analysis Tab Module UI
#'
#' Visualizes heat pump behavior: hourly profile (baseline vs optimized),
#' peak/off-peak distribution, and effective price per kWh.
#'
#' @param id module id
#' @noRd
mod_pac_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::uiOutput(ns("pac_kpi_row")),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Profil horaire moyen de la PAC",
          "Puissance PAC moyenne par heure (0-23h). Compare le fonctionnement actuel (baseline) avec le pilotage optimise. Les zones colorees indiquent les plages peak/off-peak du contrat."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_profil_horaire"), height = "350px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("Repartition peak / off-peak",
          "Pourcentage de la conso PAC en heures pleines vs creuses du contrat. La ligne pointillee indique la proportion temporelle (si la PAC etait aveugle). Un ecart significatif revele un pilotage — ou son absence."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_peak_offpeak"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Distribution horaire de la conso PAC",
          "Repartition de la conso PAC par heure (% du total). Permet de voir ou se concentre la consommation et comment l'optimisation la deplace."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_hourly_dist"), height = "300px"))))
  )
}

#' PAC Analysis Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_pac_server <- function(id, sidebar) {
  moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered

    # ---- Helper: compute hourly PAC profile ----
    compute_hourly_profile <- function(sim, params, type = "baseline") {
      if (type == "optimized") {
        pac_qt <- params$p_pac_kw * params$dt_h
        pac_kwh <- sim$sim_pac_on * pac_qt
      } else {
        pac_kwh <- if ("pac_kwh" %in% names(sim)) {
          sim$pac_kwh
        } else {
          pmax(0, sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac)
        }
      }
      h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))
      n_days <- as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days"))
      n_days <- max(n_days, 1)

      dplyr::tibble(hour = h, pac_kwh = pac_kwh) %>%
        dplyr::group_by(hour) %>%
        dplyr::summarise(
          pac_total_kwh = sum(pac_kwh, na.rm = TRUE),
          pac_moy_kw = mean(pac_kwh, na.rm = TRUE) / params$dt_h,
          .groups = "drop"
        ) %>%
        dplyr::mutate(pct = round(100 * pac_total_kwh / max(sum(pac_total_kwh), 1), 1))
    }

    # ---- Helper: get peak hours from params ----
    get_peak_hours <- function(params) {
      if (!is.null(params$belix_peak_hours) && params$type_contrat == "belix") {
        params$belix_peak_hours
      } else {
        list(c(7, 11), c(17, 22))
      }
    }

    # ---- KPI row ----
    output$pac_kpi_row <- shiny::renderUI({
      shiny::req(sim_filtered())
      sim <- sim_filtered()
      res <- sidebar$sim_result()
      sim_c <- sidebar$sim_filtered_cible()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r
      sim_data <- if (!is.null(sim_c)) sim_c else sim

      kpi <- KPICalculator$new()
      prix_bl <- kpi$get_prix_moyen_pac(sim_data, params, "baseline")
      prix_op <- kpi$get_prix_moyen_pac(sim_data, params, "optimized")
      cor_bl <- kpi$get_correlation_pac_prix(sim_data, params, "baseline")
      cor_op <- kpi$get_correlation_pac_prix(sim_data, params, "optimized")

      # PAC consumption totals
      pac_qt <- params$p_pac_kw * params$dt_h
      pac_bl <- if ("pac_kwh" %in% names(sim_data)) {
        sum(sim_data$pac_kwh, na.rm = TRUE)
      } else {
        sum(pmax(0, sim_data$offtake_kwh + sim_data$pv_kwh - sim_data$intake_kwh - sim_data$conso_hors_pac), na.rm = TRUE)
      }
      pac_op <- sum(sim_data$sim_pac_on * pac_qt, na.rm = TRUE)

      # Peak/off-peak analysis
      peak_hours <- get_peak_hours(params)
      is_peak <- is_contract_peak(sim_data$timestamp, peak_hours)
      pac_kwh_bl <- if ("pac_kwh" %in% names(sim_data)) sim_data$pac_kwh else {
        pmax(0, sim_data$offtake_kwh + sim_data$pv_kwh - sim_data$intake_kwh - sim_data$conso_hors_pac)
      }
      pct_peak_bl <- round(100 * sum(pac_kwh_bl[is_peak], na.rm = TRUE) / max(sum(pac_kwh_bl, na.rm = TRUE), 1), 1)
      pac_kwh_op <- sim_data$sim_pac_on * pac_qt
      pct_peak_op <- round(100 * sum(pac_kwh_op[is_peak], na.rm = TRUE) / max(sum(pac_kwh_op, na.rm = TRUE), 1), 1)
      pct_temps_peak <- round(100 * sum(is_peak) / length(is_peak), 1)

      kpis <- list(
        kpi_card(sprintf("%.1f c/kWh", if (!is.na(prix_bl)) prix_bl * 100 else 0),
          "Prix effectif PAC", "", cl$reel,
          baseline_val = if (!is.na(prix_bl)) prix_bl * 100 else NULL,
          opti_val = if (!is.na(prix_op)) prix_op * 100 else NULL,
          gain_invert = TRUE,
          gain_val = if (!is.na(prix_bl) && !is.na(prix_op)) round((prix_op - prix_bl) * 100, 1) else NULL,
          gain_unit = "c/kWh",
          tooltip = "Prix moyen effectif du kWh PAC. Les kWh couverts par le PV sont comptes a 0."),
        kpi_card(sprintf("%.0f kWh", pac_bl),
          "Conso PAC", "", cl$accent3,
          baseline_val = pac_bl, opti_val = pac_op, gain_invert = TRUE,
          gain_val = round(pac_op - pac_bl), gain_unit = "kWh",
          tooltip = "Consommation electrique totale de la PAC sur la periode."),
        kpi_card(sprintf("%.1f%%", pct_peak_bl),
          "PAC en heures pleines", "", cl$danger,
          baseline_val = pct_peak_bl, opti_val = pct_peak_op, gain_invert = TRUE,
          gain_val = round(pct_peak_op - pct_peak_bl, 1), gain_unit = "pts",
          tooltip = sprintf("Part de la conso PAC en heures pleines. Ref temps = %.1f%%. Un thermostat aveugle serait proche de cette valeur.", pct_temps_peak)),
        kpi_card(sprintf("%+.3f", if (!is.na(cor_bl)) cor_bl else 0),
          "Correlation PAC/Prix", "", cl$text_muted,
          baseline_val = cor_bl, opti_val = cor_op,
          gain_val = if (!is.na(cor_bl) && !is.na(cor_op)) round(cor_op - cor_bl, 3) else NULL,
          tooltip = "Correlation de Pearson entre conso PAC et prix. Negatif = la PAC evite les heures cheres (bon pilotage). Proche de 0 = thermostat aveugle.")
      )
      bslib::layout_columns(col_widths = rep(3, 4), !!!kpis)
    })

    # ---- Hourly profile chart ----
    output$plot_profil_horaire <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      sim <- if (!is.null(sim_c)) sim_c else sim_filtered()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r

      bl <- compute_hourly_profile(sim, params, "baseline")
      op <- compute_hourly_profile(sim, params, "optimized")

      peak_hours <- get_peak_hours(params)

      # Build peak shading shapes
      shapes <- list()
      for (slot in peak_hours) {
        shapes <- c(shapes, list(list(
          type = "rect", xref = "x", yref = "paper",
          x0 = slot[1] - 0.5, x1 = slot[2] - 0.5, y0 = 0, y1 = 1,
          fillcolor = "rgba(239,68,68,0.08)", line = list(width = 0)
        )))
      }

      p <- plotly::plot_ly() %>%
        plotly::add_trace(
          data = bl, x = ~hour, y = ~pac_moy_kw, name = "Baseline",
          type = "scatter", mode = "lines+markers",
          line = list(color = cl$reel, width = 2.5),
          marker = list(color = cl$reel, size = 5),
          hovertemplate = "<b>%{x}h</b><br>Baseline: %{y:.1f} kW<extra></extra>") %>%
        plotly::add_trace(
          data = op, x = ~hour, y = ~pac_moy_kw, name = "Optimise",
          type = "scatter", mode = "lines+markers",
          line = list(color = cl$opti, width = 2.5),
          marker = list(color = cl$opti, size = 5),
          hovertemplate = "<b>%{x}h</b><br>Optimise: %{y:.1f} kW<extra></extra>") %>%
        plotly::layout(
          shapes = shapes,
          xaxis = list(
            dtick = 1, tick0 = 0,
            title = list(text = "Heure", standoff = 10)),
          annotations = list(list(
            x = mean(c(peak_hours[[1]][1], peak_hours[[1]][2])),
            y = 1.05, yref = "paper", xref = "x",
            text = "Pleine", showarrow = FALSE,
            font = list(size = 9, color = "#ef4444")
          ))
        ) %>%
        pl_layout(ylab = "Puissance PAC moyenne (kW)")

      # Add second peak label if exists
      if (length(peak_hours) >= 2) {
        p <- p %>% plotly::layout(annotations = list(
          list(
            x = mean(c(peak_hours[[1]][1], peak_hours[[1]][2])),
            y = 1.05, yref = "paper", xref = "x",
            text = "Pleine", showarrow = FALSE,
            font = list(size = 9, color = "#ef4444")),
          list(
            x = mean(c(peak_hours[[2]][1], peak_hours[[2]][2])),
            y = 1.05, yref = "paper", xref = "x",
            text = "Pleine", showarrow = FALSE,
            font = list(size = 9, color = "#ef4444"))
        ))
      }

      p
    })

    # ---- Peak/off-peak distribution ----
    output$plot_peak_offpeak <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      sim <- if (!is.null(sim_c)) sim_c else sim_filtered()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r

      peak_hours <- get_peak_hours(params)
      pac_qt <- params$p_pac_kw * params$dt_h
      is_peak <- is_contract_peak(sim$timestamp, peak_hours)
      pct_temps <- round(100 * sum(is_peak) / length(is_peak), 1)

      # Baseline
      pac_kwh_bl <- if ("pac_kwh" %in% names(sim)) sim$pac_kwh else {
        pmax(0, sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac)
      }
      total_bl <- sum(pac_kwh_bl, na.rm = TRUE)
      pct_peak_bl <- round(100 * sum(pac_kwh_bl[is_peak], na.rm = TRUE) / max(total_bl, 1), 1)

      # Optimized
      pac_kwh_op <- sim$sim_pac_on * pac_qt
      total_op <- sum(pac_kwh_op, na.rm = TRUE)
      pct_peak_op <- round(100 * sum(pac_kwh_op[is_peak], na.rm = TRUE) / max(total_op, 1), 1)

      df <- dplyr::tibble(
        scenario = rep(c("Baseline", "Optimise"), each = 2),
        plage = rep(c("Heures pleines", "Heures creuses"), 2),
        pct = c(pct_peak_bl, 100 - pct_peak_bl, pct_peak_op, 100 - pct_peak_op)
      )
      df$plage <- factor(df$plage, levels = c("Heures creuses", "Heures pleines"))
      df$scenario <- factor(df$scenario, levels = c("Baseline", "Optimise"))

      plotly::plot_ly(
        data = df, x = ~scenario, y = ~pct, color = ~plage,
        type = "bar",
        colors = c("Heures creuses" = cl$success, "Heures pleines" = "#ef4444"),
        text = ~paste0(pct, "%"), textposition = "inside",
        textfont = list(size = 11, family = "JetBrains Mono", color = "white"),
        hovertemplate = "<b>%{x}</b><br>%{fullData.name}: %{y:.1f}%<extra></extra>"
      ) %>%
        plotly::layout(
          barmode = "stack",
          shapes = list(list(
            type = "line", xref = "paper", yref = "y",
            x0 = 0, x1 = 1, y0 = pct_temps, y1 = pct_temps,
            line = list(color = cl$text_muted, width = 1.5, dash = "dash")
          )),
          annotations = list(list(
            x = 1.02, xref = "paper", y = pct_temps, yref = "y",
            text = sprintf("Ref: %.1f%%", pct_temps),
            showarrow = FALSE, xanchor = "left",
            font = list(size = 9, color = cl$text_muted)
          ))
        ) %>%
        pl_layout(ylab = "% conso PAC")
    })

    # ---- Hourly distribution bars ----
    output$plot_hourly_dist <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sim_c <- sidebar$sim_filtered_cible()
      sim <- if (!is.null(sim_c)) sim_c else sim_filtered()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r

      bl <- compute_hourly_profile(sim, params, "baseline")
      op <- compute_hourly_profile(sim, params, "optimized")

      peak_hours <- get_peak_hours(params)
      is_peak_h <- sapply(0:23, function(h) {
        any(sapply(peak_hours, function(s) h >= s[1] & h < s[2]))
      })
      bar_colors_bl <- ifelse(is_peak_h, "rgba(239,68,68,0.5)", paste0("rgba(",
        paste(grDevices::col2rgb(cl$reel), collapse = ","), ",0.5)"))
      bar_colors_op <- ifelse(is_peak_h, "rgba(239,68,68,0.3)", paste0("rgba(",
        paste(grDevices::col2rgb(cl$opti), collapse = ","), ",0.7)"))

      plotly::plot_ly() %>%
        plotly::add_bars(
          data = bl, x = ~hour, y = ~pct, name = "Baseline",
          marker = list(color = bar_colors_bl),
          hovertemplate = "<b>%{x}h</b><br>Baseline: %{y:.1f}%<extra></extra>") %>%
        plotly::add_bars(
          data = op, x = ~hour, y = ~pct, name = "Optimise",
          marker = list(color = bar_colors_op),
          hovertemplate = "<b>%{x}h</b><br>Optimise: %{y:.1f}%<extra></extra>") %>%
        plotly::layout(
          barmode = "group", bargap = 0.15,
          xaxis = list(dtick = 1, tick0 = 0, title = list(text = "Heure", standoff = 10))
        ) %>%
        pl_layout(ylab = "% conso PAC")
    })
  })
}
