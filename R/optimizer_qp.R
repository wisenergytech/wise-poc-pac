# =============================================================================
# Module Optimizer QP — Quadratic Convex Programming using CVXR
# =============================================================================
#
# OVERVIEW
# --------
# This module implements a QP (Quadratic Programming) optimizer using CVXR's
# Disciplined Convex Programming (DCP) framework. It extends the LP formulation
# with quadratic penalty terms that improve comfort and PAC behavior:
#
#   1. Temperature comfort penalty: penalizes deviation from T_consigne
#      → sum_squares(t_bal - t_consigne)
#
#   2. PAC load smoothing penalty: penalizes abrupt changes in PAC load
#      → sum_squares(pac_load[2:n] - pac_load[1:(n-1)])
#
# The objective becomes:
#   Minimize: cost_term + w_comfort * comfort_penalty + w_smooth * smooth_penalty
#
# where w_comfort and w_smooth are user-tunable weights.
#
# WHY CVXR?
# ---------
# ompr only supports linear objectives/constraints. CVXR handles quadratic
# (and more general convex) terms natively and verifies convexity via DCP
# before sending to the solver.
#
# SOLVER
# ------
# Uses CLARABEL (default) or OSQP — both handle QP/SOCP natively.
# Falls back to SCS if neither is available.
#
# =============================================================================

library(CVXR)

