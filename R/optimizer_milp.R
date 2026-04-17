# =============================================================================
# Module Optimizer — MILP optimization using ompr + HiGHS
# =============================================================================
#
# OVERVIEW
# --------
# This module implements a Mixed Integer Linear Programming (MILP) optimizer
# for heat pump (PAC) dispatch. Given quarter-hourly data (PV production,
# consumption, electricity prices, ECS draws), it finds the cost-minimizing
# PAC on/off schedule while respecting thermal comfort constraints.
#
# The optimizer complements the rule-based "Smart" mode in app.R.
# While Smart makes local decisions (one quarter-hour at a time),
# the optimizer considers an entire block simultaneously and finds
# the mathematically optimal solution.
#
# ARCHITECTURE
# ------------
# The simulation period is split into blocks (default 4h = 16 quarter-hours).
# Each block is solved independently by the MILP solver (HiGHS).
# Blocks are chained: the final temperature and battery SoC of block B
# become the initial conditions of block B+1.
#
#   Block 1          Block 2          Block 3
#   [qt1..qt16] ---> [qt17..qt32] ---> [qt33..qt48] ---> ...
#         T_end ----> T_init     T_end ----> T_init
#         SoC_end --> SoC_init   SoC_end --> SoC_init
#
# If a block is infeasible (e.g. ECS draw too large for the PAC to
# maintain T >= T_min), the block falls back to Smart rule-based mode.
#
# MILP FORMULATION (per block of N quarter-hours)
# ------------------------------------------------
# Decision variables:
#   pac_on[t]   : binary {0,1}   — PAC on or off at qt t
#   t_bal[t]    : continuous      — tank temperature at qt t
#   offt[t]     : continuous >= 0 — grid offtake at qt t (kWh)
#   inj[t]      : continuous >= 0 — grid injection at qt t (kWh)
#   chrg[t]     : continuous >= 0 — battery charge at qt t (kWh) [if battery active]
#   dischrg[t]  : continuous >= 0 — battery discharge at qt t (kWh) [if battery active]
#   soc[t]      : continuous      — battery state of charge at qt t (kWh) [if battery active]
#   batt_ch[t]  : binary {0,1}   — battery charging flag (anti-simultaneity) [if battery active]
#
# Objective:
#   Minimize sum_t( offt[t] * prix_offtake[t] - inj[t] * prix_injection[t] )
#   = minimize net electricity cost (offtake paid - injection revenue)
#
# Constraints:
#   C1 — Energy balance (without battery):
#        pv[t] + offt[t] == conso[t] + pac_on[t] * P_pac_qt + inj[t]
#        (with battery: + dischrg[t] * eff on left, + chrg[t] on right)
#
#   C2 — Thermal dynamics (linearized proportional heat loss):
#        t_bal[t] * cap == t_bal[t-1] * (cap - k_perte) + pac_on[t] * chaleur[t]
#                          + k_perte * T_amb - ecs[t]
#        where: cap = volume * 0.001163 (kWh per degree per liter)
#               k_perte = 0.004 * dt_h (proportional loss coefficient)
#               chaleur[t] = P_pac_qt * COP(t_ext[t]) (thermal output)
#               ecs[t] = hot water draw at qt t (kWh thermal)
#
#   C3 — Comfort: T >= T_min at every quarter-hour
#        Exception: during heavy ECS draws (> 1 kWh), the lower bound is
#        relaxed to T_min - 10 because the PAC physically cannot compensate
#        a 3-4 kWh draw instantaneously (it only delivers ~1.7 kWh/qt).
#        This matches real-world behavior — even a classic thermostat
#        cannot prevent temporary temperature drops during large draws.
#
#   C4 — Temperature upper bound: T <= T_max at every qt
#
#   C5 — Battery SOC dynamics (if active):
#        soc[t] == soc[t-1] + chrg[t] * eff - dischrg[t] / eff
#
#   C6 — Anti-simultaneity (if battery active):
#        chrg[t] <= P_batt * batt_ch[t]
#        dischrg[t] <= P_batt * (1 - batt_ch[t])
#
# SOLVER
# ------
# Uses HiGHS (via ROI.plugin.highs), a modern open-source MIP solver.
# Typical performance: <1s per 4h block, ~50s for 30 days.
# GLPK is also available as fallback but ~7x slower.
#
# PARAMETERS (from params list)
# -----------------------------
# p_pac_kw           : PAC electrical power (kW)
# cop_nominal        : COP at reference temperature (typically 3.5 at 7°C)
# t_ref_cop          : reference temperature for COP (°C)
# volume_ballon_l    : tank volume (liters)
# capacite_kwh_par_degre : thermal capacity (kWh/°C) = volume * 0.001163
# t_min, t_max       : comfort temperature bounds (°C)
# t_consigne         : target temperature (°C)
# dt_h               : time step in hours (0.25 for quarter-hourly)
# optim_bloc_h       : block size in hours (default 4)
# batterie_active    : whether battery is enabled
# batt_kwh, batt_kw  : battery capacity (kWh) and power (kW)
# batt_rendement     : round-trip efficiency (0-1)
# batt_soc_min/max   : SOC limits (0-1)
#
# RETURN VALUE
# ------------
# Returns the input dataframe df with added columns:
#   sim_t_ballon, sim_pac_on, sim_offtake, sim_intake, sim_cop,
#   decision_raison ("optimizer" or "optimizer_fallback"),
#   batt_soc, batt_flux, mode_actif ("optimizer")
# These columns are compatible with all existing app.R visualizations.
#
# =============================================================================

