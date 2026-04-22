#' PAC Optimizer Color Constants
#'
#' Named list of all color constants used in the dashboard theme.
#' @noRd
cl <- list(
  bg_dark = "#0f1117", bg_card = "#1a1d27", bg_input = "#252833",
  accent = "#22d3ee", accent2 = "#f97316", accent3 = "#a78bfa",
  success = "#34d399", danger = "#f87171",
  text = "#e2e8f0", text_muted = "#94a3b8", grid = "#2d3348",
  reel = "#f97316", opti = "#22d3ee", pv = "#fbbf24", pac = "#34d399", prix = "#a78bfa"
)

#' PAC Optimizer bslib Theme
#'
#' Returns the bslib bs_theme configured for the dark dashboard.
#' @return A bslib theme object
#' @noRd
pac_theme <- function() {
  bslib::bs_theme(
    version = 5, bg = cl$bg_dark, fg = cl$text, primary = cl$accent,
    secondary = cl$bg_card, success = cl$success, danger = cl$danger,
    base_font = bslib::font_google("IBM Plex Sans"),
    code_font = bslib::font_google("JetBrains Mono"),
    "input-bg" = cl$bg_input, "input-color" = cl$text, "input-border-color" = cl$grid,
    "card-bg" = cl$bg_card, "nav-tabs-link-active-bg" = cl$bg_card,
    "nav-tabs-link-active-color" = cl$accent
  )
}

#' Standard Plotly Layout
#'
#' Applies the PAC dark theme layout to a plotly chart.
#' @param p A plotly object
#' @param title Optional chart title
#' @param xlab Optional x-axis label
#' @param ylab Optional y-axis label
#' @return A plotly object with themed layout
#' @noRd
pl_layout <- function(p, title = NULL, xlab = NULL, ylab = NULL) {
  p %>% plotly::layout(
    title = list(text = title, font = list(color = cl$text, size = 14, family = "JetBrains Mono, monospace")),
    paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
    font = list(color = cl$text_muted, family = "JetBrains Mono, monospace", size = 11),
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
#' No Shiny dependency — can be used standalone for reporting.
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

  plotly::plot_ly(data, x = ~timestamp) %>%
    plotly::add_bars(y = bottom, name = "Commun",
      marker = list(color = bottom_color), showlegend = FALSE,
      hovertemplate = paste0(
        "Baseline: %{customdata[0]:.1f}<br>",
        "Optimise: %{customdata[1]:.1f}<extra></extra>"),
      customdata = cbind(bl, op)) %>%
    plotly::add_bars(y = top, name = "Delta",
      marker = list(color = top_color), showlegend = FALSE,
      hovertemplate = paste0(
        "Baseline: %{customdata[0]:.1f}<br>",
        "Optimise: %{customdata[1]:.1f}<extra></extra>"),
      customdata = cbind(bl, op)) %>%
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
                     tooltip = NULL) {
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
