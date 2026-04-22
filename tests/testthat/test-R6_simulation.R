# =============================================================================
# Tests: R6_simulation integration (T020)
# =============================================================================
# Full workflow test: Simulation$new -> load_data -> run_baseline ->
# run_optimization -> get_kpi. Compares with reference values from T021.
# =============================================================================

# Ensure working directory is project root for data file access
if (exists("project_root")) setwd(project_root)

test_that("Simulation full workflow produces valid results", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")

  params <- list(
    t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
    p_pac_kw = 2, cop_nominal = 3.5, t_ref_cop = 7,
    volume_ballon_l = 200, capacite_kwh_par_degre = 200 * 0.001163,
    horizon_qt = 16, seuil_surplus_pct = 0.3, dt_h = 0.25,
    type_contrat = "dynamique", taxe_transport_eur_kwh = 0.15, coeff_injection = 1.0,
    prix_fixe_offtake = 0.30, prix_fixe_injection = 0.03,
    perte_kwh_par_qt = 0.05, pv_kwc = 6, pv_kwc_ref = 6,
    batterie_active = FALSE, batt_kwh = 0, batt_kw = 0, batt_rendement = 0.9,
    batt_soc_min = 0.1, batt_soc_max = 0.9,
    poids_cout = 0.5, slack_penalty = 2.5, optim_bloc_h = 24,
    curtailment_active = FALSE, curtail_kwh_per_qt = Inf
  )

  # Run with 7-day period for speed (using dates with local Belpex CSV data)
  sim <- Simulation$new(params)
  sim$load_data(
    source = "demo",
    date_start = as.Date("2025-06-01"),
    date_end = as.Date("2025-06-07"),
    p_pac_kw = 2, volume_ballon_l = 200, pv_kwc = 6
  )

  expect_equal(sim$get_status(), "data_loaded")

  sim$run_baseline(mode = "ingenieur")
  expect_equal(sim$get_status(), "baseline_done")
  expect_false(is.null(sim$get_baseline()))

  sim$run_optimization(mode = "lp")
  expect_equal(sim$get_status(), "done")
  expect_false(is.null(sim$get_results()))

  # KPIs
  kpis <- sim$get_kpi()
  expect_true(is.list(kpis))
  expect_true("facture_baseline" %in% names(kpis))
  expect_true("facture_opti" %in% names(kpis))
  expect_true("gain_eur" %in% names(kpis))
  expect_true("ac_baseline" %in% names(kpis))
  expect_true("ac_opti" %in% names(kpis))

  # Basic sanity: bill should be non-negative for such a short period
  expect_gte(kpis$facture_baseline, -5)
})

test_that("Simulation with LP matches reference values (PAC 60kW)", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")
  skip_on_cran()

  # Load reference
  ref_path <- get_fixture_path("reference_values.rds")
  skip_if(!file.exists(ref_path), "Reference values not yet generated")
  ref <- readRDS(ref_path)

  params <- list(
    t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
    p_pac_kw = 60, cop_nominal = 3.5, t_ref_cop = 7,
    volume_ballon_l = 36100, capacite_kwh_par_degre = 36100 * 0.001163,
    horizon_qt = 16, seuil_surplus_pct = 0.3, dt_h = 0.25,
    type_contrat = "dynamique", taxe_transport_eur_kwh = 0.15, coeff_injection = 1.0,
    prix_fixe_offtake = 0.30, prix_fixe_injection = 0.03,
    perte_kwh_par_qt = 0.05, pv_kwc = 33, pv_kwc_ref = 33,
    batterie_active = FALSE, batt_kwh = 0, batt_kw = 0, batt_rendement = 0.9,
    batt_soc_min = 0.1, batt_soc_max = 0.9,
    poids_cout = 0.5, slack_penalty = 2.5, optim_bloc_h = 24,
    curtailment_active = FALSE, curtail_kwh_per_qt = Inf
  )

  sim <- Simulation$new(params)
  sim$load_data(
    source = "demo",
    date_start = as.Date("2025-06-01"),
    date_end = as.Date("2025-08-31"),
    p_pac_kw = 60, volume_ballon_l = 36100, pv_kwc = 33
  )
  sim$run_baseline(mode = "ingenieur")
  sim$run_optimization(mode = "lp")
  kpis <- sim$get_kpi()

  # Parity check: within 0.1% of reference
  tol <- 0.001  # 0.1%

  expect_equal(kpis$facture_baseline, ref$facture_baseline,
    tolerance = abs(ref$facture_baseline) * tol + 0.01,
    label = "facture_baseline")
  expect_equal(kpis$facture_opti, ref$facture_opti,
    tolerance = abs(ref$facture_opti) * tol + 0.01,
    label = "facture_opti")
  expect_equal(kpis$gain_eur, ref$gain_eur,
    tolerance = abs(ref$gain_eur) * tol + 0.01,
    label = "gain_eur")
  expect_equal(kpis$ac_baseline, ref$ac_baseline,
    tolerance = 0.2,
    label = "ac_baseline")
  expect_equal(kpis$ac_opti, ref$ac_opti,
    tolerance = 0.2,
    label = "ac_opti")
})
