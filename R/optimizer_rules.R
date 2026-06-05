# =============================================================================
# Rule-based optimizer — Transparent, auditable PAC dispatch
# =============================================================================
#
# Simple rules applied at each quarter-hour, in priority order:
#   1. T_ballon < T_min         → PAC ON (comfort, non-negotiable)
#   2. T_ballon > T_max         → PAC OFF (overheating protection)
#   3. Surplus PV > PAC power   → PAC ON (free solar, autoconsumption)
#   4. Prix < percentile seuil  → PAC ON (cheap electricity, pre-heat)
#   5. Otherwise                → PAC OFF (save money)
#
# Each decision is logged with a human-readable reason.
# No solver, no black box, no lookahead.
# =============================================================================

#' Run rule-based optimization for dual PAC
#'
#' @param df Prepared dataframe (from Baseline/prepare_df)
#' @param params Parameter list
#' @return The dataframe with sim_* columns added
#' @export
run_optimization_rules <- function(df, params) {
  n <- nrow(df)

  # Parameters
  t_min <- params$t_min
  t_max <- params$t_max
  t_consigne <- params$t_consigne
  pac1_qt <- params$p_pac_kw * params$dt_h
  pac2_active <- isTRUE(params$pac2_active)
  pac2_qt <- if (pac2_active) params$p_pac2_kw * params$dt_h else 0
  prix_percentile <- if (!is.null(params$rules_prix_percentile)) params$rules_prix_percentile / 100 else 0.30
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20
  cap <- params$capacite_kwh_par_degre

  # COP functions
  cop1_fn <- if (params$pac1_type == "gshp") calc_cop_gshp else calc_cop
  cop2_fn <- if (pac2_active) {
    if (params$pac2_type == "gshp") calc_cop_gshp else calc_cop
  } else NULL

  # Source temperature vectors
  t_sol <- if ("t_sol" %in% names(df)) df$t_sol else rep(params$t_sol_constant, n)
  t_ext <- df$t_ext

  # Pre-compute daily price percentiles
  df$date <- as.Date(df$timestamp, tz = "Europe/Brussels")
  daily_thresholds <- tapply(df$prix_offtake, df$date, function(x) {
    quantile(x, prix_percentile, na.rm = TRUE)
  })
  prix_seuil <- daily_thresholds[as.character(df$date)]

  # PV and consumption
  pv <- df$pv_kwh
  conso <- df$conso_hors_pac
  surplus_pv <- pmax(0, pv - conso)

  # --- Simulation loop ---
  t_bal <- numeric(n)
  pac1_on <- integer(n)
  pac2_on <- integer(n)
  raison <- character(n)

  t_bal[1] <- if ("t_ballon" %in% names(df) && !is.na(df$t_ballon[1])) {
    df$t_ballon[1]
  } else {
    t_consigne
  }

  for (i in seq_len(n)) {
    t_now <- if (i == 1) t_bal[1] else t_bal[i - 1]

    # COP at this timestep
    cop1 <- cop1_fn(t_sol[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_now)
    chaleur1 <- pac1_qt * cop1

    cop2 <- 0; chaleur2 <- 0
    if (pac2_active && !is.null(cop2_fn)) {
      cop2 <- cop2_fn(t_ext[i], params$cop2_nominal, params$t_ref_cop2, t_ballon = t_now)
      chaleur2 <- pac2_qt * cop2
    }

    # ECS demand
    ecs <- if ("soutirage_estime_kwh" %in% names(df)) df$soutirage_estime_kwh[i] else 0

    # --- Rule evaluation (priority order) ---
    p1 <- 0L; p2 <- 0L; why <- "off (defaut)"

    if (t_now < t_min) {
      # Rule 1: COMFORT — must heat
      p1 <- 1L
      if (pac2_active && t_now < t_min - 3) {
        p2 <- 1L
        why <- sprintf("confort urgent (T=%.1f < %.0f-3)", t_now, t_min)
      } else {
        why <- sprintf("confort (T=%.1f < T_min=%.0f)", t_now, t_min)
      }
    } else if (t_now >= t_max) {
      # Rule 2: OVERHEATING — must stop
      p1 <- 0L; p2 <- 0L
      why <- sprintf("T_max atteint (T=%.1f >= %.0f)", t_now, t_max)
    } else if (surplus_pv[i] > pac1_qt * 0.5) {
      # Rule 3: PV SURPLUS — autoconsume
      p1 <- 1L
      if (pac2_active && surplus_pv[i] > pac1_qt + pac2_qt * 0.5) {
        p2 <- 1L
        why <- sprintf("surplus PV (%.1f kWh)", surplus_pv[i])
      } else {
        why <- sprintf("surplus PV (%.1f kWh, PAC1 seule)", surplus_pv[i])
      }
    } else if (df$prix_offtake[i] <= prix_seuil[i]) {
      # Rule 4: CHEAP PRICE — pre-heat
      p1 <- 1L
      why <- sprintf("prix bas (%.0f <= seuil %.0f EUR/MWh)",
        df$prix_offtake[i] * 1000, prix_seuil[i] * 1000)
    } else {
      # Rule 5: DEFAULT — save money
      p1 <- 0L; p2 <- 0L
      why <- sprintf("prix haut (%.0f > seuil %.0f EUR/MWh)",
        df$prix_offtake[i] * 1000, prix_seuil[i] * 1000)
    }

    pac1_on[i] <- p1
    pac2_on[i] <- p2
    raison[i] <- why

    # Thermal dynamics
    chaleur_total <- p1 * chaleur1 + p2 * chaleur2
    pertes <- k_perte * (t_now - t_amb)
    t_bal[i] <- t_now + (chaleur_total - pertes - ecs) / cap
  }

  # Compute electrical outputs
  pac1_kwh <- pac1_on * pac1_qt
  pac2_kwh <- pac2_on * pac2_qt
  pac_total_kwh <- pac1_kwh + pac2_kwh

  # COP vectors (for output)
  cop1_vec <- cop1_fn(t_sol, params$cop_nominal, params$t_ref_cop, t_ballon = t_bal)
  cop2_vec <- if (pac2_active && !is.null(cop2_fn)) {
    cop2_fn(t_ext, params$cop2_nominal, params$t_ref_cop2, t_ballon = t_bal)
  } else {
    rep(0, n)
  }

  # Energy balance: offtake and injection
  conso_totale <- pac_total_kwh + conso
  sim_offtake <- pmax(0, conso_totale - pv)
  sim_intake <- pmax(0, pv - conso_totale)

  # Weighted average COP
  sim_cop <- ifelse(pac_total_kwh > 0,
    (pac1_kwh * cop1_vec + pac2_kwh * cop2_vec) / pac_total_kwh,
    (cop1_vec + cop2_vec) / 2)

  df %>% dplyr::mutate(
    sim_t_ballon = t_bal,
    sim_pac_on = pac1_on + pac2_on,
    sim_pac1_on = pac1_on,
    sim_pac2_load = pac2_on,
    sim_pac1_kwh = pac1_kwh,
    sim_pac2_kwh = pac2_kwh,
    sim_cop1 = cop1_vec,
    sim_cop2 = cop2_vec,
    sim_offtake = sim_offtake,
    sim_intake = sim_intake,
    sim_cop = sim_cop,
    decision_raison = raison,
    batt_soc = 0,
    batt_flux = 0,
    mode_actif = "rules"
  )
}