# -----------------------------------------------------------------------------
# solve_block_qp — Solve a single block with CVXR (quadratic convex)
# -----------------------------------------------------------------------------
solve_block_qp <- function(block_data, params, t_init, soc_init = NULL, prix_terminal_per_deg = 0) {
  n <- nrow(block_data)
  if (n < 2) return(NULL)

  # Precalculations
  pac_qt <- params$p_pac_kw * params$dt_h
  # COP: use override if provided (iterative COP), else linearize around T_consigne
  cop <- if (!is.null(params$cop_override)) params$cop_override
         else calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = params$t_consigne)
  chaleur_pac <- pac_qt * cop
  cap <- params$capacite_kwh_par_degre

  pv <- block_data$pv_kwh
  conso <- block_data$conso_hors_pac
  prix_off <- block_data$prix_offtake
  prix_inj <- block_data$prix_injection
  ecs <- block_data$soutirage_estime_kwh

  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  has_batt <- params$batterie_active
  batt_pw <- if (has_batt) params$batt_kw * params$dt_h else 0
  batt_eff <- if (has_batt) sqrt(params$batt_rendement) else 1
  soc_min_kwh <- if (has_batt) params$batt_soc_min * params$batt_kwh else 0
  soc_max_kwh <- if (has_batt) params$batt_soc_max * params$batt_kwh else 0

  # QP weights
  w_comfort <- params$qp_w_comfort  # weight for temperature deviation penalty
  w_smooth  <- params$qp_w_smooth   # weight for PAC load smoothing penalty

  # ----------------------------------------------------------
  # CVXR Variables (all continuous)
  # ----------------------------------------------------------
  pac_load <- Variable(n)          # PAC load fraction [0, 1]
  t_bal    <- Variable(n)          # tank temperature
  offt     <- Variable(n)          # grid offtake (kWh)
  inj      <- Variable(n)          # grid injection (kWh)

  if (has_batt) {
    chrg    <- Variable(n)
    dischrg <- Variable(n)
    soc     <- Variable(n)
  }

  # ----------------------------------------------------------
  # Objective: cost + comfort penalty + smoothing penalty
  # ----------------------------------------------------------
  # 1) Net electricity cost (linear)
  cost_term <- sum(offt * prix_off - inj * prix_inj)

  # 2) Comfort: penalize deviation from consigne
  comfort_term <- sum_squares(t_bal - params$t_consigne)

  # 3) Smoothing: penalize abrupt PAC load changes
  smooth_term <- sum_squares(pac_load[2:n] - pac_load[1:(n - 1)])

  # 4) Terminal value: reward keeping the tank warm at end of block
  terminal_term <- t_bal[n] * prix_terminal_per_deg

  objective <- Minimize(cost_term + w_comfort * comfort_term + w_smooth * smooth_term - terminal_term)

  # ----------------------------------------------------------
  # Constraints
  # ----------------------------------------------------------
  constraints <- list(
    # Variable bounds
    pac_load >= 0,
    pac_load <= 1,
    offt >= 0,
    inj >= 0,
    t_bal >= 20,
    t_bal <= params$t_max + 5
  )

  # C1: Energy balance
  if (has_batt) {
    constraints <- c(constraints, list(
      pv + offt + dischrg * batt_eff == conso + pac_load * pac_qt + chrg + inj,
      chrg >= 0,
      chrg <= batt_pw,
      dischrg >= 0,
      dischrg <= batt_pw,
      soc >= soc_min_kwh,
      soc <= soc_max_kwh
    ))
  } else {
    constraints <- c(constraints, list(
      pv + offt == conso + pac_load * pac_qt + inj
    ))
  }

  # C2: Thermal dynamics — first time step
  constraints <- c(constraints, list(
    t_bal[1] * cap ==
      t_init * (cap - k_perte) + pac_load[1] * chaleur_pac[1] + k_perte * t_amb - ecs[1]
  ))
  # C2: Thermal dynamics — subsequent time steps
  for (t in 2:n) {
    constraints <- c(constraints, list(
      t_bal[t] * cap ==
        t_bal[t - 1] * (cap - k_perte) + pac_load[t] * chaleur_pac[t] + k_perte * t_amb - ecs[t]
    ))
  }

  # C3+C4: Per-qt comfort bounds (relaxed during heavy ECS draws)
  for (t in 1:n) {
    if (ecs[t] <= chaleur_pac[t]) {
      constraints <- c(constraints, list(t_bal[t] >= params$t_min))
    }
    constraints <- c(constraints, list(t_bal[t] <= params$t_max))
  }
  # End-of-block: ensure T doesn't end too low for the next block
  constraints <- c(constraints, list(t_bal[n] >= params$t_min))

  # C5: Battery SOC dynamics
  if (has_batt) {
    constraints <- c(constraints, list(
      soc[1] == soc_init + chrg[1] * batt_eff - dischrg[1] / batt_eff
    ))
    for (t in 2:n) {
      constraints <- c(constraints, list(
        soc[t] == soc[t - 1] + chrg[t] * batt_eff - dischrg[t] / batt_eff
      ))
    }
    # Anti-simultaneity relaxation
    constraints <- c(constraints, list(
      chrg + dischrg <= batt_pw
    ))
  }

  # ----------------------------------------------------------
  # Solve with CVXR
  # Uses psolve() + value()/status() API (future-proof for CVXR >= 1.8)
  # ----------------------------------------------------------
  problem <- Problem(objective, constraints)
  solve_ok <- tryCatch({
    psolve(problem, solver = "CLARABEL", verbose = FALSE)
    TRUE
  }, error = function(e) {
    message("[QP Optimizer] CLARABEL failed, trying SCS: ", e$message)
    tryCatch({
      psolve(problem, solver = "SCS", verbose = FALSE)
      TRUE
    }, error = function(e2) {
      message("[QP Optimizer] SCS also failed: ", e2$message)
      FALSE
    })
  })

  if (!solve_ok || status(problem) != "optimal") {
    message(sprintf("[QP Optimizer] Status: %s",
      if (solve_ok) status(problem) else "solver_error"))
    return(NULL)
  }

  # ----------------------------------------------------------
  # Extract solution via value() (new CVXR API)
  # ----------------------------------------------------------
  pac_sol <- as.numeric(value(pac_load))
  t_bal_sol <- as.numeric(value(t_bal))
  offt_sol <- as.numeric(value(offt))
  inj_sol <- as.numeric(value(inj))

  # Clamp small numerical artifacts
  pac_sol <- pmax(0, pmin(1, pac_sol))
  offt_sol <- pmax(0, offt_sol)
  inj_sol <- pmax(0, inj_sol)

  if (has_batt) {
    chrg_sol <- pmax(0, as.numeric(value(chrg)))
    dischrg_sol <- pmax(0, as.numeric(value(dischrg)))
    soc_sol <- as.numeric(value(soc))
  } else {
    chrg_sol <- rep(0, n)
    dischrg_sol <- rep(0, n)
    soc_sol <- rep(0, n)
  }

  tibble(
    sim_pac_on = pac_sol,
    sim_t_ballon = t_bal_sol,
    sim_offtake = offt_sol,
    sim_intake = inj_sol,
    sim_cop = cop,
    decision_raison = "optimizer_qp",
    batt_soc = if (has_batt) soc_sol / params$batt_kwh else 0,
    batt_flux = chrg_sol - dischrg_sol
  )
}

