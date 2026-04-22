# =============================================================================
# R6 Class: Simulation (Orchestrator)
# =============================================================================
# Top-level class that orchestrates the full simulation workflow:
# load_data -> run_baseline -> run_optimization -> get_kpi -> export_csv.
# Ties together all other R6 classes.
# =============================================================================

#' @title Simulation Orchestrator
#' @description R6 class orchestrating the full simulation workflow. This is
#'   the main entry point for running PAC optimization simulations without Shiny.
#' @export
Simulation <- R6::R6Class("Simulation",
  public = list(
    #' @description Create a new Simulation.
    #' @param params A SimulationParams R6 object or a plain list of parameters
    initialize = function(params) {
      if (inherits(params, "SimulationParams")) {
        private$params_obj <- params
        private$params <- params$as_list()
      } else {
        private$params <- params
      }
      private$thermal_model <- ThermalModel$new(private$params)
      private$kpi_calc <- KPICalculator$new()
      private$status <- "idle"
    },

    #' @description Load input data from demo generator or CSV file.
    #' @param source Data source: "demo" (synthetic) or "csv" (file import)
    #' @param file Path to CSV file (required if source = "csv")
    #' @param date_start Start date (for demo mode, Date)
    #' @param date_end End date (for demo mode, Date)
    #' @param p_pac_kw PAC power for demo generation (default from params)
    #' @param volume_ballon_l Tank volume for demo generation (default from params)
    #' @param pv_kwc PV capacity for demo generation (default from params)
    #' @param ecs_kwh_jour Daily ECS consumption for demo (NULL = auto)
    #' @param building_type Building type for demo: "passif", "standard", "ancien"
    #' @param data_provider Optional DataProvider instance
    #' @return self (for chaining)
    load_data = function(source = "demo", file = NULL,
                         date_start = NULL, date_end = NULL,
                         p_pac_kw = NULL, volume_ballon_l = NULL, pv_kwc = NULL,
                         ecs_kwh_jour = NULL, building_type = "standard",
                         data_provider = NULL) {
      private$status <- "loading"

      if (source == "csv") {
        if (is.null(file)) stop("file parameter required for CSV source")
        private$raw_data <- readr::read_csv(file, show_col_types = FALSE) %>%
          dplyr::mutate(timestamp = lubridate::ymd_hms(timestamp))
      } else {
        # Demo mode
        if (is.null(date_start)) date_start <- as.Date("2025-02-01")
        if (is.null(date_end)) date_end <- as.Date("2025-07-31")

        gen <- DataGenerator$new(data_provider)
        private$raw_data <- gen$generate_demo(
          date_start = date_start,
          date_end = date_end,
          p_pac_kw = if (!is.null(p_pac_kw)) p_pac_kw else private$params$p_pac_kw,
          volume_ballon_l = if (!is.null(volume_ballon_l)) volume_ballon_l else private$params$volume_ballon_l,
          pv_kwc = if (!is.null(pv_kwc)) pv_kwc else private$params$pv_kwc,
          ecs_kwh_jour = ecs_kwh_jour,
          building_type = building_type
        )
      }

      # Prepare the data
      gen <- DataGenerator$new(data_provider)
      result <- gen$prepare_df(private$raw_data, private$params)
      private$prepared_data <- result$df
      private$params <- result$params  # May have been updated (perte_kwh_par_qt)

      private$status <- "data_loaded"
      invisible(self)
    },

    #' @description Load a pre-existing raw dataframe (e.g. from a Shiny reactive).
    #'   Runs prepare_df() internally to produce the prepared data.
    #' @param df A raw dataframe (from generer_demo, CSV upload, or any source)
    #' @param data_provider Optional DataProvider instance
    #' @return self (for chaining)
    load_raw_dataframe = function(df, data_provider = NULL) {
      private$status <- "loading"
      private$raw_data <- df

      gen <- DataGenerator$new(data_provider)
      result <- gen$prepare_df(private$raw_data, private$params)
      private$prepared_data <- result$df
      private$params <- result$params

      private$status <- "data_loaded"
      invisible(self)
    },

    #' @description Run the baseline simulation.
    #' @param mode Baseline mode: \code{"thermostat"} (default) or
    #'   \code{"pv_tracking"}. Legacy names are mapped automatically.
    #' @return self (for chaining)
    run_baseline = function(mode = NULL) {
      if (is.null(private$prepared_data)) stop("Call load_data() first")

      if (is.null(mode)) mode <- private$params$baseline_mode %||% "thermostat"

      private$status <- "running_baseline"

      baseline <- Baseline$new(private$thermal_model)
      private$baseline_result <- baseline$run(
        private$prepared_data, private$params, mode = mode
      )

      private$status <- "baseline_done"
      invisible(self)
    },

    #' @description Run the optimization.
    #' @param mode Optimization mode: "smart", "milp", "lp" (default), or "qp"
    #' @return self (for chaining)
    run_optimization = function(mode = "lp") {
      if (is.null(private$baseline_result)) stop("Call run_baseline() first")

      private$status <- "running_optimization"

      # Create the appropriate optimizer
      optimizer <- switch(mode,
        smart = SmartOptimizer$new(private$params, private$baseline_result),
        milp  = MILPOptimizer$new(private$params, private$baseline_result),
        lp    = LPOptimizer$new(private$params, private$baseline_result),
        qp    = QPOptimizer$new(private$params, private$baseline_result),
        stop(sprintf("Unknown optimization mode: %s", mode))
      )

      private$optim_result <- optimizer$solve()

      # Guard against regression
      optimizer$guard_baseline(private$baseline_result)
      private$optim_result <- optimizer$get_results()

      private$status <- "done"
      invisible(self)
    },

    #' @description Get the optimization results.
    #' @return Dataframe with simulation columns, or NULL
    get_results = function() private$optim_result,

    #' @description Get the baseline results.
    #' @return Dataframe with baseline columns, or NULL
    get_baseline = function() private$baseline_result,

    #' @description Get the prepared input data.
    #' @return Prepared dataframe, or NULL
    get_prepared_data = function() private$prepared_data,

    #' @description Compute and return KPIs.
    #' @return Named list of KPIs
    get_kpi = function() {
      if (is.null(private$optim_result) || is.null(private$baseline_result)) {
        stop("Call run_baseline() and run_optimization() first")
      }
      private$kpi_calc$compute(
        private$optim_result, private$baseline_result, private$params
      )
    },

    #' @description Get current simulation status.
    #' @return Character: "idle", "loading", "data_loaded", "running_baseline",
    #'   "baseline_done", "running_optimization", or "done"
    get_status = function() private$status,

    #' @description Get current parameters.
    #' @return Named list of parameters
    get_params = function() private$params,

    #' @description Export simulation results to CSV.
    #' @param path File path for the CSV output
    #' @return Invisible self (for chaining)
    export_csv = function(path) {
      if (is.null(private$optim_result)) stop("No results to export. Run optimization first.")

      # Select key columns for export
      export_cols <- c(
        "timestamp", "pv_kwh", "t_ext", "prix_offtake", "prix_injection",
        "conso_hors_pac", "soutirage_estime_kwh",
        "t_ballon", "offtake_kwh", "intake_kwh",
        "sim_t_ballon", "sim_pac_on", "sim_offtake", "sim_intake",
        "sim_cop", "decision_raison", "batt_soc", "batt_flux", "mode_actif"
      )

      # Only keep columns that exist
      available_cols <- intersect(export_cols, names(private$optim_result))
      export_df <- private$optim_result[, available_cols]

      readr::write_csv(export_df, path)
      message(sprintf("[Export] %d rows written to %s", nrow(export_df), path))

      invisible(self)
    }
  ),

  private = list(
    params_obj = NULL,
    params = NULL,
    thermal_model = NULL,
    kpi_calc = NULL,
    raw_data = NULL,
    prepared_data = NULL,
    baseline_result = NULL,
    optim_result = NULL,
    status = "idle"
  )
)

# Null-coalesce operator (if not already defined)
if (!exists("%||%")) {
  `%||%` <- function(x, y) if (is.null(x)) y else x
}
