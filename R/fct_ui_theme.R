# =============================================================================
# Theme: load colors from YAML + chart helpers
# =============================================================================

# Load theme YAML and build flat `cl` list for backward compatibility
.theme <- yaml::read_yaml(system.file("theme.yml", package = "wisepocpac"))

cl <- list(
  # UI
  bg_dark    = .theme$ui$bg_dark,
  bg_card    = .theme$ui$bg_card,
  bg_input   = .theme$ui$bg_input,
  text       = .theme$ui$text,
  text_muted = .theme$ui$text_muted,
  text_light = .theme$ui$text_light,
  grid       = .theme$ui$grid,
  # Accents
  accent     = .theme$accent$primary,
  accent2    = .theme$accent$secondary,
  accent3    = .theme$accent$tertiary,
  # Status
  success    = .theme$status$success,
  danger     = .theme$status$danger,
  # Series
  reel       = .theme$series$baseline,
  opti       = .theme$series$optimise,
  pv         = .theme$series$pv,
  pac        = .theme$series$pac,
  prix       = .theme$series$prix,
  external1  = .theme$series$external1,
  external2  = .theme$series$external2,
  external3  = .theme$series$external3,
  # Scenario styles
  scenarios  = .theme$scenarios
)

#' Standard Plotly Layout
#'
#' Applies the Wise light theme layout to a plotly chart.
#' @param p A plotly object
#' @param title Optional chart title
#' @param xlab Optional x-axis label
#' @param ylab Optional y-axis label
#' @param agg_level Optional aggregation level from [auto_aggregate()]:
#'   \code{"15 min"}, \code{"hour"}, \code{"day"}, \code{"week"}.
#'   When provided, adapts x-axis tick format and spacing.
#' @return A plotly object with themed layout
#' @noRd
pl_layout <- function(p, title = NULL, xlab = NULL, ylab = NULL,
                      agg_level = NULL, n_points = NULL) {
  # X-axis: no grid (Tufte: erase non-data-ink), adaptive ticks
  xaxis <- list(title = xlab, gridcolor = "rgba(0,0,0,0)",
    zerolinecolor = cl$grid, tickfont = list(size = 10))

  if (!is.null(agg_level)) {
    # Tick format depends on granularity
    xaxis$tickformat <- switch(agg_level,
      "15 min" = "%H:%M\n%d %b",
      "hour"   = "%H:%M\n%d %b",
      "day"    = "%d %b",
      "week"   = "Sem %V\n%d %b",
      NULL)
    # Adaptive dtick: aim for ~8-12 ticks based on number of data points
    n <- if (!is.null(n_points)) n_points else 50
    step_ms <- switch(agg_level,
      "15 min" = 900000,
      "hour"   = 3600000,
      "day"    = 86400000,
      "week"   = 604800000,
      86400000)
    target_ticks <- 10
    tick_every <- max(1, ceiling(n / target_ticks))
    xaxis$dtick <- step_ms * tick_every
  }

  p %>% plotly::layout(
    title = list(text = title, font = list(color = cl$text, size = 14, family = "Raleway, sans-serif")),
    paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
    font = list(color = cl$text_muted, family = "Raleway, sans-serif", size = 11),
    xaxis = xaxis,
    yaxis = list(title = ylab, gridcolor = cl$grid, zerolinecolor = cl$grid, tickfont = list(size = 10)),
    legend = list(orientation = "h", y = -0.3, yanchor = "top", x = 0.5, xanchor = "center",
      font = list(size = 10)),
    margin = list(t = 50, b = 100, l = 70, r = 70),
    hoverlabel = list(font = list(family = "JetBrains Mono", size = 11))
  )
}

