#' Wise bslib Theme
#'
#' Returns the Wise Bootstrap 5 theme for use in bslib page layouts.
#' @importFrom bslib bs_theme font_google
#' @noRd
wise_theme <- function() {
  bslib::bs_theme(
    version = 5,
    bg = "#F6F7F8",
    fg = "#171616",
    primary = "#1D4345",
    secondary = "#E9A345",
    success = "#059669",
    warning = "#F59E0B",
    danger = "#DC2626",
    base_font = bslib::font_google("Raleway"),
    heading_font = bslib::font_google("Raleway"),
    code_font = bslib::font_google("JetBrains Mono"),
    "navbar-bg" = "#1D4345",
    "card-bg" = "#FFFFFF",
    "card-border-color" = "#E2E8F0",
    # Input styling
    "input-bg" = "#FFFFFF",
    "input-color" = "#171616",
    "input-border-color" = "#E2E8F0",
    "input-placeholder-color" = "#94A3B8",
    # Tabs
    "nav-tabs-link-active-bg" = "#FFFFFF",
    "nav-tabs-link-active-color" = "#1D4345",
    # Sidebar
    "sidebar-bg" = "#FFFFFF"
  ) |> bslib::bs_add_rules("
    .card { border-left: 3px solid $primary; }
    .sidebar { border-right: 1px solid $secondary; }
  ")
}
