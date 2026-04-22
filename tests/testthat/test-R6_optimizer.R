# =============================================================================
# Tests: R6_optimizer (T018)
# =============================================================================

# Helper: create a prepared 1-day dataset with baseline already run
make_optimizer_test_data <- function() {
  n <- 96  # 1 day
  ts <- seq(
    as.POSIXct("2025-06-15 00:00:00", tz = "Europe/Brussels"),
    by = "15 min", length.out = n
  )
  h <- lubridate::hour(ts) + lubridate::minute(ts) / 60

  params <- list(
    t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
    p_pac_kw = 2, cop_nominal = 3.5, t_ref_cop = 7,
    volume_ballon_l = 200, capacite_kwh_par_degre = 200 * 0.001163,
    dt_h = 0.25, perte_kwh_par_qt = 0.05,
    batterie_active = FALSE, batt_kwh = 0, batt_kw = 0,
    batt_rendement = 0.9, batt_soc_min = 0.1, batt_soc_max = 0.9,
    optim_bloc_h = 24, slack_penalty = 2.5,
    curtailment_active = FALSE, curtail_kwh_per_qt = Inf
  )

  df <- tibble::tibble(
    timestamp = ts,
    pv_kwh = pmax(0, sin(pi * (h - 6) / 14)) * 2 * 0.25,
    t_ext = 15 + 5 * sin(pi * (h - 6) / 18),
    conso_hors_pac = 0.3 * 0.25,
    soutirage_estime_kwh = ifelse(h > 7 & h < 8, 1.5, 0.05),
    prix_offtake = 0.20 + 0.05 * sin(pi * (h - 8) / 12),
    prix_injection = 0.05 + 0.02 * sin(pi * (h - 8) / 12)
  )

  # Run baseline first (optimizer needs baseline columns)
  tm <- ThermalModel$new(params)
  bl <- Baseline$new(tm)
  df_bl <- bl$run(df, params, mode = "ingenieur")

  list(df = df_bl, params = params)
}

test_that("LPOptimizer solves a 1-day dataset without error", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")

  td <- make_optimizer_test_data()
  opt <- LPOptimizer$new(td$params, td$df)
  result <- opt$solve()

  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 96)

  # Expected columns from optimization
  expected_cols <- c("sim_t_ballon", "sim_pac_on", "sim_offtake",
                     "sim_intake", "sim_cop", "decision_raison",
                     "batt_soc", "batt_flux", "mode_actif")
  for (col in expected_cols) {
    expect_true(col %in% names(result), info = paste("Missing column:", col))
  }
})

test_that("LPOptimizer respects temperature bounds", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")

  td <- make_optimizer_test_data()
  opt <- LPOptimizer$new(td$params, td$df)
  result <- opt$solve()

  # Temperature within bounds (with some solver tolerance)
  expect_true(all(result$sim_t_ballon >= td$params$t_min - 1, na.rm = TRUE))
  expect_true(all(result$sim_t_ballon <= td$params$t_max + 5, na.rm = TRUE))
})

test_that("LPOptimizer produces non-negative offtake and intake", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")

  td <- make_optimizer_test_data()
  opt <- LPOptimizer$new(td$params, td$df)
  result <- opt$solve()

  expect_true(all(result$sim_offtake >= -0.001, na.rm = TRUE))
  expect_true(all(result$sim_intake >= -0.001, na.rm = TRUE))
})

test_that("LPOptimizer pac_load is between 0 and 1", {
  skip_if_not_installed("ompr")
  skip_if_not_installed("ROI.plugin.glpk")

  td <- make_optimizer_test_data()
  opt <- LPOptimizer$new(td$params, td$df)
  result <- opt$solve()

  expect_true(all(result$sim_pac_on >= -0.001, na.rm = TRUE))
  expect_true(all(result$sim_pac_on <= 1.001, na.rm = TRUE))
})

test_that("SmartOptimizer solves without error", {
  td <- make_optimizer_test_data()
  # Smart mode needs these extra params
  td$params$horizon_qt <- 16
  td$params$poids_cout <- 0.5

  opt <- SmartOptimizer$new(td$params, td$df)
  result <- opt$solve()

  expect_s3_class(result, "tbl_df")
  expect_equal(nrow(result), 96)
  expect_true("sim_t_ballon" %in% names(result))
  expect_true("decision_raison" %in% names(result))
})
