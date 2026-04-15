# =============================================================================
# Module Optimizer — MILP optimization using ompr + HiGHS
# =============================================================================
# Resout par blocs glissants un probleme MILP qui minimise le cout net
# en respectant les contraintes physiques (PAC, ballon, batterie).
# Le confort est assure par une contrainte de temperature en fin de bloc.
# =============================================================================

library(ompr)
library(ompr.roi)
library(ROI.plugin.highs)

# -----------------------------------------------------------------------------
# Resoudre un bloc de N quarts d'heure
# -----------------------------------------------------------------------------
solve_block <- function(block_data, params, t_init, soc_init = NULL) {
  n <- nrow(block_data)
  if (n < 2) return(NULL)

  # Precalculs
  pac_qt <- params$p_pac_kw * params$dt_h
  cop <- calc_cop(block_data$t_ext, params$cop_nominal, params$t_ref_cop)
  chaleur_pac <- pac_qt * cop
  cap <- params$capacite_kwh_par_degre

  pv <- block_data$pv_kwh
  conso <- block_data$conso_hors_pac
  prix_off <- block_data$prix_offtake
  prix_inj <- block_data$prix_injection
  ecs <- block_data$soutirage_estime_kwh

  # Pertes proportionnelles a T (coherent avec generer_demo)
  k_perte <- 0.004 * params$dt_h
  t_amb <- 20

  has_batt <- params$batterie_active
  batt_pw <- if (has_batt) params$batt_kw * params$dt_h else 0
  batt_eff <- if (has_batt) sqrt(params$batt_rendement) else 1
  soc_min_kwh <- if (has_batt) params$batt_soc_min * params$batt_kwh else 0
  soc_max_kwh <- if (has_batt) params$batt_soc_max * params$batt_kwh else 0

  # ----------------------------------------------------------
  # Construction du modele MILP
  # ----------------------------------------------------------
  model <- MIPModel() |>
    add_variable(pac_on[t], t = 1:n, type = "binary") |>
    # Bornes physiques larges intra-bloc (les gros tirages ECS font descendre T)
    add_variable(t_bal[t], t = 1:n, lb = max(20, params$t_min - 10), ub = params$t_max + 5) |>
    add_variable(offt[t], t = 1:n, lb = 0) |>
    add_variable(inj[t], t = 1:n, lb = 0)

  # Ajouter variables batterie si active
  if (has_batt) {
    model <- model |>
      add_variable(chrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(dischrg[t], t = 1:n, lb = 0, ub = batt_pw) |>
      add_variable(soc[t], t = 1:n, lb = soc_min_kwh, ub = soc_max_kwh) |>
      add_variable(batt_ch[t], t = 1:n, type = "binary")
  }

  # ----------------------------------------------------------
  # Objectif : minimiser le cout net
  # ----------------------------------------------------------
  model <- model |>
    set_objective(
      sum_expr(offt[t] * prix_off[t] - inj[t] * prix_inj[t], t = 1:n),
      sense = "min"
    )

  # ----------------------------------------------------------
  # Contraintes : bilan energetique nodal
  # ----------------------------------------------------------
  if (has_batt) {
    model <- model |>
      add_constraint(
        pv[t] + offt[t] + dischrg[t] * batt_eff == conso[t] + pac_on[t] * pac_qt + chrg[t] + inj[t],
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
  # Contraintes : dynamique thermique
  # T(t)*cap = T(t-1)*(cap - k_perte) + pac*chaleur + k*Tamb - ecs
  # ----------------------------------------------------------
  model <- model |>
    add_constraint(
      t_bal[1] * cap == t_init * (cap - k_perte) + pac_on[1] * chaleur_pac[1] + k_perte * t_amb - ecs[1]
    ) |>
    add_constraint(
      t_bal[t] * cap == t_bal[t - 1] * (cap - k_perte) + pac_on[t] * chaleur_pac[t] + k_perte * t_amb - ecs[t],
      t = 2:n
    )

  # ----------------------------------------------------------
  # Contrainte confort : T dans [T_min, T_max] a chaque qt
  # Exception : apres un gros tirage ECS (>1 kWh), la borne basse
  # est relachee car la PAC ne peut pas compenser instantanement
  # ----------------------------------------------------------
  # Calculer la borne basse par qt : T_min sauf si gros tirage ECS
  t_min_qt <- ifelse(ecs > 1.0, params$t_min - 10, params$t_min)
  model <- model |>
    add_constraint(t_bal[t] >= t_min_qt[t], t = 1:n) |>
    add_constraint(t_bal[t] <= params$t_max, t = 1:n)

  # ----------------------------------------------------------
  # Contraintes batterie
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
  # Resoudre
  # ----------------------------------------------------------
  result <- tryCatch(
    solve_model(model, with_ROI(solver = "highs", verbose = FALSE)),
    error = function(e) {
      message("[Optimizer] Erreur solveur : ", e$message)
      return(NULL)
    }
  )

  if (is.null(result) || result$status != "success") {
    message(sprintf("[Optimizer] Status: %s", if (!is.null(result)) result$status else "NULL"))
    return(NULL)
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
# Optimiser toute la periode, bloc par bloc
# -----------------------------------------------------------------------------
run_optimization_milp <- function(df, params) {
  n <- nrow(df)

  # Taille des blocs en quarts d'heure
  bloc_qt <- params$optim_bloc_h * 4  # ex: 4h * 4 = 16 qt
  n_blocs <- ceiling(n / bloc_qt)

  # Resultats accumules
  all_results <- vector("list", n_blocs)

  # Conditions initiales
  t_init <- df$t_ballon[1]
  soc_init <- if (params$batterie_active) {
    (params$batt_soc_min + params$batt_soc_max) / 2 * params$batt_kwh
  } else {
    0
  }

  for (b in seq_len(n_blocs)) {
    # Indices du bloc
    i_start <- (b - 1) * bloc_qt + 1
    i_end <- min(b * bloc_qt, n)
    block_data <- df[i_start:i_end, ]

    if (nrow(block_data) < 2) {
      # Bloc trop petit : fallback smart
      block_sim <- run_simulation(block_data, params, "smart", 0.5)
      block_result <- tibble(
        sim_pac_on = block_sim$sim_pac_on,
        sim_t_ballon = block_sim$sim_t_ballon,
        sim_offtake = block_sim$sim_offtake,
        sim_intake = block_sim$sim_intake,
        sim_cop = block_sim$sim_cop,
        decision_raison = "optimizer_fallback",
        batt_soc = block_sim$batt_soc,
        batt_flux = block_sim$batt_flux
      )
    } else {
      # Resoudre le bloc
      block_result <- solve_block(block_data, params, t_init, soc_init)

      if (is.null(block_result)) {
        # Fallback smart
        message(sprintf("[Optimizer] Bloc %d infaisable, fallback smart", b))
        block_sim <- run_simulation(block_data, params, "smart", 0.5)
        block_result <- tibble(
          sim_pac_on = block_sim$sim_pac_on,
          sim_t_ballon = block_sim$sim_t_ballon,
          sim_offtake = block_sim$sim_offtake,
          sim_intake = block_sim$sim_intake,
          sim_cop = block_sim$sim_cop,
          decision_raison = "optimizer_fallback",
          batt_soc = block_sim$batt_soc,
          batt_flux = block_sim$batt_flux
        )
      }
    }

    all_results[[b]] <- block_result

    # Chainer les conditions initiales pour le bloc suivant
    t_init <- tail(block_result$sim_t_ballon, 1)
    if (params$batterie_active) {
      soc_init <- tail(block_result$batt_soc, 1) * params$batt_kwh
    }

    # Progression
    if (exists("setProgress", mode = "function")) {
      try(setProgress(b / n_blocs, detail = sprintf("Bloc %d/%d", b, n_blocs)), silent = TRUE)
    }
  }

  # Assembler
  results_df <- bind_rows(all_results)

  if (nrow(results_df) != n) {
    message(sprintf("[Optimizer] %d lignes vs %d attendues", nrow(results_df), n))
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
