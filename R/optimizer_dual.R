# =============================================================================
# Module Optimizer Dual — Mixed MILP for coupled ASHP+GSHP dispatch
# =============================================================================
#
# OVERVIEW
# --------
# This module implements a dual heat pump optimizer using Mixed Integer Linear
# Programming (MILP). It handles two PACs feeding the same thermal buffer:
#   - PAC with mode "onoff": binary variable y[t] in {0,1}, fixed power
#   - PAC with mode "inverter": continuous variable p[t] in [0,1], variable power
#     with ramp constraints for smooth transitions
#
# The formulation extends optimizer_milp.R with:
#   - Two PAC variables (one per heat pump)
#   - Two COP curves: calc_cop() for ASHP, calc_cop_gshp() for GSHP
#   - Ramp constraints |Dp[t]| <= ramp_max for inverter PACs
#   - Coupled thermal dynamics (single tank, two heat sources)
#
# REFERENCES
# ----------
# - IEEE 2019 "MILP for Dual Source Heat Pump" (dispatch ASHP/GSHP)
# - D'Ettorre et al. 2019 "MPC of hybrid heat pump" (ramp constraints)
# - specs/009-dual-pac-optimizer/spec.md
#
# =============================================================================

library(ompr)
library(ompr.roi)
library(ROI.plugin.highs)