#' Resolve trace configuration for comparison chart
#'
#' For each variable, determines the trace type (bar or line), Y axis,
#' fill behaviour, and line dash based on the aggregation level and
#' variable nature. Rules:
#' - Bars only for summable variables at day/week aggregation
#' - Bars only on y1 axis; y2 is always lines
#' - No fill for mean variables (temperature, price, COP)
#' - Third variable gets dashed line
#'
#' @param vars Character vector of variable names (length 2 or 3)
#' @param agg_level Aggregation level: "15 min", "hour", "day", "week"
#' @param summable Character vector of summable variable names
#' @param unit_fn Function(var) returning the unit string
#' @param unit1 Unit of the first variable (left axis)
#' @param unit2 Unit of the second variable (right axis)
#' @return A named list of lists, one per variable, each with:
#'   \code{type} ("bar"|"line"), \code{axis} ("y"|"y2"),
#'   \code{fill} (logical), \code{dash} (NULL|"dot")
#' @noRd
resolve_trace_config <- function(vars, agg_level, summable, unit_fn,
                                  unit1, unit2) {
  use_bars <- agg_level %in% c("day", "week")
  configs <- list()
  n_bars_y1 <- 0L


  for (i in seq_along(vars)) {
    v <- vars[i]
    is_sum <- v %in% summable
    u <- unit_fn(v)
    # Axis: match unit to y1 or y2
    ax <- if (!is.na(u) && !is.na(unit1) && u == unit1) "y"
          else if (!is.na(u) && !is.na(unit2) && u == unit2) "y2"
          else "y"

    # Trace type: bars only for summable + coarse agg + y1
    if (is_sum && use_bars && ax == "y") {
      type <- "bar"
      n_bars_y1 <- n_bars_y1 + 1L
    } else {
      type <- "line"
    }

    # Fill: only for summable lines at fine resolution (area = energy proxy)
    do_fill <- is_sum && type == "line" && agg_level %in% c("15 min", "hour")

    # Dash: third variable gets dotted line
    dash <- if (i >= 3 && type == "line") "dot" else NULL

    configs[[v]] <- list(type = type, axis = ax, fill = do_fill, dash = dash)
  }

  attr(configs, "n_bars_y1") <- n_bars_y1
  configs
}

#' Grouped Bar Chart (baseline vs optimised)
#'
#' Side-by-side bar chart comparing baseline and optimised values.
#' Baseline is shown at reduced opacity, optimised at full opacity,
#' following dataviz best practices (Tufte, Few, Knaflic): grouped bars
#' with a shared zero baseline enable the most accurate visual comparison.
#' See \code{vignette("conventions-dataviz")} for rationale.
#'
#' @param data Dataframe with \code{timestamp} and the two series columns
#' @param baseline_col Column name for baseline series
#' @param opti_col Column name for optimised series
#' @param ylab Y-axis label
#' @param agg_level Optional aggregation level for x-axis formatting
#' @return A plotly object
#' @export
plot_overlay_bar <- function(data, baseline_col, opti_col, ylab,
                             agg_level = NULL) {
  bl <- data[[baseline_col]]
  op <- data[[opti_col]]

  bl_rgba <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$reel), collapse = ","), ",",
    cl$scenarios$baseline$bar_opacity, ")")
  op_rgba <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$opti), collapse = ","), ",",
    cl$scenarios$optimise$bar_opacity, ")")

  hover_bl <- sprintf("Baseline: %.1f", bl)
  hover_op <- sprintf("Optimis\u00e9: %.1f", op)

  plotly::plot_ly(data, x = ~timestamp) %>%
    plotly::add_bars(y = bl, name = "Baseline",
      marker = list(color = bl_rgba),
      text = hover_bl, hoverinfo = "text+x", textposition = "none") %>%
    plotly::add_bars(y = op, name = "Optimise",
      marker = list(color = op_rgba),
      text = hover_op, hoverinfo = "text+x", textposition = "none") %>%
    plotly::layout(barmode = "group", bargap = 0.1) %>%
    pl_layout(ylab = ylab, agg_level = agg_level, n_points = nrow(data))
}

#' Cumulative comparison chart (baseline vs optimised)
#'
#' Two-line chart with dashed baseline and solid optimised, showing
#' the cumulative gap. Used for both finances and CO2.
#'
#' @param data Dataframe with \code{timestamp}, \code{cum_baseline}, \code{cum_opti}
#' @param ylab Y-axis label
#' @param unit Unit string for hover (e.g. "EUR", "kg")
#' @param baseline_label Legend label for baseline
#' @param opti_label Legend label for optimised
#' @param delta_label Hover label for the gap (e.g. "Economie cumulee", "CO2 evite")
#' @return A plotly object
#' @noRd
plot_cumulative <- function(data, ylab, unit = "",
                            baseline_label = "Baseline",
                            opti_label = "Optimise",
                            delta_label = "Delta") {
  d <- data
  d$eco <- d$cum_baseline - d$cum_opti

  bl_fill <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$reel), collapse = ","), ",",
    cl$scenarios$baseline$fill_opacity, ")")
  op_fill <- paste0("rgba(",
    paste(grDevices::col2rgb(cl$opti), collapse = ","), ",",
    cl$scenarios$optimise$fill_opacity, ")")

  plotly::plot_ly(d, x = ~timestamp) %>%
    plotly::add_trace(y = ~cum_baseline, type = "scatter", mode = "lines",
      name = baseline_label,
      line = list(color = cl$reel, width = 2,
        dash = cl$scenarios$baseline$line_dash),
      fill = "tozeroy", fillcolor = bl_fill,
      customdata = ~eco,
      hovertemplate = paste0(
        "<b>", baseline_label, "</b>: %{y:.1f} ", unit, "<br>",
        delta_label, ": %{customdata:.1f} ", unit,
        "<extra>", baseline_label, "</extra>")) %>%
    plotly::add_trace(y = ~cum_opti, type = "scatter", mode = "lines",
      name = opti_label,
      line = list(color = cl$opti, width = 2,
        dash = cl$scenarios$optimise$line_dash),
      fill = "tozeroy", fillcolor = op_fill,
      customdata = ~eco,
      hovertemplate = paste0(
        "<b>", opti_label, "</b>: %{y:.1f} ", unit, "<br>",
        delta_label, ": %{customdata:.1f} ", unit,
        "<extra>", opti_label, "</extra>")) %>%
    pl_layout(ylab = ylab)
}