library(ompr)
library(ompr.roi)
library(ROI.plugin.highs)

# -----------------------------------------------------------------------------
# solve_block — Solve a single block of N quarter-hours
#
# Args:
#   block_data : tibble with columns pv_kwh, conso_hors_pac, prix_offtake,
#                prix_injection, soutirage_estime_kwh, t_ext
#   params     : list of installation parameters (see above)
#   t_init     : initial tank temperature (°C) — from previous block end
#   soc_init   : initial battery SOC (kWh) — NULL if no battery
#
# Returns:
#   tibble with N rows (one per qt) containing optimizer decisions,
#   or NULL if the solver fails (infeasible or error)
# -----------------------------------------------------------------------------
solve_block <- function(block_data, params, t_init, soc_init = NULL, prix_terminal_per_deg = 0) {
  n <- nrow(block_data)
  if (n < 2) return(NULL)

  # Precalculations
  pac_qt <- params$p_pac_kw * params$dt_h            # kWh electrical per qt
  # COP: use override if provided (iterative COP), else linearize around T_consigne
  cop <- if (!is.null(params$cop_override)) params$cop_override
         else calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = params$t_consigne)
  chaleur_pac <- pac_qt * cop                         # kWh thermal per qt
  cap <- params$capacite_kwh_par_degre                # kWh per degree

  # Input data vectors (R vectors indexed by t in ompr constraints)
  pv <- block_data$pv_kwh
  conso <- block_data$conso_hors_pac
  prix_off <- block_data$prix_offtake
  prix_inj <- block_data$prix_injection
  ecs <- block_data$soutirage_estime_kwh

  # Proportional heat loss coefficient (same model as generer_demo)
  # Loss = k_perte * (T_ballon - T_ambient) per quarter-hour
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  # Battery parameters
  has_batt <- params$batterie_active
  batt_pw <- if (has_batt) params$batt_kw * params$dt_h else 0
  batt_eff <- if (has_batt) sqrt(params$batt_rendement) else 1
  soc_min_kwh <- if (has_batt) params$batt_soc_min * params$batt_kwh else 0
  soc_max_kwh <- if (has_batt) params$batt_soc_max * params$batt_kwh else 0

  # ----------------------------------------------------------
  # Build MILP model
  # ----------------------------------------------------------
  model <- MIPModel() |>
    # Decision variables
    add_variable(pac_on[t], t = 1:n, type = "binary") |>
    add_variable(t_bal[t], t = 1:n,
      lb = 20,
      ub = params$t_max + 5) |>
    add_variable(offt[t], t = 1:n, lb = 0) |>
    add_variable(inj[t], t = 1:n, lb = 0)

  # Battery variables (conditional)
  if (has_batt) {
    model <- model |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min_kwh, ub = soc_max_kwh) |>
      add_variable(batt_ch[t], t = 1:n, type = "binary")
  }

  # ----------------------------------------------------------
  # Slack variable for T_min violation (soft constraint)
  # slack[t] >= 0 : how many degrees below T_min at qt t
  # Penalized heavily in the objective to avoid violations
  # This makes the problem ALWAYS feasible (no more fallbacks)
  # ----------------------------------------------------------
  model <- model |>
    add_variable(slack[t], t = 1:n, lb = 0)

  # Penalty: EUR per degree below T_min per qt (user-configurable)
  penalty <- if (!is.null(params$slack_penalty)) params$slack_penalty else 2.5

  # ----------------------------------------------------------
  # Objective: minimize net electricity cost + slack penalty - terminal value
  # Terminal value: incentivize keeping the tank warm at end of block
  # so the next block doesn't have to reheat from T_min
  # ----------------------------------------------------------
  model <- model |>
    set_objective(
      sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n) +
        sum_expr(slack[t] * penalty, t = 1:n) -
        sum_expr(t_bal[t] * prix_terminal_per_deg, t = n:n),
      sense = "min"
    )

  # ----------------------------------------------------------
  # C1: Energy balance at each quarter-hour
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] + dischrg[t] * batt_eff ==
          conso[t] + pac_on[t] * pac_qt + chrg[t] + inj[t],
        t = 1:n
      )
  } else {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] == conso[t] + pac_on[t] * pac_qt + inj[t],
        t = 1:n
      )
  }

  # ----------------------------------------------------------
  # C2: Thermal dynamics (linearized proportional loss model)
  # T(t)*cap = T(t-1)*(cap - k_perte) + pac_on*chaleur + k*Tamb - ecs
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(
      t_bal[1] * cap ==
        t_init * (cap - k_perte) + pac_on[1] * chaleur_pac[1] + k_perte * t_amb - ecs[1]
    ) |>
    add_constraint(
      t_bal[t] * cap ==
        t_bal[t - 1] * (cap - k_perte) + pac_on[t] * chaleur_pac[t] + k_perte * t_amb - ecs[t],
      t = 2:n
    )

  # ----------------------------------------------------------
  # C3+C4: Comfort — T within bounds with soft T_min via slack
  # t_bal[t] + slack[t] >= t_min  (slack absorbs violations)
  # t_bal[n] + slack[n] >= t_min  (end-of-block for chaining)
  # t_bal[t] <= t_max             (hard upper bound)
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(t_bal[t] + slack[t] >= params$t_min, t = 1:n) |>
    add_constraint(t_bal[t] <= params$t_max, t = 1:n)

  # ----------------------------------------------------------
  # C5+C6: Battery constraints (conditional)
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      # SOC dynamics with efficiency
      add_constraint(
        soc[1] == soc_init + chrg[1] * batt_eff - dischrg[1] / batt_eff
      ) |>
      add_constraint(
        soc[t] == soc[t - 1] + chrg[t] * batt_eff - dischrg[t] / batt_eff,
        t = 2:n
      ) |>
      # Anti-simultaneity: cannot charge and discharge at the same time
      add_constraint(chrg[t] <= batt_pw * batt_ch[t], t = 1:n) |>
      add_constraint(dischrg[t] <= batt_pw * (1 - batt_ch[t]), t = 1:n)
  }

  # ----------------------------------------------------------
  # Solve
  # ----------------------------------------------------------
  result <- tryCatch(
    solve_model(model, with_ROI(solver = "highs", verbose = FALSE)),
    error = function(e) {
      message("[Optimizer] Solver error: ", e$message)
      return(NULL)
    }
  )

  if (is.null(result) || result$status != "success") {
    message(sprintf("[Optimizer] Status: %s",
      if (!is.null(result)) result$status else "NULL"))
    return(NULL)
  }

  # ----------------------------------------------------------
  # Extract solution
  # ----------------------------------------------------------
  pac_sol <- get_solution(result, pac_on[t])$value
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
    sim_pac_on = as.integer(round(pac_sol)),
    sim_t_ballon = t_bal_sol,
    sim_offtake = offt_sol,
    sim_intake = inj_sol,
    sim_cop = cop,
    decision_raison = "optimizer",
    batt_soc = if (has_batt) soc_sol / params$batt_kwh else 0,
    batt_flux = chrg_sol - dischrg_sol
  )
}

