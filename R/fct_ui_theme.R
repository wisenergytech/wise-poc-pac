#' Wise Color Palette
#'
#' Named list of all color constants used in the dashboard theme.
#' Based on the Wise brand identity (wise-standards).
#' @noRd
cl <- list(
  bg_dark    = "#F6F7F8",    # app background
  bg_card    = "#FFFFFF",    # card/surface
  bg_input   = "#EDF0F4",   # input backgrounds
  accent     = "#1D4345",    # primary (deep green)

  accent2    = "#E9A345",    # secondary (gold)
  accent3    = "#0D9488",    # tertiary (teal)
  success    = "#059669",    # success green
  danger     = "#DC2626",    # danger red
  text       = "#171616",    # primary text
  text_muted = "#475569",    # muted text
  text_light = "#FFFFFF",    # text on dark backgrounds
  grid       = "#E2E8F0",    # borders/grid lines
  reel       = "#D97706",    # baseline/real (amber)
  opti       = "#1D4345",    # optimized (deep green)
  pv         = "#F59E0B",    # solar PV (bright amber)
  pac        = "#059669",    # heat pump (emerald)
  prix       = "#0D9488"     # price (teal)
)

#' Standard Plotly Layout
#'
#' Applies the Wise light theme layout to a plotly chart.
#' @param p A plotly object
#' @param title Optional chart title
#' @param xlab Optional x-axis label
#' @param ylab Optional y-axis label
#' @return A plotly object with themed layout
#' @noRd
pl_layout <- function(p, title = NULL, xlab = NULL, ylab = NULL) {
  p %>% plotly::layout(
    title = list(text = title, font = list(color = cl$text, size = 14, family = "Raleway, sans-serif")),
    paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
    font = list(color = cl$text_muted, family = "Raleway, sans-serif", size = 11),
    xaxis = list(title = xlab, gridcolor = cl$grid, zerolinecolor = cl$grid, tickfont = list(size = 10)),
    yaxis = list(title = ylab, gridcolor = cl$grid, zerolinecolor = cl$grid, tickfont = list(size = 10)),
    legend = list(orientation = "h", y = -0.3, yanchor = "top", x = 0.5, xanchor = "center",
      font = list(size = 10)),
    margin = list(t = 50, b = 100, l = 70, r = 70),
    hoverlabel = list(font = list(family = "JetBrains Mono", size = 11))
  )
}

#' Overlay Bar Chart (baseline vs optimised)
#'
#' Creates a stacked bar chart where for each period the bar height equals
#' \code{max(baseline, opti)}. The bottom portion (0 to min) is coloured as the
#' smaller series and the top portion (min to max) as the larger one.
#' This visually shows that one value is contained within the other.
#'
#' No Shiny dependency -- can be used standalone for reporting.
#'
#' @param data A dataframe with a \code{timestamp} column and the two series
#'   to compare
#' @param baseline_col Character. Column name for the baseline series
#' @param opti_col Character. Column name for the optimised series
#' @param ylab Character. Y-axis label (e.g. \code{"kWh (horaire)"})
#' @return A \pkg{plotly} object
#'
#' @examples
#' df <- data.frame(
#'   timestamp = seq(as.POSIXct("2025-01-01"), by = "hour", length.out = 24),
#'   soutirage_baseline = runif(24, 1, 5),
#'   soutirage_opti = runif(24, 0.5, 4)
#' )
#' plot_overlay_bar(df, "soutirage_baseline", "soutirage_opti", "kWh")
#' @export
plot_overlay_bar <- function(data, baseline_col, opti_col, ylab) {
  bl <- data[[baseline_col]]
  op <- data[[opti_col]]

  bottom <- pmin(bl, op)
  top    <- pmax(bl, op) - bottom

  bl_bigger <- bl > op
  bottom_color <- ifelse(bl_bigger, cl$opti, cl$reel)
  top_color    <- ifelse(bl_bigger, cl$reel, cl$opti)

  hover_text <- sprintf("Baseline: %.1f<br>Optimis\u00e9: %.1f", bl, op)

  plotly::plot_ly(data, x = ~timestamp) %>%
    plotly::add_bars(y = bottom, name = "Commun",
      marker = list(color = bottom_color), showlegend = FALSE,
      text = hover_text, hoverinfo = "text+x") %>%
    plotly::add_bars(y = top, name = "Delta",
      marker = list(color = top_color), showlegend = FALSE,
      text = hover_text, hoverinfo = "text+x") %>%
    plotly::add_bars(y = 0, name = "Baseline", marker = list(color = cl$reel),
      showlegend = TRUE, hoverinfo = "skip") %>%
    plotly::add_bars(y = 0, name = "Optimise", marker = list(color = cl$opti),
      showlegend = TRUE, hoverinfo = "skip") %>%
    plotly::layout(barmode = "stack", bargap = 0.1) %>%
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
