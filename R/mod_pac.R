#' PAC Analysis Tab Module UI
#'
#' Visualizes heat pump behavior: hourly profile (baseline vs optimized),
#' price distribution of PAC consumption, and hourly distribution.
#'
#' @param id module id
#' @noRd
mod_pac_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      class = "border-warning bg-warning-subtle mb-3",
      bslib::card_body(
        shiny::tags$div(class = "d-flex align-items-center gap-2",
          shiny::tags$strong("Work in progress"),
          shiny::tags$span(class = "text-muted", "— Analyse PAC en cours de developpement")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Profil horaire moyen de la PAC",
          "Puissance PAC moyenne par heure (0-23h). Compare le fonctionnement actuel (baseline) avec le pilotage optimise. Le fond colore indique le prix moyen par heure : plus c'est rouge, plus c'est cher."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_profil_horaire"), height = "350px"))))
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

    # ---- Helper: get sim data and params (handles cross-contract) ----
    get_sim_params <- function() {
      sim <- sim_filtered()
      sim_c <- sidebar$sim_filtered_cible()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r
      sim_data <- if (!is.null(sim_c)) sim_c else sim
      list(sim = sim_data, params = params)
    }

    # ---- Helper: extract PAC kWh vector ----
    get_pac_kwh <- function(sim, params, type = "baseline") {
      if (type == "optimized") {
        sim$sim_pac_on * params$p_pac_kw * params$dt_h
      } else if ("pac_kwh" %in% names(sim)) {
        sim$pac_kwh
      } else {
        pmax(0, sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac)
      }
    }

    # ---- Helper: compute hourly PAC profile ----
    compute_hourly_profile <- function(sim, params, type = "baseline") {
      pac_kwh <- get_pac_kwh(sim, params, type)
      h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))

      dplyr::tibble(hour = h, pac_kwh = pac_kwh) %>%
        dplyr::group_by(hour) %>%
        dplyr::summarise(
          pac_total_kwh = sum(pac_kwh, na.rm = TRUE),
          pac_moy_kw = mean(pac_kwh, na.rm = TRUE) / params$dt_h,
          .groups = "drop"
        ) %>%
        dplyr::mutate(pct = round(100 * pac_total_kwh / max(sum(pac_total_kwh), 1), 1))
    }

    # ---- Helper: mean price per hour ----
    compute_hourly_prix <- function(sim) {
      h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))
      dplyr::tibble(hour = h, prix = sim$prix_offtake) %>%
        dplyr::group_by(hour) %>%
        dplyr::summarise(prix_moy = mean(prix, na.rm = TRUE), .groups = "drop")
    }

    # ---- Helper: price-to-color (green=cheap, red=expensive) ----
    prix_to_color <- function(prix, alpha = 0.15) {
      rng <- range(prix, na.rm = TRUE)
      span <- max(rng[2] - rng[1], 0.001)
      t <- (prix - rng[1]) / span  # 0=cheapest, 1=most expensive
      r <- round(34 + 205 * t)
      g <- round(139 - 71 * t)
      b <- round(69 - 1 * t)
      sprintf("rgba(%d,%d,%d,%.2f)", r, g, b, alpha)
    }

    # ---- Hourly profile chart with price gradient background ----
    output$plot_profil_horaire <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      sim <- sp$sim; params <- sp$params

      bl <- compute_hourly_profile(sim, params, "baseline")
      op <- compute_hourly_profile(sim, params, "optimized")
      hp <- compute_hourly_prix(sim)

      # Build price-colored background shapes (one rect per hour)
      colors <- prix_to_color(hp$prix_moy, alpha = 0.12)
      shapes <- lapply(seq_len(nrow(hp)), function(i) {
        list(type = "rect", xref = "x", yref = "paper",
          x0 = hp$hour[i] - 0.5, x1 = hp$hour[i] + 0.5,
          y0 = 0, y1 = 1,
          fillcolor = colors[i], line = list(width = 0))
      })

      plotly::plot_ly() %>%
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
        plotly::add_trace(
          data = hp, x = ~hour, y = ~(prix_moy * 1000), name = "Prix moyen",
          type = "scatter", mode = "lines",
          line = list(color = cl$text_muted, width = 1, dash = "dot"),
          yaxis = "y2",
          hovertemplate = "<b>%{x}h</b><br>Prix: %{y:.0f} EUR/MWh<extra></extra>") %>%
        plotly::layout(
          shapes = shapes,
          xaxis = list(dtick = 1, tick0 = 0,
            title = list(text = "Heure", standoff = 10)),
          yaxis2 = list(
            overlaying = "y", side = "right",
            title = list(text = "EUR/MWh", standoff = 5),
            showgrid = FALSE,
            tickfont = list(size = 9, color = cl$text_muted)),
          legend = list(orientation = "h", y = -0.15)
        ) %>%
        pl_layout(ylab = "Puissance PAC moyenne (kW)")
    })

  })
}