#' Card header with info tooltip
#'
#' @param title Card title
#' @param tooltip Tooltip text explaining the chart
#' @return A bslib card_header tag
#' @noRd
card_header_tip <- function(title, tooltip) {
  bslib::card_header(shiny::tags$span(title, " ", tip(tooltip)))
}

#' Inline Info Tooltip
#'
#' Creates a small "i" circle with a native HTML tooltip.
#' @param text The tooltip text
#' @return A shiny tag
#' @noRd
tip <- function(text) {
  shiny::tags$span(class = "info-tip", title = text, "i")
}

#' KPI Card
#'
#' Renders a KPI display with value, label, optional baseline comparison and gain.
#' @param value The formatted KPI value to display
#' @param label The KPI label
#' @param unit The unit string
#' @param color The accent color for the value
#' @param baseline_val Optional baseline value for relative comparison
#' @param opti_val Optional optimized value for relative comparison
#' @param gain_val Optional gain value
#' @param gain_unit Optional unit for gain (defaults to unit)
#' @param gain_invert If TRUE, negative gain is "positive" (green)
#' @param tooltip Optional tooltip text
#' @return A shiny tag div
#' @noRd
kpi_card <- function(value, label, unit, color,
                     baseline_val = NULL, opti_val = NULL,
                     gain_val = NULL, gain_unit = NULL, gain_invert = FALSE,
                     tooltip = NULL, is_percentage = FALSE) {
  val_div <- shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;", color),
    value, shiny::tags$span(class = "kpi-unit", unit))

  label_div <- if (!is.null(tooltip)) {
    shiny::tags$div(class = "kpi-label", label, tip(tooltip))
  } else {
    shiny::tags$div(class = "kpi-label", label)
  }

  sub_divs <- list()

  # Relative % vs baseline

  if (!is.null(baseline_val) && !is.null(opti_val) && abs(baseline_val) > 0.001) {
    if (is_percentage) {
      # For metrics already in % (AC, autosuffisance): show point difference
      diff_pts <- opti_val - baseline_val
      cls <- if (gain_invert) {
        if (diff_pts <= 0) "positive" else "negative"
      } else {
        if (diff_pts >= 0) "positive" else "negative"
      }
      sub_divs <- c(sub_divs, list(
        shiny::tags$div(class = "kpi-sub",
          sprintf("baseline: %.0f%%", baseline_val))
      ))
    } else {
      # For absolute values (kWh, EUR): show relative % change
      pct <- (opti_val - baseline_val) / abs(baseline_val) * 100
      cls <- if (gain_invert) {
        if (pct <= 0) "positive" else "negative"
      } else {
        if (pct >= 0) "positive" else "negative"
      }
      sub_divs <- c(sub_divs, list(
        shiny::tags$div(class = "kpi-sub",
          sprintf("%s%.1f%% vs baseline", ifelse(pct >= 0, "+", ""), pct))
      ))
    }
  }

  # Gain/reduction line
  if (!is.null(gain_val)) {
    gu <- if (!is.null(gain_unit)) gain_unit else unit
    cls <- if (gain_invert) {
      if (gain_val <= 0) "positive" else "negative"
    } else {
      if (gain_val >= 0) "positive" else "negative"
    }
    arrow <- if (gain_val > 0) "\u25b2" else if (gain_val < 0) "\u25bc" else ""
    sub_divs <- c(sub_divs, list(
      shiny::tags$div(class = paste("kpi-gain", cls),
        sprintf("%s %s%s %s", arrow, ifelse(gain_val >= 0, "+", ""),
          formatC(round(gain_val), big.mark = " ", format = "d"), gu))
    ))
  }

  do.call(shiny::tags$div, c(list(class = "text-center"), list(val_div, label_div), sub_divs))
}

#' Explainer Panel
#'
#' Creates a collapsible explanatory panel for tab content.
#' @param ... Content tags (summary + body)
#' @return A shiny tags$details element
#' @noRd
explainer <- function(...) {
  shiny::tags$details(class = "tab-explainer", ...)
}