# -----------------------------------------------------------------------------
# solve_block_dual — Solve a single block with dual PAC MILP
# -----------------------------------------------------------------------------
solve_block_dual <- function(block_data, params, t_init, soc_init = NULL,
                             prix_terminal_per_deg = 0, p_pac2_init = NULL) {
  n <- nrow(block_data)
  if (n < 2) return(NULL)

  # --- PAC 1 parameters ---
  pac1_qt <- params$p_pac_kw * params$dt_h  # kWh electrical per qt
  pac1_is_binary <- (params$pac1_mode == "onoff")
  cop1 <- if (!is.null(params$cop1_override)) {
    params$cop1_override
  } else {
    cop1_fn <- if (params$pac1_type == "gshp") calc_cop_gshp else calc_cop
    cop1_fn(block_data$t_sol, params$cop_nominal, params$t_ref_cop, t_ballon = params$t_consigne)
  }

  # --- PAC 2 parameters ---
  pac2_qt <- params$p_pac2_kw * params$dt_h
  pac2_is_binary <- (params$pac2_mode == "onoff")
  cop2 <- if (!is.null(params$cop2_override)) {
    params$cop2_override
  } else {
    cop2_fn <- if (params$pac2_type == "gshp") calc_cop_gshp else calc_cop
    cop2_fn(block_data$t_ext, params$cop2_nominal, params$t_ref_cop2, t_ballon = params$t_consigne)
  }

  # Use correct source temperature for each PAC type
  if (!is.null(params$cop1_override)) {
    # Already set
  } else if (params$pac1_type == "gshp") {
    cop1 <- calc_cop_gshp(block_data$t_sol, params$cop_nominal, params$t_ref_cop, t_ballon = params$t_consigne)
  } else {
    cop1 <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = params$t_consigne)
  }
  if (!is.null(params$cop2_override)) {
    # Already set
  } else if (params$pac2_type == "gshp") {
    cop2 <- calc_cop_gshp(block_data$t_sol, params$cop2_nominal, params$t_ref_cop2, t_ballon = params$t_consigne)
  } else {
    cop2 <- calc_cop(block_data$t_ext, params$cop2_nominal, params$t_ref_cop2, t_ballon = params$t_consigne)
  }

  chaleur_pac1 <- pac1_qt * cop1
  chaleur_pac2 <- pac2_qt * cop2
  cap <- params$capacite_kwh_par_degre

  # Input vectors
  pv <- block_data$pv_kwh
  conso <- block_data$conso_hors_pac
  prix_off <- block_data$prix_offtake
  prix_inj <- block_data$prix_injection
  ecs <- block_data$soutirage_estime_kwh

  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  # Floor negative prices to 0 to avoid solver divergence
  # (negative offtake price → solver wants infinite offtake → infeasible)
  prix_off <- pmax(0, prix_off)

  # Battery
  has_batt <- params$batterie_active
  batt_pw <- if (has_batt) params$batt_kw * params$dt_h else 0
  batt_eff <- if (has_batt) sqrt(params$batt_rendement) else 1
  soc_min_kwh <- if (has_batt) params$batt_soc_min * params$batt_kwh else 0
  soc_max_kwh <- if (has_batt) params$batt_soc_max * params$batt_kwh else 0

  ramp_max <- params$ramp_max

  # ----------------------------------------------------------
  # Build MILP model
  # ----------------------------------------------------------
  model <- MIPModel()

  # PAC 1 variable (binary or continuous depending on mode)
  if (pac1_is_binary) {
    model <- model |> add_variable(y_pac1[t], t = 1:n, type = "binary")
  } else {
    model <- model |> add_variable(y_pac1[t], t = 1:n, lb = 0, ub = 1, type = "continuous")
  }

  # PAC 2 variable (binary or continuous depending on mode)
  if (pac2_is_binary) {
    model <- model |> add_variable(p_pac2[t], t = 1:n, type = "binary")
  } else {
    model <- model |> add_variable(p_pac2[t], t = 1:n, lb = 0, ub = 1, type = "continuous")
  }

  # Other variables
  model <- model |>
    add_variable(t_bal[t], t = 1:n, lb = 20, ub = params$t_max + 5) |>
    add_variable(offt[t], t = 1:n, lb = 0) |>
    add_variable(inj[t], t = 1:n, lb = 0,
      ub = if (!is.null(params$curtail_kwh_per_qt) && is.finite(params$curtail_kwh_per_qt))
        params$curtail_kwh_per_qt else Inf) |>
    add_variable(slack[t], t = 1:n, lb = 0)

  # Battery variables
  if (has_batt) {
    model <- model |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min_kwh, ub = soc_max_kwh) |>
      add_variable(batt_ch[t], t = 1:n, type = "binary")
  }

  # ----------------------------------------------------------
  # Objective: min net cost + slack penalty - terminal value
  # ----------------------------------------------------------
  penalty <- if (!is.null(params$slack_penalty)) params$slack_penalty else 2.5

  model <- model |>
    set_objective(
      sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n) +
        sum_expr(slack[t] * penalty, t = 1:n) -
        sum_expr(t_bal[t] * prix_terminal_per_deg, t = n:n),
      sense = "min"
    )

  # ----------------------------------------------------------
  # C1: Energy balance (two PAC terms)
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] + dischrg[t] * batt_eff ==
          conso[t] + y_pac1[t] * pac1_qt + p_pac2[t] * pac2_qt + chrg[t] + inj[t],
        t = 1:n
      )
  } else {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] ==
          conso[t] + y_pac1[t] * pac1_qt + p_pac2[t] * pac2_qt + inj[t],
        t = 1:n
      )
  }

  # ----------------------------------------------------------
  # C2: Thermal dynamics (dual source, single tank)
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(
      t_bal[1] * cap ==
        t_init * (cap - k_perte) +
        y_pac1[1] * chaleur_pac1[1] + p_pac2[1] * chaleur_pac2[1] +
        k_perte * t_amb - ecs[1]
    ) |>
    add_constraint(
      t_bal[t] * cap ==
        t_bal[t - 1] * (cap - k_perte) +
        y_pac1[t] * chaleur_pac1[t] + p_pac2[t] * chaleur_pac2[t] +
        k_perte * t_amb - ecs[t],
      t = 2:n
    )

  # ----------------------------------------------------------
  # C3+C4: Comfort bounds (soft T_min, hard T_max)
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(t_bal[t] + slack[t] >= params$t_min, t = 1:n) |>
    add_constraint(t_bal[t] <= params$t_max, t = 1:n)

  # ----------------------------------------------------------
  # C5: Ramp constraints for inverter PACs
  # ----------------------------------------------------------
  if (!pac1_is_binary && n > 1) {
    # PAC 1 is inverter — add ramp constraints
    if (!is.null(p_pac2_init)) {
      # Chain ramp from previous block for PAC 1
      # (reusing p_pac2_init slot for pac1 when pac1 is inverter — see note)
    }
    model <- model |>
      add_constraint(y_pac1[t] - y_pac1[t - 1] <= ramp_max, t = 2:n) |>
      add_constraint(y_pac1[t - 1] - y_pac1[t] <= ramp_max, t = 2:n)
  }

  if (!pac2_is_binary && n > 1) {
    # PAC 2 is inverter — add ramp constraints
    model <- model |>
      add_constraint(p_pac2[t] - p_pac2[t - 1] <= ramp_max, t = 2:n) |>
      add_constraint(p_pac2[t - 1] - p_pac2[t] <= ramp_max, t = 2:n)

    # Chain ramp from previous block
    if (!is.null(p_pac2_init)) {
      model <- model |>
        add_constraint(p_pac2[1] - p_pac2_init <= ramp_max) |>
        add_constraint(p_pac2_init - p_pac2[1] <= ramp_max)
    }
  }

  # ----------------------------------------------------------
  # C5b: Minimum cycle duration for on/off PACs
  # ----------------------------------------------------------
  # If PAC turns ON at t, it must stay ON for min_cycle_qt steps.
  # If PAC turns OFF at t, it must stay OFF for min_cycle_qt steps.
  # Formulation: for each k in 1:(L-1):
  #   y[t] - y[t-1] <= y[t+k]        (min ON)
  #   y[t-1] - y[t] + y[t+k] <= 1    (min OFF)
  min_cycle_qt <- if (!is.null(params$min_cycle_qt) && params$min_cycle_qt > 1) {
    params$min_cycle_qt
  } else {
    0L
  }

  if (pac1_is_binary && min_cycle_qt > 1 && n > min_cycle_qt) {
    for (k in seq_len(min_cycle_qt - 1)) {
      t_range <- 2:(n - k)
      if (length(t_range) > 0) {
        model <- model |>
          add_constraint(y_pac1[t] - y_pac1[t - 1] <= y_pac1[t + k], t = t_range) |>
          add_constraint(y_pac1[t - 1] - y_pac1[t] + y_pac1[t + k] <= 1, t = t_range)
      }
    }
  }

  if (pac2_is_binary && min_cycle_qt > 1 && n > min_cycle_qt) {
    for (k in seq_len(min_cycle_qt - 1)) {
      t_range <- 2:(n - k)
      if (length(t_range) > 0) {
        model <- model |>
          add_constraint(p_pac2[t] - p_pac2[t - 1] <= p_pac2[t + k], t = t_range) |>
          add_constraint(p_pac2[t - 1] - p_pac2[t] + p_pac2[t + k] <= 1, t = t_range)
      }
    }
  }

  # ----------------------------------------------------------
  # C6-C8: Battery constraints (same as optimizer_milp.R)
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_constraint(
        soc[1] == soc_init + chrg[1] * batt_eff - dischrg[1] / batt_eff
      ) |>
      add_constraint(
        soc[t] == soc[t - 1] + chrg[t] * batt_eff - dischrg[t] / batt_eff,
        t = 2:n
      ) |>
      add_constraint(chrg[t] <= batt_pw * batt_ch[t], t = 1:n) |>
      add_constraint(dischrg[t] <= batt_pw * (1 - batt_ch[t]), t = 1:n)
  }

  # ----------------------------------------------------------
  # Solve
  # ----------------------------------------------------------
  result <- tryCatch(
    solve_model(model, with_ROI(solver = "highs", verbose = FALSE)),
    error = function(e) {
      message("[Dual Optimizer] Solver error: ", e$message)
      return(NULL)
    }
  )

  if (is.null(result) || result$status != "success") {
    message(sprintf("[Dual Optimizer] Status: %s",
      if (!is.null(result)) result$status else "NULL"))
    return(NULL)
  }

  # ----------------------------------------------------------
  # Extract solution
  # ----------------------------------------------------------
  pac1_sol <- get_solution(result, y_pac1[t])$value
  pac2_sol <- get_solution(result, p_pac2[t])$value
  t_bal_sol <- get_solution(result, t_bal[t])$value
  offt_sol <- get_solution(result, offt[t])$value
  inj_sol <- get_solution(result, inj[t])$value

  # Clamp binary solutions
  if (pac1_is_binary) pac1_sol <- as.integer(round(pac1_sol))
  if (pac2_is_binary) pac2_sol <- as.integer(round(pac2_sol))

  # Compute per-qt electrical consumption
  pac1_kwh <- pac1_sol * pac1_qt
  pac2_kwh <- pac2_sol * pac2_qt

  if (has_batt) {
    chrg_sol <- get_solution(result, chrg[t])$value
    dischrg_sol <- get_solution(result, dischrg[t])$value
    soc_sol <- get_solution(result, soc[t])$value
  } else {
    chrg_sol <- rep(0, n)
    dischrg_sol <- rep(0, n)
    soc_sol <- rep(0, n)
  }

  # Backward-compatible sim_pac_on = combined load
  sim_pac_on <- pac1_sol + pac2_sol
  # Weighted average COP
  total_kwh <- pac1_kwh + pac2_kwh
  sim_cop <- ifelse(total_kwh > 0,
    (pac1_kwh * cop1 + pac2_kwh * cop2) / total_kwh,
    (cop1 + cop2) / 2)

  tibble(
    sim_pac_on = sim_pac_on,
    sim_pac1_on = pac1_sol,
    sim_pac2_load = pac2_sol,
    sim_pac1_kwh = pac1_kwh,
    sim_pac2_kwh = pac2_kwh,
    sim_cop1 = cop1,
    sim_cop2 = cop2,
    sim_t_ballon = t_bal_sol,
    sim_offtake = offt_sol,
    sim_intake = inj_sol,
    sim_cop = sim_cop,
    decision_raison = "optimizer_dual",
    batt_soc = if (has_batt) soc_sol / params$batt_kwh else 0,
    batt_flux = chrg_sol - dischrg_sol
  )
}

