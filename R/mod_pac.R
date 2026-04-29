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
    shiny::uiOutput(ns("pac_kpi_row")),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Profil horaire moyen de la PAC",
          "Puissance PAC moyenne par heure (0-23h). Compare le fonctionnement actuel (baseline) avec le pilotage optimise. Le fond colore indique le prix moyen par heure : plus c'est rouge, plus c'est cher."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_profil_horaire"), height = "350px")))),
    bslib::layout_columns(col_widths = c(6, 6),
      bslib::card(full_screen = TRUE,
        card_header_tip("A quel prix la PAC achete-t-elle ?",
          "Repartition des kWh PAC par tranche de prix (du moins cher au plus cher). Un bon pilotage concentre la conso dans les tranches basses."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_prix_distribution"), height = "300px"))),
      bslib::card(full_screen = TRUE,
        card_header_tip("Distribution horaire de la conso PAC",
          "Repartition de la conso PAC par heure (% du total). La couleur reflète le prix moyen de l'heure."),
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

    # ---- KPI row ----
    output$pac_kpi_row <- shiny::renderUI({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      sim_data <- sp$sim; params <- sp$params

      kpi <- KPICalculator$new()
      prix_bl <- kpi$get_prix_moyen_pac(sim_data, params, "baseline")
      prix_op <- kpi$get_prix_moyen_pac(sim_data, params, "optimized")

      pac_bl <- sum(get_pac_kwh(sim_data, params, "baseline"), na.rm = TRUE)
      pac_op <- sum(get_pac_kwh(sim_data, params, "optimized"), na.rm = TRUE)

      # Cheapest quartile analysis (universal replacement for peak/off-peak)
      prix <- sim_data$prix_offtake
      q25 <- stats::quantile(prix, 0.25, na.rm = TRUE)
      is_cheap <- prix <= q25
      pac_bl_vec <- get_pac_kwh(sim_data, params, "baseline")
      pac_op_vec <- get_pac_kwh(sim_data, params, "optimized")
      pct_cheap_bl <- round(100 * sum(pac_bl_vec[is_cheap], na.rm = TRUE) / max(sum(pac_bl_vec, na.rm = TRUE), 1), 1)
      pct_cheap_op <- round(100 * sum(pac_op_vec[is_cheap], na.rm = TRUE) / max(sum(pac_op_vec, na.rm = TRUE), 1), 1)

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
        kpi_card(sprintf("%.1f%%", pct_cheap_bl),
          "PAC en heures bon marche", "", cl$success,
          baseline_val = pct_cheap_bl, opti_val = pct_cheap_op,
          gain_val = round(pct_cheap_op - pct_cheap_bl, 1), gain_unit = "pts",
          is_percentage = TRUE,
          tooltip = "Part de la conso PAC dans le quartile de prix le moins cher (25% du temps). Un thermostat aveugle serait a ~25%.")
      )
      bslib::layout_columns(col_widths = rep(4, 3), !!!kpis)
    })

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

    # ---- Price distribution of PAC consumption ----
    output$plot_prix_distribution <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      sim <- sp$sim; params <- sp$params

      pac_bl <- get_pac_kwh(sim, params, "baseline")
      pac_op <- get_pac_kwh(sim, params, "optimized")
      prix <- sim$prix_offtake * 1000  # EUR/MWh for display

      # Create 5 price bins
      breaks <- stats::quantile(prix, probs = seq(0, 1, 0.2), na.rm = TRUE)
      # Ensure unique breaks
      breaks <- unique(breaks)
      if (length(breaks) < 3) {
        breaks <- seq(min(prix, na.rm = TRUE), max(prix, na.rm = TRUE), length.out = 6)
      }
      labels <- paste0(round(breaks[-length(breaks)]), "-", round(breaks[-1]))
      bin_bl <- cut(prix, breaks = breaks, labels = labels, include.lowest = TRUE)
      bin_op <- cut(prix, breaks = breaks, labels = labels, include.lowest = TRUE)

      df_bl <- dplyr::tibble(bin = bin_bl, kwh = pac_bl) %>%
        dplyr::filter(!is.na(bin)) %>%
        dplyr::group_by(bin) %>%
        dplyr::summarise(kwh = sum(kwh, na.rm = TRUE), .groups = "drop") %>%
        dplyr::mutate(pct = round(100 * kwh / max(sum(kwh), 1), 1), scenario = "Baseline")

      df_op <- dplyr::tibble(bin = bin_op, kwh = pac_op) %>%
        dplyr::filter(!is.na(bin)) %>%
        dplyr::group_by(bin) %>%
        dplyr::summarise(kwh = sum(kwh, na.rm = TRUE), .groups = "drop") %>%
        dplyr::mutate(pct = round(100 * kwh / max(sum(kwh), 1), 1), scenario = "Optimise")

      df <- rbind(df_bl, df_op)
      df$scenario <- factor(df$scenario, levels = c("Baseline", "Optimise"))

      # Color bins from green (cheap) to red (expensive)
      n_bins <- length(labels)
      t_vals <- seq(0, 1, length.out = n_bins)
      bin_colors <- sprintf("rgba(%d,%d,%d,%%s)",
        round(34 + 205 * t_vals),
        round(139 - 71 * t_vals),
        round(69 - 1 * t_vals))

      bl_rgba <- sprintf(bin_colors, 0.6)
      op_rgba <- sprintf(bin_colors, 0.85)

      plotly::plot_ly() %>%
        plotly::add_bars(
          data = df_bl, x = ~bin, y = ~pct, name = "Baseline",
          text = ~paste0(pct, "%"), textposition = "outside",
          textfont = list(size = 9, family = "JetBrains Mono"),
          marker = list(color = bl_rgba),
          hovertemplate = "<b>%{x} EUR/MWh</b><br>Baseline: %{y:.1f}% (%{customdata:.0f} kWh)<extra></extra>",
          customdata = ~kwh) %>%
        plotly::add_bars(
          data = df_op, x = ~bin, y = ~pct, name = "Optimise",
          text = ~paste0(pct, "%"), textposition = "outside",
          textfont = list(size = 9, family = "JetBrains Mono"),
          marker = list(color = op_rgba),
          hovertemplate = "<b>%{x} EUR/MWh</b><br>Optimise: %{y:.1f}% (%{customdata:.0f} kWh)<extra></extra>",
          customdata = ~kwh) %>%
        plotly::layout(
          barmode = "group", bargap = 0.15,
          xaxis = list(title = list(text = "Tranche de prix (EUR/MWh)", standoff = 10))
        ) %>%
        pl_layout(ylab = "% conso PAC")
    })

    # ---- Hourly distribution bars with price-colored bars ----
    output$plot_hourly_dist <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      sim <- sp$sim; params <- sp$params

      bl <- compute_hourly_profile(sim, params, "baseline")
      op <- compute_hourly_profile(sim, params, "optimized")
      hp <- compute_hourly_prix(sim)

      # Color bars by hourly price
      colors_bl <- prix_to_color(hp$prix_moy, alpha = 0.55)
      colors_op <- prix_to_color(hp$prix_moy, alpha = 0.80)

      plotly::plot_ly() %>%
        plotly::add_bars(
          data = bl, x = ~hour, y = ~pct, name = "Baseline",
          marker = list(color = colors_bl),
          hovertemplate = "<b>%{x}h</b><br>Baseline: %{y:.1f}%<extra></extra>") %>%
        plotly::add_bars(
          data = op, x = ~hour, y = ~pct, name = "Optimise",
          marker = list(color = colors_op),
          hovertemplate = "<b>%{x}h</b><br>Optimise: %{y:.1f}%<extra></extra>") %>%
        plotly::layout(
          barmode = "group", bargap = 0.15,
          xaxis = list(dtick = 1, tick0 = 0,
            title = list(text = "Heure", standoff = 10))
        ) %>%
        pl_layout(ylab = "% conso PAC")
    })
  })
}
