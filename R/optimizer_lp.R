# =============================================================================
# Module Optimizer LP — Pure Linear Programming (no binary variables)
# =============================================================================
#
# OVERVIEW
# --------
# This module implements a pure LP (Linear Programming) optimizer for heat pump
# dispatch. Unlike the MILP optimizer (optimizer_milp.R) which uses binary
# on/off decisions, this formulation treats the PAC as a continuously variable
# load between 0% and 100% of rated power.
#
# This is physically realistic for inverter-driven heat pumps, and a reasonable
# approximation for on/off units on 15-minute time steps (duty cycling).
#
# ADVANTAGES OVER MILP
# --------------------
# - Pure LP is always convex → guaranteed global optimum
# - Polynomial-time solving (vs NP-hard for MILP)
# - Much faster: can handle larger blocks or the whole period at once
# - No anti-simultaneity binary needed for battery (suboptimal by construction)
#
# FORMULATION (per block of N quarter-hours)
# ------------------------------------------
# Decision variables:
#   pac_load[t] : continuous [0,1] — PAC load fraction at qt t
#   t_bal[t]    : continuous       — tank temperature at qt t
#   offt[t]     : continuous >= 0  — grid offtake at qt t (kWh)
#   inj[t]      : continuous >= 0  — grid injection at qt t (kWh)
#   chrg[t]     : continuous >= 0  — battery charge at qt t (kWh)
#   dischrg[t]  : continuous >= 0  — battery discharge at qt t (kWh)
#   soc[t]      : continuous       — battery SOC at qt t (kWh)
#
# Objective:
#   Minimize sum_t( offt[t] * prix_offtake[t] - inj[t] * prix_injection[t] )
#
# Constraints: same as MILP (see optimizer_milp.R) but with pac_load replacing
# pac_on, and no binary variables at all.
#
# =============================================================================

# -----------------------------------------------------------------------------
# solve_block_lp — Solve a single block with pure LP (continuous PAC load)
# -----------------------------------------------------------------------------
solve_block_lp <- function(block_data, params, t_init, soc_init = NULL, prix_terminal_per_deg = 0) {
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

  # ----------------------------------------------------------
  # Build LP model (all continuous variables)
  # ----------------------------------------------------------
  model <- MIPModel() |>
    add_variable(pac_load[t], t = 1:n, lb = 0, ub = 1, type = "continuous") |>
    add_variable(t_bal[t], t = 1:n, lb = 20, ub = params$t_max + 5) |>
    add_variable(offt[t], t = 1:n, lb = 0) |>
    add_variable(inj[t], t = 1:n, lb = 0) |>
    add_variable(slack[t], t = 1:n, lb = 0)

  if (has_batt) {
    model <- model |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min_kwh, ub = soc_max_kwh)
  }

  penalty <- if (!is.null(params$slack_penalty)) params$slack_penalty else 2.5

  # ----------------------------------------------------------
  # Objective: minimize net electricity cost + slack penalty - terminal value
  # ----------------------------------------------------------
  model <- model |>
    set_objective(
      sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n) +
        sum_expr(slack[t] * penalty, t = 1:n) -
        sum_expr(t_bal[t] * prix_terminal_per_deg, t = n:n),
      sense = "min"
    )

  # ----------------------------------------------------------
  # C1: Energy balance
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] + dischrg[t] * batt_eff ==
          conso[t] + pac_load[t] * pac_qt + chrg[t] + inj[t],
        t = 1:n
      )
  } else {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] == conso[t] + pac_load[t] * pac_qt + inj[t],
        t = 1:n
      )
  }

  # ----------------------------------------------------------
  # C2: Thermal dynamics
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(
      t_bal[1] * cap ==
        t_init * (cap - k_perte) + pac_load[1] * chaleur_pac[1] + k_perte * t_amb - ecs[1]
    ) |>
    add_constraint(
      t_bal[t] * cap ==
        t_bal[t - 1] * (cap - k_perte) + pac_load[t] * chaleur_pac[t] + k_perte * t_amb - ecs[t],
      t = 2:n
    )

  # ----------------------------------------------------------
  # C3+C4: Comfort — soft T_min via slack, hard T_max
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(t_bal[t] + slack[t] >= params$t_min, t = 1:n) |>
    add_constraint(t_bal[t] <= params$t_max, t = 1:n)

  # ----------------------------------------------------------
  # C5: Battery SOC dynamics
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
      # Anti-simultaneity relaxation: can't charge and discharge at full power simultaneously
      add_constraint(chrg[t] + dischrg[t] <= batt_pw, t = 1:n)
  }

  # ----------------------------------------------------------
  # Solve
  # ----------------------------------------------------------
  result <- tryCatch(
    solve_model(model, with_ROI(solver = "highs", verbose = FALSE)),
    error = function(e) {
      message("[LP Optimizer] Solver error: ", e$message)
      return(NULL)
    }
  )

  if (is.null(result) || result$status != "success") {
    message(sprintf("[LP Optimizer] Status: %s",
      if (!is.null(result)) result$status else "NULL"))
    return(NULL)
  }

  # ----------------------------------------------------------
  # Extract solution
  # ----------------------------------------------------------
  pac_sol <- get_solution(result, pac_load[t])$value
  t_bal_sol <- get_solution(result, t_bal[t])$value
  offt_sol <- get_solution(result, offt[t])$value
  inj_sol <- get_solution(result, inj[t])$value

  if (has_batt) {
    chrg_sol <- get_solution(result, chrg[t])$value
    dischrg_sol <- get_solution(result, dischrg[t])$value
    soc_sol <- get_solution(result, soc[t])$value
  } else {
    chrg_sol <- rep(0, n)
    dischrg_sol <- rep(0, n)
    soc_sol <- rep(0, n)
  }

  tibble(
    sim_pac_on = pac_sol,  # continuous 0-1 (fraction of rated power)
    sim_t_ballon = t_bal_sol,
    sim_offtake = offt_sol,
    sim_intake = inj_sol,
    sim_cop = cop,
    decision_raison = "optimizer_lp",
    batt_soc = if (has_batt) soc_sol / params$batt_kwh else 0,
    batt_flux = chrg_sol - dischrg_sol
  )
}

# -----------------------------------------------------------------------------
# run_optimization_lp — LP optimizer for the entire period, block by block
# -----------------------------------------------------------------------------
run_optimization_lp <- function(df, params) {
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
        decision_raison = "optimizer_lp_fallback",
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
        full_result <- solve_block_lp(block_data, params_iter, t_init, soc_init, prix_terminal_per_deg)
        if (is.null(full_result) || cop_iter == 2) break
        t_bal_solved <- full_result$sim_t_ballon
        params_iter$cop_override <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
      }

      if (is.null(full_result)) {
        message(sprintf("[LP Optimizer] Block %d infeasible, fallback to baseline", b))
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
    message(sprintf("[LP Optimizer] %d rows vs %d expected", nrow(results_df), n))
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
    mode_actif = "optimizer_lp"
  )
}
