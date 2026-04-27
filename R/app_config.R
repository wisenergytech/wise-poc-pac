#' Access files in the current app
#' @param ... path components
#' @noRd
app_sys <- function(...) {
  system.file(..., package = "wisepocpac")
}

#' Read App Config
#' @param value key to read
#' @param config config name (default: Sys.getenv("R_CONFIG_ACTIVE", "default"))
#' @noRd
get_golem_config <- function(value, config = Sys.getenv("R_CONFIG_ACTIVE", "default")) {
  golem::get_golem_config(value, config = config)
}

#' Read UI config from inst/config.yml
#'
#' Returns the `ui` section of the config, controlling which optimizers,
#' PV sources, strategies, and battery option are shown in the sidebar.
#' Profile is selected via R_CONFIG_ACTIVE env var (default: "default").
#'
#' @return A list with: optimizers, pv_sources, show_battery, strategies
#' @noRd
get_ui_config <- function() {
  cfg_file <- app_sys("config.yml")
  if (!file.exists(cfg_file)) cfg_file <- "inst/config.yml"
  if (!file.exists(cfg_file)) {
    # Fallback: everything enabled
    return(list(
      optimizers = c("optimiseur", "optimiseur_lp", "optimiseur_qp"),
      pv_sources = c("synthetic", "real_elia", "real_delaunoy"),
      show_battery = TRUE,
      strategies = list(tou = TRUE, curtailment = TRUE)
    ))
  }
  active <- Sys.getenv("R_CONFIG_ACTIVE", "default")
  cfg <- config::get(config = active, file = cfg_file)
  cfg$ui
}
