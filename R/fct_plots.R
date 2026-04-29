# =============================================================================
# Shared plot functions used by both Shiny modules and presentation export
# =============================================================================

#' Bar chart: PAC consumption by time slot (tranche horaire)
#'
#' @param tranche_data Data frame with columns: tranche, kwh, pct, prix_moyen, scenario
#' @return A plotly object
#' @noRd
plot_pac_tranches <- function(tranche_data) {
  bl <- tranche_data[tranche_data$scenario == "Baseline", ]
  op <- tranche_data[tranche_data$scenario == "Optimise", ]

  bl_rgba <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$reel), collapse = ","), ",",
    cl$scenarios$baseline$bar_opacity, ")")
  op_rgba <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$opti), collapse = ","), ",",
    cl$scenarios$optimise$bar_opacity, ")")

  p <- plotly::plot_ly() %>%
    plotly::add_bars(
      data = bl, x = ~tranche, y = ~kwh, name = "Baseline",
      text = ~paste0(pct, "%"), textposition = "outside",
      textfont = list(size = 10, family = "JetBrains Mono"),
      marker = list(color = bl_rgba),
      hovertemplate = "<b>%{x}</b><br>Baseline: %{y:.0f} kWh (%{text})<br>Prix moyen: %{customdata:.0f} EUR/MWh<extra></extra>",
      customdata = ~prix_moyen) %>%
    plotly::add_bars(
      data = op, x = ~tranche, y = ~kwh, name = "Optimise",
      text = ~paste0(pct, "%"), textposition = "outside",
      textfont = list(size = 10, family = "JetBrains Mono"),
      marker = list(color = op_rgba),
      hovertemplate = "<b>%{x}</b><br>Optimise: %{y:.0f} kWh (%{text})<br>Prix moyen: %{customdata:.0f} EUR/MWh<extra></extra>",
      customdata = ~prix_moyen)

  for (i in seq_len(nrow(bl))) {
    p <- p %>% plotly::add_annotations(
      x = bl$tranche[i], y = bl$kwh[i] + max(bl$kwh) * 0.12,
      text = paste0(round(bl$prix_moyen[i]), " EUR/MWh"),
      showarrow = FALSE, font = list(size = 9, color = cl$text_muted))
  }

  p %>%
    plotly::layout(barmode = "group", bargap = 0.15) %>%
    pl_layout(ylab = "kWh")
}

#' Price-to-color gradient (green = cheap, red = expensive)
#'
#' @param prix Numeric vector of prices
#' @param alpha Opacity (default 0.15)
#' @return Character vector of rgba colors
#' @noRd
prix_to_color <- function(prix, alpha = 0.15) {
  rng <- range(prix, na.rm = TRUE)
  span <- max(rng[2] - rng[1], 0.001)
  t <- (prix - rng[1]) / span
  r <- round(34 + 205 * t)
  g <- round(139 - 71 * t)
  b <- round(69 - 1 * t)
  sprintf("rgba(%d,%d,%d,%.2f)", r, g, b, alpha)
}

#' Cumulative CO2 emissions chart (baseline vs optimised)
#'
#' Computes cumulative CO2 from impact data and renders a cumulative
#' comparison chart. Used by both mod_co2 and presentation export.
#'
#' @param sim_data Simulation dataframe with \code{timestamp} column
#' @param co2_impact Result from \code{compute_co2_impact()}, with
#'   \code{co2_baseline_g} and \code{co2_opti_g} columns
#' @return A plotly object
#' @noRd
plot_co2_cumul <- function(sim_data, co2_impact) {
  d <- data.frame(
    timestamp = sim_data$timestamp,
    cum_baseline = cumsum(ifelse(is.na(co2_impact$co2_baseline_g), 0,
                                 co2_impact$co2_baseline_g)) / 1000,
    cum_opti = cumsum(ifelse(is.na(co2_impact$co2_opti_g), 0,
                              co2_impact$co2_opti_g)) / 1000
  )
  d <- d %>%
    dplyr::mutate(.h = lubridate::floor_date(timestamp, "hour")) %>%
    dplyr::group_by(.h) %>%
    dplyr::slice_tail(n = 1) %>%
    dplyr::ungroup() %>%
    dplyr::select(timestamp, cum_baseline, cum_opti)
  plot_cumulative(d, ylab = "Emissions CO2 cumulees (kg)", unit = "kg",
    baseline_label = "Baseline", opti_label = "Optimise",
    delta_label = "CO2 evite")
}

#' Line chart: hourly PAC profile with price gradient background
#'
#' @param profil_data Data frame with columns: hour, pac_moy_kw, scenario
#' @param profil_prix Data frame with columns: hour, prix_moy
#' @return A plotly object
#' @noRd
plot_profil_horaire <- function(profil_data, profil_prix) {
  bl <- profil_data[profil_data$scenario == "Baseline", ]
  op <- profil_data[profil_data$scenario == "Optimise", ]
  hp <- profil_prix

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
      data = hp, x = ~hour, y = ~(prix_moy * 1000), name = "Prix spot Belpex",
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
}
