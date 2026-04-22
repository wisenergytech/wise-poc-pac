# =============================================================================
# Tests: R6_kpi (T019)
# =============================================================================

# Helper: create known test data for KPI calculation
make_kpi_test_data <- function() {
  n <- 96
  baseline <- tibble::tibble(
    offtake_kwh = c(rep(1.0, 48), rep(0.5, 48)),   # 72 kWh total
    intake_kwh = c(rep(0.2, 48), rep(0.8, 48)),     # 48 kWh total
    prix_offtake = rep(0.20, n),
    prix_injection = rep(0.05, n),
    t_ballon = rep(50, n),
    pv_kwh = rep(1.0, n),  # 96 kWh total PV
    conso_hors_pac = rep(0.3, n)  # 28.8 kWh total
  )

  sim <- tibble::tibble(
    sim_offtake = c(rep(0.8, 48), rep(0.3, 48)),    # 52.8 kWh total
    sim_intake = c(rep(0.3, 48), rep(1.0, 48)),      # 62.4 kWh total
    prix_offtake = rep(0.20, n),
    prix_injection = rep(0.05, n),
    sim_t_ballon = rep(50, n),
    pv_kwh = rep(1.0, n),
    sim_pac_on = rep(1, n),  # PAC always on
    conso_hors_pac = rep(0.3, n)
  )

  list(baseline = baseline, sim = sim, n = n)
}

test_that("get_facture computes correctly for baseline", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  # Baseline: offtake * prix_offtake - intake * prix_injection
  # = 72 * 0.20 - 48 * 0.05 = 14.4 - 2.4 = 12.0
  facture <- kpi$get_facture(td$baseline, type = "baseline")
  expect_equal(facture, 12.0, tolerance = 0.01)
})

test_that("get_facture computes correctly for optimized", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  # Optimized: sim_offtake * prix_offtake - sim_intake * prix_injection
  # = 52.8 * 0.20 - 62.4 * 0.05 = 10.56 - 3.12 = 7.44
  facture <- kpi$get_facture(td$sim, type = "optimized")
  expect_equal(facture, 7.44, tolerance = 0.01)
})

test_that("get_cout_soutirage computes correctly", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  # Baseline: 72 * 0.20 = 14.4
  expect_equal(kpi$get_cout_soutirage(td$baseline, type = "baseline"), 14.4, tolerance = 0.01)

  # Optimized: 52.8 * 0.20 = 10.56
  expect_equal(kpi$get_cout_soutirage(td$sim, type = "optimized"), 10.56, tolerance = 0.01)
})

test_that("get_rev_injection computes correctly", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  # Baseline: 48 * 0.05 = 2.4
  expect_equal(kpi$get_rev_injection(td$baseline, type = "baseline"), 2.4, tolerance = 0.01)

  # Optimized: 62.4 * 0.05 = 3.12
  expect_equal(kpi$get_rev_injection(td$sim, type = "optimized"), 3.12, tolerance = 0.01)
})

test_that("get_autoconsommation computes correctly", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  pv_total <- sum(td$baseline$pv_kwh)  # 96

  # Baseline: 1 - 48/96 = 0.5 => 50%
  ac_bl <- kpi$get_autoconsommation(td$baseline, pv_total, type = "baseline")
  expect_equal(ac_bl, 50.0, tolerance = 0.1)

  # Optimized: 1 - 62.4/96 = 0.35 => 35%
  ac_opt <- kpi$get_autoconsommation(td$sim, pv_total, type = "optimized")
  expect_equal(ac_opt, 35.0, tolerance = 0.1)
})

test_that("get_autosuffisance computes correctly", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()

  pv_total <- sum(td$baseline$pv_kwh)  # 96

  # Baseline: autoconso = 96 - 48 = 48, conso_totale = 72 + 48 = 120
  # autosuffisance = 48 / 120 = 40%
  as_bl <- kpi$get_autosuffisance(td$baseline, pv_total, type = "baseline")
  expect_equal(as_bl, 40.0, tolerance = 0.1)

  # Optimized: autoconso = 96 - 62.4 = 33.6, conso_totale = 52.8 + 33.6 = 86.4
  # autosuffisance = 33.6 / 86.4 = 38.9%
  as_opt <- kpi$get_autosuffisance(td$sim, pv_total, type = "optimized")
  expect_equal(as_opt, 38.9, tolerance = 0.1)
})

test_that("get_conformite computes correctly", {
  kpi <- KPICalculator$new()

  # All within bounds: 100%
  t_bal <- rep(50, 100)
  expect_equal(kpi$get_conformite(t_bal, t_min = 45, t_max = 55), 100)

  # 10% below t_min: 90%
  t_bal <- c(rep(50, 90), rep(40, 10))
  expect_equal(kpi$get_conformite(t_bal, t_min = 45, t_max = 55), 90)

  # 5% above t_max: 95%
  t_bal <- c(rep(50, 95), rep(60, 5))
  expect_equal(kpi$get_conformite(t_bal, t_min = 45, t_max = 55), 95)
})

test_that("compute returns all expected KPI fields", {
  kpi <- KPICalculator$new()
  td <- make_kpi_test_data()
  params <- list(t_min = 45, t_max = 55, dt_h = 0.25, p_pac_kw = 20)

  result <- kpi$compute(td$sim, td$baseline, params)

  expected_keys <- c(
    # Energy
    "pv_total", "ac_baseline", "ac_opti", "as_baseline", "as_opti",
    "soutirage_baseline", "soutirage_opti", "injection_baseline", "injection_opti",
    "conso_pac_baseline", "conso_pac_opti",
    # Financial
    "facture_baseline", "facture_opti", "gain_eur", "gain_pct",
    "cout_soutirage_baseline", "cout_soutirage_opti",
    "rev_injection_baseline", "rev_injection_opti",
    "gain_eur_per_day", "gain_eur_per_year",
    # Comfort
    "conformite_baseline", "conformite_opti",
    # Period
    "n_days"
  )
  for (key in expected_keys) {
    expect_true(key %in% names(result), info = paste("Missing KPI:", key))
  }

  # Gain should be positive (opti < baseline bill)
  expect_gt(result$gain_eur, 0)

  # Financial decomposition should be consistent
  expect_equal(
    result$facture_baseline,
    result$cout_soutirage_baseline - result$rev_injection_baseline,
    tolerance = 0.01
  )
  expect_equal(
    result$facture_opti,
    result$cout_soutirage_opti - result$rev_injection_opti,
    tolerance = 0.01
  )
})