# -----------------------------------------------------------------------------
# run_optimization_dual — Dual optimizer block loop with iterative COP
# -----------------------------------------------------------------------------
run_optimization_dual <- function(df, params) {
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
  p_pac2_init <- NULL  # No previous block for first block

  for (b in seq_len(n_blocs)) {
    i_start <- (b - 1) * bloc_qt + 1
    i_end <- min(b * bloc_qt, n)
    n_execute <- i_end - i_start + 1

    # Overlapping: extend with lookahead
    i_lookahead_end <- min(i_end + bloc_qt, n)
    block_data <- df[i_start:i_lookahead_end, ]

    baseline_fallback <- function(bd) {
      tibble(
        sim_pac_on = 0,
        sim_pac1_on = 0,
        sim_pac2_load = 0,
        sim_pac1_kwh = 0,
        sim_pac2_kwh = 0,
        sim_cop1 = if (params$pac1_type == "gshp") {
          calc_cop_gshp(bd$t_sol, params$cop_nominal, params$t_ref_cop)
        } else {
          calc_cop(bd$t_ext, params$cop_nominal, params$t_ref_cop)
        },
        sim_cop2 = if (params$pac2_type == "gshp") {
          calc_cop_gshp(bd$t_sol, params$cop2_nominal, params$t_ref_cop2)
        } else {
          calc_cop(bd$t_ext, params$cop2_nominal, params$t_ref_cop2)
        },
        sim_t_ballon = if ("t_ballon" %in% names(bd)) bd$t_ballon else rep(params$t_consigne, nrow(bd)),
        sim_offtake = if ("offtake_kwh" %in% names(bd)) bd$offtake_kwh else rep(0, nrow(bd)),
        sim_intake = if ("intake_kwh" %in% names(bd)) bd$intake_kwh else rep(0, nrow(bd)),
        sim_cop = calc_cop(bd$t_ext, params$cop_nominal, params$t_ref_cop),
        decision_raison = "optimizer_dual_fallback",
        batt_soc = 0,
        batt_flux = 0
      )
    }

    # Terminal value for last block
    if (i_lookahead_end == i_end) {
      cop1_fn <- if (params$pac1_type == "gshp") calc_cop_gshp else calc_cop
      cop1_moyen <- mean(cop1_fn(block_data$t_sol, params$cop_nominal, params$t_ref_cop))
      prix_moyen <- mean(block_data$prix_offtake, na.rm = TRUE)
      prix_terminal_per_deg <- params$capacite_kwh_par_degre / max(cop1_moyen, 1) * prix_moyen
    } else {
      prix_terminal_per_deg <- 0
    }

    if (nrow(block_data) < 2) {
      block_result <- baseline_fallback(df[i_start:i_end, ])
    } else {
      # Iterative COP: solve, get T trajectory, update both COPs, re-solve
      params_iter <- params
      full_result <- NULL
      for (cop_iter in 1:2) {
        full_result <- solve_block_dual(block_data, params_iter, t_init, soc_init,
                                        prix_terminal_per_deg, p_pac2_init)
        if (is.null(full_result) || cop_iter == 2) break
        # Update both COPs based on solved T trajectory
        t_bal_solved <- full_result$sim_t_ballon
        if (params$pac1_type == "gshp") {
          params_iter$cop1_override <- calc_cop_gshp(block_data$t_sol, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
        } else {
          params_iter$cop1_override <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
        }
        if (params$pac2_type == "gshp") {
          params_iter$cop2_override <- calc_cop_gshp(block_data$t_sol, params$cop2_nominal, params$t_ref_cop2, t_ballon = t_bal_solved)
        } else {
          params_iter$cop2_override <- calc_cop(block_data$t_ext, params$cop2_nominal, params$t_ref_cop2, t_ballon = t_bal_solved)
        }
      }

      if (is.null(full_result)) {
        message(sprintf("[Dual Optimizer] Block %d infeasible, fallback to baseline", b))
        block_result <- baseline_fallback(df[i_start:i_end, ])
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
    # Chain ramp for inverter PAC 2
    if (params$pac2_mode == "inverter") {
      p_pac2_init <- tail(block_result$sim_pac2_load, 1)
    }

    # Progress reporting
    if (exists("setProgress", mode = "function")) {
      try(setProgress(b / n_blocs, detail = sprintf("Bloc %d/%d", b, n_blocs)),
        silent = TRUE)
    }
  }

  # Assemble
  results_df <- dplyr::bind_rows(all_results)

  # Handle length mismatch
  if (nrow(results_df) != n) {
    message(sprintf("[Dual Optimizer] %d rows vs %d expected", nrow(results_df), n))
    if (nrow(results_df) < n) {
      pad_n <- n - nrow(results_df)
      padding <- dplyr::tibble(
        sim_pac_on = rep(0, pad_n),
        sim_pac1_on = rep(0, pad_n),
        sim_pac2_load = rep(0, pad_n),
        sim_pac1_kwh = rep(0, pad_n),
        sim_pac2_kwh = rep(0, pad_n),
        sim_cop1 = rep(3.5, pad_n),
        sim_cop2 = rep(3.5, pad_n),
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

  df %>% dplyr::mutate(
    sim_t_ballon = results_df$sim_t_ballon,
    sim_pac_on = results_df$sim_pac_on,
    sim_pac1_on = results_df$sim_pac1_on,
    sim_pac2_load = results_df$sim_pac2_load,
    sim_pac1_kwh = results_df$sim_pac1_kwh,
    sim_pac2_kwh = results_df$sim_pac2_kwh,
    sim_cop1 = results_df$sim_cop1,
    sim_cop2 = results_df$sim_cop2,
    sim_offtake = results_df$sim_offtake,
    sim_intake = results_df$sim_intake,
    sim_cop = results_df$sim_cop,
    decision_raison = results_df$decision_raison,
    batt_soc = results_df$batt_soc,
    batt_flux = results_df$batt_flux,
    mode_actif = "optimizer_dual"
  )
}