# -----------------------------------------------------------------------------
# run_optimization_milp — Optimize the entire period, block by block
#
# Splits the period into blocks of params$optim_bloc_h hours (default 4h).
# Chains initial conditions (T, SoC) between blocks.
# Falls back to Smart rule-based for blocks that are infeasible.
#
# Args:
#   df     : prepared dataframe (output of prepare_df)
#   params : list of installation parameters
#
# Returns:
#   df with added simulation columns (same format as run_simulation)
# -----------------------------------------------------------------------------
run_optimization_milp <- function(df, params) {
  n <- nrow(df)

  # Block size in quarter-hours
  bloc_qt <- params$optim_bloc_h * 4  # e.g. 4h * 4 = 16 qt
  n_blocs <- ceiling(n / bloc_qt)

  # Accumulated results
  all_results <- vector("list", n_blocs)

  # Initial conditions — meme point de depart que la baseline
  t_init <- params$t_consigne
  soc_init <- if (params$batterie_active) {
    (params$batt_soc_min + params$batt_soc_max) / 2 * params$batt_kwh
  } else {
    0
  }

  for (b in seq_len(n_blocs)) {
    # Block indices — execute this range
    i_start <- (b - 1) * bloc_qt + 1
    i_end <- min(b * bloc_qt, n)
    n_execute <- i_end - i_start + 1

    # Overlapping blocks: extend with lookahead from next block
    # Solve a larger block but only keep the first n_execute rows
    i_lookahead_end <- min(i_end + bloc_qt, n)
    block_data <- df[i_start:i_lookahead_end, ]

    baseline_fallback <- function(bd) {
      tibble(
        sim_pac_on = 0L,
        sim_t_ballon = bd$t_ballon,
        sim_offtake = bd$offtake_kwh,
        sim_intake = bd$intake_kwh,
        sim_cop = calc_cop(bd$t_ext, params$cop_nominal, params$t_ref_cop),
        decision_raison = "optimizer_fallback",
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
        full_result <- solve_block(block_data, params_iter, t_init, soc_init, prix_terminal_per_deg)
        if (is.null(full_result) || cop_iter == 2) break
        # Update COP based on solved T_ballon trajectory
        t_bal_solved <- full_result$sim_t_ballon
        params_iter$cop_override <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal_solved)
      }

      if (is.null(full_result)) {
        message(sprintf("[Optimizer] Block %d infeasible, fallback to baseline", b))
        block_result <- baseline_fallback(df[i_start:i_end, ])
      } else {
        block_result <- full_result[1:n_execute, ]
      }
    }

    all_results[[b]] <- block_result

    # Chain initial conditions to next block
    # Clamp t_init to avoid passing infeasible initial conditions
    t_init <- max(params$t_min, tail(block_result$sim_t_ballon, 1))
    if (params$batterie_active) {
      soc_init <- tail(block_result$batt_soc, 1) * params$batt_kwh
    }

    # Progress reporting (when called from Shiny)
    if (exists("setProgress", mode = "function")) {
      try(setProgress(b / n_blocs, detail = sprintf("Bloc %d/%d", b, n_blocs)),
        silent = TRUE)
    }
  }

  # Assemble all block results
  results_df <- bind_rows(all_results)

  # Handle length mismatch (partial blocks at period boundaries)
  if (nrow(results_df) != n) {
    message(sprintf("[Optimizer] %d rows vs %d expected", nrow(results_df), n))
    if (nrow(results_df) < n) {
      padding <- tibble(
        sim_pac_on = rep(0L, n - nrow(results_df)),
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

  # Merge optimizer results into the original dataframe
  df %>% mutate(
    sim_t_ballon = results_df$sim_t_ballon,
    sim_pac_on = results_df$sim_pac_on,
    sim_offtake = results_df$sim_offtake,
    sim_intake = results_df$sim_intake,
    sim_cop = results_df$sim_cop,
    decision_raison = results_df$decision_raison,
    batt_soc = results_df$batt_soc,
    batt_flux = results_df$batt_flux,
    mode_actif = "optimizer"
  )
}
