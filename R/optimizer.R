# =============================================================================
# Module Optimizer — MILP optimization using ompr + GLPK
# =============================================================================
# Resout jour par jour un probleme MILP qui minimise le cout net
# en respectant les contraintes physiques (PAC, ballon, batterie).
# =============================================================================

library(ompr)
library(ompr.roi)
library(ROI.plugin.glpk)

# -----------------------------------------------------------------------------
# Resoudre un jour (96 quarts d'heure)
# -----------------------------------------------------------------------------
solve_one_day <- function(day_data, params, t_init, soc_init = NULL) {
  n <- nrow(day_data)  # should be 96

  # Precalculs
  pac_qt <- params$p_pac_kw * params$dt_h  # kWh elec par qt
  cop <- calc_cop(day_data$t_ext, params$cop_nominal, params$t_ref_cop)
  chaleur_pac <- pac_qt * cop  # kWh thermique par qt
  cap <- params$capacite_kwh_par_degre

  pv <- day_data$pv_kwh
  conso <- day_data$conso_hors_pac
  prix_off <- day_data$prix_offtake
  prix_inj <- day_data$prix_injection
  perte <- rep(params$perte_kwh_par_qt, n)
  ecs <- day_data$soutirage_estime_kwh

  has_batt <- params$batterie_active
  batt_pw <- if (has_batt) params$batt_kw * params$dt_h else 0
  batt_eff <- if (has_batt) sqrt(params$batt_rendement) else 1
  soc_min <- if (has_batt) params$batt_soc_min * params$batt_kwh else 0
  soc_max <- if (has_batt) params$batt_soc_max * params$batt_kwh else 0

  # Big-M pour linearisation
  M_elec <- max(pv) + params$p_pac_kw + 50  # borne sup flux electrique

  # ----------------------------------------------------------
  # Formulation MILP
  # ----------------------------------------------------------
  model <- MIPModel() |>

    # Variables de decision
    add_variable(pac_on[t], t = 1:n, type = "binary") |>
    add_variable(t_bal[t], t = 1:n, lb = params$t_min, ub = params$t_max) |>
    add_variable(offt[t], t = 1:n, lb = 0) |>
    add_variable(inj[t], t = 1:n, lb = 0) |>

    # Objectif : minimiser le cout net
    set_objective(
      sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n),
      sense = "min"
    ) |>

    # C1: Bilan energetique nodal (sans batterie d'abord)
    # pv + offtake = conso + pac_elec + injection  (+ charge - discharge si batterie)
    add_constraint(
      pv[t] + offt[t] == conso[t] + pac_on[t] * pac_qt + inj[t],
      t = 1:n
    ) |>

    # C2: Dynamique thermique - t=1
    add_constraint(
      t_bal[1] == t_init + (pac_on[1] * chaleur_pac[1] - perte[1] - ecs[1]) / cap
    ) |>

    # C2: Dynamique thermique - t=2..n
    add_constraint(
      t_bal[t] == t_bal[t - 1] + (pac_on[t] * chaleur_pac[t] - perte[t] - ecs[t]) / cap,
      t = 2:n
    )

  # ----------------------------------------------------------
  # Variables et contraintes batterie (si activee)
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min, ub = soc_max) |>
      add_variable(batt_ch[t], t = 1:n, type = "binary") |>

      # Modifier le bilan energetique : ajouter batterie
      # On doit le reformuler car ompr ne supporte pas la modification de contraintes
      # => On supprime les contraintes C1 et les re-ajoute avec batterie
      # En fait, on ne peut pas supprimer. On ajoute des contraintes correctives.
      # Approche : annuler C1 et refaire. Pas possible avec ompr.
      # Solution : construire le modele avec batterie des le depart.
      # => Refactoring : on reconstruit le modele.
      identity()

    # Le modele doit etre reconstruit avec batterie dans le bilan.
    # Reconstruisons proprement.
    model <- MIPModel() |>
      add_variable(pac_on[t], t = 1:n, type = "binary") |>
      add_variable(t_bal[t], t = 1:n, lb = params$t_min, ub = params$t_max) |>
      add_variable(offt[t], t = 1:n, lb = 0) |>
      add_variable(inj[t], t = 1:n, lb = 0) |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min, ub = soc_max) |>
      add_variable(batt_ch[t], t = 1:n, type = "binary") |>

      # Objectif
      set_objective(
        sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n),
        sense = "min"
      ) |>

      # Bilan energetique avec batterie
      add_constraint(
        pv[t] + offt[t] + dischrg[t] * batt_eff == conso[t] + pac_on[t] * pac_qt + chrg[t] + inj[t],
        t = 1:n
      ) |>

      # Dynamique thermique
      add_constraint(
        t_bal[1] == t_init + (pac_on[1] * chaleur_pac[1] - perte[1] - ecs[1]) / cap
      ) |>
      add_constraint(
        t_bal[t] == t_bal[t - 1] + (pac_on[t] * chaleur_pac[t] - perte[t] - ecs[t]) / cap,
        t = 2:n
      ) |>

      # SOC dynamique
      add_constraint(
        soc[1] == soc_init + chrg[1] * batt_eff - dischrg[1] / batt_eff
      ) |>
      add_constraint(
        soc[t] == soc[t - 1] + chrg[t] * batt_eff - dischrg[t] / batt_eff,
        t = 2:n
      ) |>

      # Anti-simultaneite charge/decharge
      add_constraint(chrg[t] <= batt_pw * batt_ch[t], t = 1:n) |>
      add_constraint(dischrg[t] <= batt_pw * (1 - batt_ch[t]), t = 1:n)
  }

  # ----------------------------------------------------------
  # Resoudre
  # ----------------------------------------------------------
  result <- tryCatch(
    solve_model(model, with_ROI(solver = "glpk", verbose = FALSE)),
    error = function(e) {
      message("[Optimizer] Erreur solveur : ", e$message)
      return(NULL)
    }
  )

  if (is.null(result) || result$status != 0) {
    return(NULL)  # infeasible ou erreur
  }

  # ----------------------------------------------------------
  # Extraire les resultats
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
# Optimiser toute la periode, jour par jour
# -----------------------------------------------------------------------------
run_optimization_milp <- function(df, params) {
  n <- nrow(df)
  jours <- unique(as.Date(df$timestamp))
  n_jours <- length(jours)

  # Resultats accumules
  all_results <- vector("list", n_jours)

  # Conditions initiales
  t_init <- df$t_ballon[1]
  soc_init <- if (params$batterie_active) {
    (params$batt_soc_min + params$batt_soc_max) / 2 * params$batt_kwh
  } else {
    0
  }

  for (d in seq_along(jours)) {
    # Extraire les donnees du jour
    day_mask <- as.Date(df$timestamp) == jours[d]
    day_data <- df[day_mask, ]

    if (nrow(day_data) == 0) next

    # Resoudre le jour
    day_result <- solve_one_day(day_data, params, t_init, soc_init)

    if (is.null(day_result)) {
      # Fallback : mode smart rule-based pour ce jour
      message(sprintf("[Optimizer] Jour %s infaisable, fallback smart", jours[d]))
      day_sim <- run_simulation(day_data, params, "smart", 0.5)
      day_result <- tibble(
        sim_pac_on = day_sim$sim_pac_on,
        sim_t_ballon = day_sim$sim_t_ballon,
        sim_offtake = day_sim$sim_offtake,
        sim_intake = day_sim$sim_intake,
        sim_cop = day_sim$sim_cop,
        decision_raison = "optimizer_fallback",
        batt_soc = day_sim$batt_soc,
        batt_flux = day_sim$batt_flux
      )
    }

    all_results[[d]] <- day_result

    # Chainer les conditions initiales
    t_init <- tail(day_result$sim_t_ballon, 1)
    if (params$batterie_active) {
      soc_init <- tail(day_result$batt_soc, 1) * params$batt_kwh
    }

    # Progression (si appele depuis Shiny)
    if (exists("setProgress", mode = "function")) {
      try(setProgress(d / n_jours, detail = sprintf("Jour %d/%d", d, n_jours)), silent = TRUE)
    }
  }

  # Assembler les resultats
  results_df <- bind_rows(all_results)

  if (nrow(results_df) != n) {
    # Padding si jours incomplets
    message(sprintf("[Optimizer] %d lignes vs %d attendues — padding", nrow(results_df), n))
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

  # Fusionner avec le df original
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
