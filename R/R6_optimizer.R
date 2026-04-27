# =============================================================================
# R6 Classes: BaseOptimizer + MILPOptimizer + LPOptimizer + QPOptimizer
# =============================================================================
# Optimization hierarchy for PAC dispatch. BaseOptimizer provides the common
# block-loop logic (overlapping blocks + iterative COP). Subclasses delegate
# to the existing solver functions in R/optimizer_milp.R, R/optimizer_lp.R,
# R/optimizer_qp.R.
# =============================================================================

# -----------------------------------------------------------------------------
# BaseOptimizer — Abstract base class for block-based optimization
# -----------------------------------------------------------------------------

#' @title Base Optimizer
#' @description R6 base class for all optimization modes. Provides the common
#'   block loop with overlapping blocks and iterative COP refinement.
#' @export
BaseOptimizer <- R6::R6Class("BaseOptimizer",
  public = list(
    #' @description Create a new optimizer.
    #' @param params Parameter list (or SimulationParams$as_list())
    #' @param data Prepared dataframe (output of prepare_df / Baseline$run)
    initialize = function(params, data) {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }
      private$params <- params
      private$data <- data
    },

    #' @description Run the optimization over the full period using block loop.
    #'   Splits the period into overlapping blocks, solves each block, chains
    #'   initial conditions (temperature, battery SoC) between blocks.
    #' @return The dataframe with simulation columns added
    solve = function() {
      df <- private$data
      params <- private$params
      n <- nrow(df)

      bloc_qt <- params$optim_bloc_h * 4
      n_blocs <- ceiling(n / bloc_qt)

      all_results <- vector("list", n_blocs)

      # Initial conditions
      t_init <- params$t_consigne
      soc_init <- if (params$batterie_active) {
        (params$batt_soc_min + params$batt_soc_max) / 2 * params$batt_kwh
      } else {
        0
      }

      for (b in seq_len(n_blocs)) {
        i_start <- (b - 1) * bloc_qt + 1
        i_end <- min(b * bloc_qt, n)
        n_execute <- i_end - i_start + 1

        # Overlapping: extend with lookahead from next block
        i_lookahead_end <- min(i_end + bloc_qt, n)
        block_data <- df[i_start:i_lookahead_end, ]

        # Terminal value for last block
        if (i_lookahead_end == i_end) {
          cop_moyen <- mean(calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop))
          prix_moyen <- mean(block_data$prix_offtake, na.rm = TRUE)
          prix_terminal_per_deg <- params$capacite_kwh_par_degre / max(cop_moyen, 1) * prix_moyen
        } else {
          prix_terminal_per_deg <- 0
        }

        if (nrow(block_data) < 2) {
          block_result <- private$baseline_fallback(df[i_start:i_end, ])
        } else {
          # Iterative COP: solve, get T trajectory, update COP, re-solve
          params_iter <- params
          full_result <- NULL
          for (cop_iter in 1:2) {
            full_result <- private$solve_block(block_data, params_iter, t_init, soc_init, prix_terminal_per_deg)
            if (is.null(full_result) || cop_iter == 2) break
            t_bal_solved <- full_result$sim_t_ballon
            params_iter$cop_override <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
          }

          if (is.null(full_result)) {
            message(sprintf("[%s] Block %d infeasible, fallback to baseline", private$mode_label, b))
            block_result <- private$baseline_fallback(df[i_start:i_end, ])
          } else {
            block_result <- full_result[1:n_execute, ]
          }
        }

        all_results[[b]] <- block_result

        # Chain initial conditions
        t_init <- max(params$t_min, tail(block_result$sim_t_ballon, 1))
        if (params$batterie_active) {
          soc_init <- tail(block_result$batt_soc, 1) * params$batt_kwh
        }
      }

      # Assemble
      results_df <- dplyr::bind_rows(all_results)

      # Handle length mismatch
      if (nrow(results_df) != n) {
        message(sprintf("[%s] %d rows vs %d expected", private$mode_label, nrow(results_df), n))
        if (nrow(results_df) < n) {
          pad_n <- n - nrow(results_df)
          padding <- dplyr::tibble(
            sim_pac_on = rep(0, pad_n),
            sim_t_ballon = rep(t_init, pad_n),
            sim_offtake = rep(0, pad_n),
            sim_intake = rep(0, pad_n),
            sim_cop = rep(3.5, pad_n),
            decision_raison = rep("padding", pad_n),
            batt_soc = rep(0, pad_n),
            batt_flux = rep(0, pad_n)
          )
          results_df <- dplyr::bind_rows(results_df, padding)
        } else {
          results_df <- results_df[1:n, ]
        }
      }

      private$results <- df %>% dplyr::mutate(
        sim_t_ballon = results_df$sim_t_ballon,
        sim_pac_on = results_df$sim_pac_on,
        sim_offtake = results_df$sim_offtake,
        sim_intake = results_df$sim_intake,
        sim_cop = results_df$sim_cop,
        decision_raison = results_df$decision_raison,
        batt_soc = results_df$batt_soc,
        batt_flux = results_df$batt_flux,
        mode_actif = private$mode_label
      )

      private$results
    },

    #' @description Get the optimization results.
    #' @return The result dataframe, or NULL if solve() hasn't been called
    get_results = function() private$results,

    #' @description Guard against regression: compare optimized bill vs baseline.
    #'   If the optimizer produces a worse bill, fall back to baseline values.
    #' @param baseline_data Baseline dataframe with offtake_kwh, intake_kwh,
    #'   prix_offtake, prix_injection
    #' @return The (possibly corrected) results dataframe
    guard_baseline = function(baseline_data) {
      if (is.null(private$results)) return(NULL)

      sim <- private$results
      params <- private$params

      facture_baseline <- sum(baseline_data$offtake_kwh * baseline_data$prix_offtake, na.rm = TRUE) -
        sum(baseline_data$intake_kwh * baseline_data$prix_injection, na.rm = TRUE)
      facture_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) -
        sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)

      if (facture_opti > facture_baseline * 1.01) {
        message(sprintf("[%s] Guard: opti (%.2f) worse than baseline (%.2f), falling back",
          private$mode_label, facture_opti, facture_baseline))
        # Reconstruct baseline pac_on from energy balance
        pac_qt <- params$p_pac_kw * params$dt_h
        baseline_pac_elec <- pmax(0, baseline_data$offtake_kwh + baseline_data$pv_kwh -
          baseline_data$intake_kwh - baseline_data$conso_hors_pac)
        baseline_pac_on <- as.integer(baseline_pac_elec > pac_qt * 0.1)
        private$results <- sim %>% dplyr::mutate(
          sim_t_ballon = baseline_data$t_ballon,
          sim_pac_on = baseline_pac_on,
          sim_offtake = baseline_data$offtake_kwh,
          sim_intake = baseline_data$intake_kwh,
          decision_raison = "guard_fallback",
          mode_actif = private$mode_label
        )
      }

      private$results
    }
  ),

  private = list(
    params = NULL,
    data = NULL,
    results = NULL,
    mode_label = "optimizer",

    # Subclasses MUST override this method
    solve_block = function(block_data, params, t_init, soc_init, prix_terminal_per_deg) {
      stop("solve_block() must be implemented by subclass")
    },

    baseline_fallback = function(bd) {
      params <- private$params
      dplyr::tibble(
        sim_pac_on = 0,
        sim_t_ballon = if ("t_ballon" %in% names(bd)) bd$t_ballon else rep(params$t_consigne, nrow(bd)),
        sim_offtake = if ("offtake_kwh" %in% names(bd)) bd$offtake_kwh else rep(0, nrow(bd)),
        sim_intake = if ("intake_kwh" %in% names(bd)) bd$intake_kwh else rep(0, nrow(bd)),
        sim_cop = calc_cop(bd$t_ext, params$cop_nominal, params$t_ref_cop),
        decision_raison = paste0(private$mode_label, "_fallback"),
        batt_soc = 0,
        batt_flux = 0
      )
    }
  )
)