# -----------------------------------------------------------------------------
# run_optimization_qp — QP optimizer for the entire period, block by block
# -----------------------------------------------------------------------------
run_optimization_qp <- function(df, params) {
  n <- nrow(df)

  bloc_qt <- params$optim_bloc_h * 4
  n_blocs <- ceiling(n / bloc_qt)

  all_results <- vector("list", n_blocs)

  # Initial conditions — meme point de depart que la baseline
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

    # Overlapping blocks: extend with lookahead from next block
    i_lookahead_end <- min(i_end + bloc_qt, n)
    block_data <- df[i_start:i_lookahead_end, ]

    baseline_fallback <- function(bd) {
      tibble(
        sim_pac_on = 0,
        sim_t_ballon = bd$t_ballon,
        sim_offtake = bd$offtake_kwh,
        sim_intake = bd$intake_kwh,
        sim_cop = calc_cop(bd$t_ext, params$cop_nominal, params$t_ref_cop),
        decision_raison = "optimizer_qp_fallback",
        batt_soc = 0,
        batt_flux = 0
      )
    }

    # Last block has no lookahead beyond data — use average price of current block as terminal value
    if (i_lookahead_end == i_end) {
      cop_moyen <- mean(calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop))
      prix_moyen <- mean(block_data$prix_offtake, na.rm = TRUE)
      prix_terminal_per_deg <- params$capacite_kwh_par_degre / max(cop_moyen, 1) * prix_moyen
    } else {
      prix_terminal_per_deg <- 0  # overlap provides natural lookahead
    }

    if (nrow(block_data) < 2) {
      block_result <- baseline_fallback(df[i_start:i_end, ])
    } else {
      # Iterative COP: solve, get T trajectory, update COP, re-solve
      params_iter <- params
      full_result <- NULL
      for (cop_iter in 1:2) {
        full_result <- solve_block_qp(block_data, params_iter, t_init, soc_init, prix_terminal_per_deg)
        if (is.null(full_result) || cop_iter == 2) break
        t_bal_solved <- full_result$sim_t_ballon
        params_iter$cop_override <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
      }

      if (is.null(full_result)) {
        message(sprintf("[QP Optimizer] Block %d infeasible, fallback to baseline", b))
        block_result <- baseline_fallback(df[i_start:i_end, ])
      } else {
        block_result <- full_result[1:n_execute, ]
      }
    }

    all_results[[b]] <- block_result

    t_init <- max(params$t_min, tail(block_result$sim_t_ballon, 1))
    if (params$batterie_active) {
      soc_init <- tail(block_result$batt_soc, 1) * params$batt_kwh
    }

    if (exists("setProgress", mode = "function")) {
      try(setProgress(b / n_blocs, detail = sprintf("Bloc %d/%d", b, n_blocs)),
        silent = TRUE)
    }
  }

  results_df <- bind_rows(all_results)

  if (nrow(results_df) != n) {
    message(sprintf("[QP Optimizer] %d rows vs %d expected", nrow(results_df), n))
    if (nrow(results_df) < n) {
      padding <- tibble(
        sim_pac_on = rep(0, n - nrow(results_df)),
        sim_t_ballon = rep(t_init, n - nrow(results_df)),
        sim_offtake = rep(0, n - nrow(results_df)),
        sim_intake = rep(0, n - nrow(results_df)),
        sim_cop = rep(3.5, n - nrow(results_df)),
        decision_raison = rep("padding", n - nrow(results_df)),
        batt_soc = rep(0, n - nrow(results_df)),
        batt_flux = rep(0, n - nrow(results_df))
      )
      results_df <- bind_rows(results_df, padding)
    } else {
      results_df <- results_df[1:n, ]
    }
  }

  df %>% mutate(
    sim_t_ballon = results_df$sim_t_ballon,
    sim_pac_on = results_df$sim_pac_on,
    sim_offtake = results_df$sim_offtake,
    sim_intake = results_df$sim_intake,
    sim_cop = results_df$sim_cop,
    decision_raison = results_df$decision_raison,
    batt_soc = results_df$batt_soc,
    batt_flux = results_df$batt_flux,
    mode_actif = "optimizer_qp"
  )
}
