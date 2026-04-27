# =============================================================================
# Simulation orchestration functions
# =============================================================================
# Standalone functions for running full simulation workflows.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Guard optimised results against baseline regression
#'
#' Checks if the optimised bill is worse than baseline. If so, replaces
#' optimised results with baseline values (safety net).
#'
#' @param sim Optimised simulation dataframe
#' @param df_baseline Baseline dataframe
#' @param params Parameter list
#' @param mode_label Character label for logging (e.g. "MILP")
#' @return The simulation dataframe, possibly reverted to baseline values
#' @export
guard_baseline <- function(sim, df_baseline, params, mode_label) {
  facture_baseline <- sum(
    df_baseline$offtake_kwh * df_baseline$prix_offtake -
    df_baseline$intake_kwh * df_baseline$prix_injection,
    na.rm = TRUE
  )
  facture_opti <- sum(
    sim$sim_offtake * sim$prix_offtake -
    sim$sim_intake * sim$prix_injection,
    na.rm = TRUE
  )
  if (facture_opti > facture_baseline) {
    message(sprintf("[%s] Facture opti (%.1f) > baseline (%.1f) -- fallback baseline",
                    mode_label, facture_opti, facture_baseline))
    # Reconstruct baseline pac_on from energy balance
    pac_qt <- params$p_pac_kw * params$dt_h
    baseline_pac_elec <- pmax(0, df_baseline$offtake_kwh + df_baseline$pv_kwh -
      df_baseline$intake_kwh - df_baseline$conso_hors_pac)
    sim$sim_pac_on <- as.integer(baseline_pac_elec > pac_qt * 0.1)
    sim$sim_t_ballon <- df_baseline$t_ballon
    sim$sim_offtake <- df_baseline$offtake_kwh
    sim$sim_intake <- df_baseline$intake_kwh
    sim$sim_cop <- calc_cop(df_baseline$t_ext, params$cop_nominal, params$t_ref_cop)
    sim$decision_raison <- "baseline_fallback"
    sim$mode_actif <- paste0(mode_label, "_baseline")
  }
  sim
}

#' Run full simulation pipeline
#'
#' Executes the complete workflow: data preparation, parametric baseline,
#' optimisation, and baseline guard. This is the main entry point for
#' running a simulation outside of Shiny.
#'
#' @param df Raw data dataframe (with timestamp, pv_kwh, t_ext, etc.)
#' @param params Parameter list (as returned by sidebar params_r or
#'   SimulationParams)
#' @param mode Optimisation mode: \code{"milp"}, \code{"lp"},
#'   or \code{"qp"}
#' @param baseline_mode Baseline mode (default \code{"thermostat"})
#' @param fallback_mode If optimisation fails, fall back to this mode
#'   (default \code{NULL}). Set to a valid mode or \code{NULL} to disable.
#' @return A named list with:
#'   \describe{
#'     \item{sim}{Simulation results dataframe}
#'     \item{df}{Baseline dataframe}
#'     \item{params}{Final parameter list (may differ from input due to
#'       data-dependent adjustments)}
#'     \item{mode}{Optimisation mode actually used}
#'   }
#'
#' @examples
#' \dontrun{
#' result <- run_simulation(df, params, mode = "milp")
#' result$sim  # optimised results
#' KPICalculator$new()$compute(result$sim, result$sim, result$params)
#' }
#' @export
run_simulation <- function(df, params, mode = "lp",
                           baseline_mode = "thermostat",
                           fallback_mode = NULL) {
  sim_obj <- Simulation$new(params)
  sim_obj$load_raw_dataframe(df)
  params <- sim_obj$get_params()

  sim_obj$run_baseline(mode = baseline_mode)
  df_prep <- sim_obj$get_baseline()

  mode_label <- toupper(mode)

  sim <- tryCatch({
    sim_obj$run_optimization(mode)
    sim_obj$get_results()
  }, error = function(e) {
    message(sprintf("[%s] Optimization failed: %s", mode_label, e$message))
    NULL
  })

  if (is.null(sim) && !is.null(fallback_mode)) {
    message(sprintf("[%s] Falling back to %s", mode_label, fallback_mode))
    sim_obj$run_optimization(fallback_mode)
    sim <- sim_obj$get_results()
    sim$mode_actif <- paste0(fallback_mode, "_fallback")
    mode <- fallback_mode
  } else if (!is.null(sim)) {
    sim <- guard_baseline(sim, df_prep, params, mode_label)
  }

  list(sim = sim, df = df_prep, params = params, mode = mode)
}