# -----------------------------------------------------------------------------
# MILPOptimizer — Delegates to solve_block() from R/optimizer_milp.R
# -----------------------------------------------------------------------------

#' @title MILP Optimizer
#' @description R6 optimizer using Mixed Integer Linear Programming.
#'   Delegates block solving to solve_block() from R/optimizer_milp.R.
#' @export
MILPOptimizer <- R6::R6Class("MILPOptimizer",
  inherit = BaseOptimizer,
  private = list(
    mode_label = "optimizer",
    solve_block = function(block_data, params, t_init, soc_init, prix_terminal_per_deg) {
      # Delegate to the existing solve_block() from R/optimizer_milp.R
      solve_block(block_data, params, t_init, soc_init, prix_terminal_per_deg)
    }
  )
)

# -----------------------------------------------------------------------------
# LPOptimizer — Delegates to solve_block_lp() from R/optimizer_lp.R
# -----------------------------------------------------------------------------

#' @title LP Optimizer
#' @description R6 optimizer using pure Linear Programming (continuous PAC load).
#'   Delegates block solving to solve_block_lp() from R/optimizer_lp.R.
#' @export
LPOptimizer <- R6::R6Class("LPOptimizer",
  inherit = BaseOptimizer,
  private = list(
    mode_label = "optimizer_lp",
    solve_block = function(block_data, params, t_init, soc_init, prix_terminal_per_deg) {
      solve_block_lp(block_data, params, t_init, soc_init, prix_terminal_per_deg)
    }
  )
)

# -----------------------------------------------------------------------------
# QPOptimizer — Delegates to solve_block_qp() from R/optimizer_qp.R
# -----------------------------------------------------------------------------

#' @title QP Optimizer
#' @description R6 optimizer using Quadratic Programming with comfort and
#'   smoothing penalties. Delegates to solve_block_qp() from R/optimizer_qp.R.
#' @export
QPOptimizer <- R6::R6Class("QPOptimizer",
  inherit = BaseOptimizer,
  private = list(
    mode_label = "optimizer_qp",
    solve_block = function(block_data, params, t_init, soc_init, prix_terminal_per_deg) {
      solve_block_qp(block_data, params, t_init, soc_init, prix_terminal_per_deg)
    }
  )
)
