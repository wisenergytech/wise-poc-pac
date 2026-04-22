# =============================================================================
# R6 Classes: BaseOptimizer + SmartOptimizer + MILPOptimizer + LPOptimizer + QPOptimizer
# =============================================================================
# Optimization hierarchy for PAC dispatch. BaseOptimizer provides the common
# block-loop logic (overlapping blocks + iterative COP). Subclasses delegate
# to the existing solver functions in R/optimizer_milp.R, R/optimizer_lp.R,
# R/optimizer_qp.R. SmartOptimizer uses the rule-based decider from app.R.
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
        private$results <- sim %>% dplyr::mutate(
          sim_t_ballon = baseline_data$t_ballon,
          sim_pac_on = 0,
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

# -----------------------------------------------------------------------------
# SmartOptimizer — Rule-based optimizer using decider() logic from app.R
# -----------------------------------------------------------------------------

#' @title Smart Optimizer (Rule-based)
#' @description R6 optimizer using the rule-based Smart mode from app.R.
#'   Contains the decider() and run_simulation() logic. Unlike the mathematical
#'   optimizers, this processes one quarter-hour at a time sequentially.
#' @export
SmartOptimizer <- R6::R6Class("SmartOptimizer",
  inherit = BaseOptimizer,
  public = list(
    #' @description Run the smart (rule-based) simulation.
    #'   Overrides BaseOptimizer$solve() completely since the Smart mode
    #'   doesn't use the block loop pattern.
    #' @return The dataframe with simulation columns added
    solve = function() {
      df <- private$data
      params <- private$params
      n <- nrow(df)
      pac_conso_qt_nom <- params$p_pac_kw * params$dt_h

      sim_t <- rep(NA_real_, n); sim_on <- rep(NA_integer_, n)
      sim_off <- rep(NA_real_, n); sim_inj <- rep(NA_real_, n)
      sim_cop <- rep(NA_real_, n); sim_raison <- rep(NA_character_, n)
      sim_batt_soc <- rep(NA_real_, n); sim_batt_flux <- rep(NA_real_, n)

      # Initial conditions
      sim_t[1] <- params$t_consigne; sim_on[1] <- 0L
      sim_cop[1] <- calc_cop(df$t_ext[1], params$cop_nominal, params$t_ref_cop, t_ballon = sim_t[1])
      sim_raison[1] <- "init"

      # Battery initialization
      if (params$batterie_active) {
        batt_cap <- params$batt_kwh
        batt_soc_min_kwh <- params$batt_soc_min * batt_cap
        batt_soc_max_kwh <- params$batt_soc_max * batt_cap
        batt_pw <- params$batt_kw * params$dt_h
        batt_eff <- sqrt(params$batt_rendement)
        batt_soc <- (batt_soc_min_kwh + batt_soc_max_kwh) / 2
        sim_batt_soc[1] <- batt_soc / batt_cap
      } else {
        batt_soc <- 0
        sim_batt_soc[1] <- 0
      }
      sim_batt_flux[1] <- 0

      # Qt 1: electrical balance (PAC OFF)
      surplus_1 <- df$pv_kwh[1] - df$conso_hors_pac[1]
      if (surplus_1 >= 0) {
        sim_off[1] <- 0; sim_inj[1] <- surplus_1
      } else {
        sim_off[1] <- abs(surplus_1); sim_inj[1] <- 0
      }

      for (i in 2:n) {
        t_act <- sim_t[i - 1]
        cop_n <- calc_cop(df$t_ext[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_act)
        ch_pac <- pac_conso_qt_nom * cop_n
        sur <- df$pv_kwh[i] - df$conso_hors_pac[i]
        fin_h <- min(i + params$horizon_qt, n); idx <- i:fin_h

        d <- private$decider(
          mode = "smart", params = params, t_actuelle = t_act,
          surplus_now = sur, cop_now = cop_n,
          pac_conso_qt = pac_conso_qt_nom, chaleur_pac = ch_pac,
          pv_futur = df$pv_kwh[idx], conso_hp_fut = df$conso_hors_pac[idx],
          t_ext_futur = df$t_ext[idx], sout_futur = df$soutirage_estime_kwh[idx],
          prix_injection_now = df$prix_injection[i], prix_offtake_now = df$prix_offtake[i],
          prix_injection_fut = df$prix_injection[idx], prix_offtake_fut = df$prix_offtake[idx],
          poids_cout = params$poids_cout
        )

        sim_on[i] <- d$pac_on; sim_cop[i] <- cop_n; sim_raison[i] <- d$raison

        # Same thermal model as baseline and optimizers
        k_perte <- 0.004 * params$dt_h
        t_amb <- 20
        ecs_i <- df$soutirage_estime_kwh[i]
        t_min_i <- if (ecs_i > ch_pac) params$t_min - 10 else params$t_min

        # Proactive T_min / T_max checks
        if (sim_on[i] == 0L) {
          t_sans_pac <- (t_act * (params$capacite_kwh_par_degre - k_perte) + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
          if (t_sans_pac < t_min_i) { sim_on[i] <- 1L; sim_raison[i] <- "smart_contrainte_tmin" }
        }
        if (sim_on[i] == 1L) {
          t_avec_pac <- (t_act * (params$capacite_kwh_par_degre - k_perte) + ch_pac + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
          if (t_avec_pac > params$t_max) { sim_on[i] <- 0L; sim_raison[i] <- "smart_contrainte_tmax" }
        }

        apport <- sim_on[i] * ch_pac
        sim_t[i] <- (t_act * (params$capacite_kwh_par_degre - k_perte) + apport + k_perte * t_amb - ecs_i) / params$capacite_kwh_par_degre
        sim_t[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, sim_t[i]))

        # Electrical balance before battery
        ct <- df$conso_hors_pac[i] + d$pac_on * pac_conso_qt_nom
        surplus_elec <- df$pv_kwh[i] - ct

        batt_flux_qt <- 0

        if (params$batterie_active) {
          if (surplus_elec > 0) {
            charge_possible <- min(surplus_elec, batt_pw, (batt_soc_max_kwh - batt_soc) / batt_eff)
            charge_possible <- max(0, charge_possible)
            batt_soc <- batt_soc + charge_possible * batt_eff
            batt_flux_qt <- charge_possible
            surplus_elec <- surplus_elec - charge_possible
          } else if (surplus_elec < 0) {
            deficit <- abs(surplus_elec)
            decharge_possible <- min(deficit, batt_pw, (batt_soc - batt_soc_min_kwh) * batt_eff)
            decharge_possible <- max(0, decharge_possible)
            batt_soc <- batt_soc - decharge_possible / batt_eff
            batt_flux_qt <- -decharge_possible
            surplus_elec <- surplus_elec + decharge_possible
          }
          sim_batt_soc[i] <- batt_soc / batt_cap
        } else {
          sim_batt_soc[i] <- 0
        }

        sim_batt_flux[i] <- batt_flux_qt

        # Grid balance after battery
        if (surplus_elec >= 0) {
          sim_off[i] <- 0
          sim_inj[i] <- min(surplus_elec, if (!is.null(params$curtail_kwh_per_qt)) params$curtail_kwh_per_qt else Inf)
        } else {
          sim_off[i] <- abs(surplus_elec); sim_inj[i] <- 0
        }
      }

      private$results <- df %>% dplyr::mutate(
        sim_t_ballon = sim_t, sim_pac_on = sim_on, sim_offtake = sim_off,
        sim_intake = sim_inj, sim_cop = sim_cop, decision_raison = sim_raison,
        batt_soc = sim_batt_soc, batt_flux = sim_batt_flux,
        mode_actif = "smart"
      )

      private$results
    }
  ),

  private = list(
    mode_label = "smart",

    # The decider function, copied from app.R
    decider = function(mode, params, t_actuelle, surplus_now, cop_now,
                       pac_conso_qt, chaleur_pac,
                       pv_futur, conso_hp_fut, t_ext_futur, sout_futur,
                       prix_injection_now, prix_offtake_now,
                       prix_injection_fut, prix_offtake_fut,
                       poids_cout = 0.5) {

      # Relaxed T_min during heavy ECS draws
      ecs_now <- if (length(sout_futur) > 0) sout_futur[1] else 0
      t_min_eff <- if (ecs_now > chaleur_pac) params$t_min - 10 else params$t_min

      if (t_actuelle < t_min_eff) return(list(pac_on = 1L, raison = "urgence_confort"))
      if (t_actuelle >= params$t_max) return(list(pac_on = 0L, raison = "ballon_plein"))

      surplus_futur <- pv_futur - conso_hp_fut
      cop_futur     <- calc_cop(t_ext_futur, params$cop_nominal, params$t_ref_cop)

      # Predict future T with same proportional model
      k_perte_d <- 0.004 * params$dt_h
      t_amb_d <- 20
      cap_d <- params$capacite_kwh_par_degre
      t_simul <- t_actuelle
      qt_avant_t_min <- length(sout_futur)
      for (j in seq_along(sout_futur)) {
        chaleur_j <- pac_conso_qt * cop_futur[j]
        t_min_j <- if (sout_futur[j] > chaleur_j) params$t_min - 10 else params$t_min
        t_simul <- (t_simul * (cap_d - k_perte_d) + k_perte_d * t_amb_d - sout_futur[j]) / cap_d
        if (t_simul < t_min_j) { qt_avant_t_min <- j; break }
      }

      if (mode == "smart") {
        # Smart mode: net value-based decision
        if (surplus_now >= pac_conso_qt) {
          cout_now <- pac_conso_qt * prix_injection_now
        } else if (surplus_now > 0) {
          cout_now <- surplus_now * prix_injection_now + (pac_conso_qt - surplus_now) * prix_offtake_now
        } else {
          cout_now <- pac_conso_qt * prix_offtake_now
        }
        cout_par_kwh_th_now <- cout_now / chaleur_pac

        cout_futur_par_kwh_th <- numeric(length(surplus_futur))
        for (j in seq_along(surplus_futur)) {
          s <- surplus_futur[j]; cj <- cop_futur[j]; kj <- pac_conso_qt * cj
          if (s >= pac_conso_qt) cf <- pac_conso_qt * prix_injection_fut[j]
          else if (s > 0) cf <- s * prix_injection_fut[j] + (pac_conso_qt - s) * prix_offtake_fut[j]
          else cf <- pac_conso_qt * prix_offtake_fut[j]
          cout_futur_par_kwh_th[j] <- cf / kj
        }
        cout_moyen_futur <- stats::median(cout_futur_par_kwh_th, na.rm = TRUE)

        marge <- t_actuelle - t_min_eff
        if (marge <= 2) return(list(pac_on = 1L, raison = "smart_urgence"))
        if (qt_avant_t_min <= 8) return(list(pac_on = 1L, raison = "smart_prechauffage"))
        if (prix_injection_now < 0 & surplus_now > 0 & t_actuelle < params$t_max)
          return(list(pac_on = 1L, raison = "smart_eviter_inj_neg"))

        needs_heat <- t_actuelle < params$t_consigne | qt_avant_t_min <= params$horizon_qt
        if (!needs_heat) return(list(pac_on = 0L, raison = "smart_ballon_ok"))

        if (surplus_now >= pac_conso_qt) {
          if (cout_par_kwh_th_now < cout_moyen_futur * 1.5)
            return(list(pac_on = 1L, raison = "smart_surplus_gratuit"))
          return(list(pac_on = 0L, raison = "smart_injection_rentable"))
        }

        if (cout_par_kwh_th_now < cout_moyen_futur * 0.7) {
          if (t_actuelle < params$t_consigne)
            return(list(pac_on = 1L, raison = "smart_prix_favorable"))
        }

        h_avant <- which(surplus_futur >= pac_conso_qt)
        if (length(h_avant) > 0 & qt_avant_t_min > min(h_avant) + 4)
          return(list(pac_on = 0L, raison = "smart_attente_surplus"))

        if (t_actuelle < params$t_consigne)
          return(list(pac_on = 1L, raison = "smart_maintien_confort"))

        return(list(pac_on = 0L, raison = "smart_attente"))
      }
    }
  )
)
