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

#' Get the date range covered by all .rda package data
#'
#' Inspects the lazy-loaded package data objects (entsoe_prices, elia_co2,
#' openmeteo_temperature, elia_solar) and returns the intersection of their
#' date ranges — i.e. the period covered by ALL datasets.
#'
#' @return A list with \code{min} and \code{max} (Date), or NULL if no data found
#' @noRd
get_rda_date_range <- function() {
  mins <- c()
  maxs <- c()

  # Helper: try package namespace first, then global env
  try_load <- function(name, date_col) {
    obj <- NULL
    if (exists(name, where = asNamespace("wisepocpac"), inherits = FALSE)) {
      obj <- get(name, envir = asNamespace("wisepocpac"))
    } else if (exists(name, envir = .GlobalEnv)) {
      obj <- get(name, envir = .GlobalEnv)
    }
    if (!is.null(obj) && date_col %in% names(obj)) {
      list(min = min(obj[[date_col]], na.rm = TRUE),
           max = max(obj[[date_col]], na.rm = TRUE))
    } else {
      NULL
    }
  }

  datasets <- list(
    list(name = "entsoe_prices", col = "datetime"),
    list(name = "elia_co2", col = "datetime"),
    list(name = "openmeteo_temperature", col = "timestamp"),
    list(name = "elia_solar", col = "datetime")
  )

  for (ds in datasets) {
    r <- try_load(ds$name, ds$col)
    if (!is.null(r)) {
      mins <- c(mins, as.Date(r$min))
      maxs <- c(maxs, as.Date(r$max))
    }
  }

  if (length(mins) == 0) return(NULL)

  list(min = max(mins), max = min(maxs))
}
