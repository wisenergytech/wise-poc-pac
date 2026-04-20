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
