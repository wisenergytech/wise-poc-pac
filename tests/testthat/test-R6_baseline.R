# =============================================================================
# Tests: R6_baseline (T017)
# =============================================================================

# Helper to create a small test dataset (1 day = 96 quarter-hours)
make_test_df <- function(n = 96) {
  ts <- seq(
    as.POSIXct("2025-06-15 00:00:00", tz = "Europe/Brussels"),
    by = "15 min", length.out = n
  )
  h <- lubridate::hour(ts) + lubridate::minute(ts) / 60

  tibble::tibble(
    timestamp = ts,
    pv_kwh = pmax(0, sin(pi * (h - 6) / 14)) * 2 * 0.25,
    t_ext = 15 + 5 * sin(pi * (h - 6) / 18),
    conso_hors_pac = 0.3 * 0.25,
    soutirage_estime_kwh = ifelse(h > 7 & h < 8, 2.0, 0.1),
    prix_offtake = 0.20,
    prix_injection = 0.05
  )
}

make_test_params <- function() {
  list(
    t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
    p_pac_kw = 2, cop_nominal = 3.5, t_ref_cop = 7,
    volume_ballon_l = 200, capacite_kwh_par_degre = 200 * 0.001163,
    dt_h = 0.25, perte_kwh_par_qt = 0.05
  )
}

test_that("Thermostat mode produces valid results", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  result <- bl$run(df, params, mode = "thermostat")

  expect_true("t_ballon" %in% names(result))
  expect_true("offtake_kwh" %in% names(result))
  expect_true("intake_kwh" %in% names(result))
  expect_equal(nrow(result), nrow(df))
})

test_that("PV tracking mode produces valid results", {
  df <- make_test_df()
  params <- make_test_params()
  params$baseline_alpha <- 0.7
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  result <- bl$run(df, params, mode = "pv_tracking")

  expect_true("t_ballon" %in% names(result))
  expect_true("offtake_kwh" %in% names(result))
  expect_true("intake_kwh" %in% names(result))
  expect_equal(nrow(result), nrow(df))
})

test_that("PV tracking has better autoconsommation than thermostat", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl_thermo <- Baseline$new(tm)
  r_thermo <- bl_thermo$run(df, params, mode = "thermostat")

  params$baseline_alpha <- 0.8
  bl_pv <- Baseline$new(tm)
  r_pv <- bl_pv$run(df, params, mode = "pv_tracking")

  pv_tot <- sum(df$pv_kwh)
  ac_thermo <- 1 - sum(r_thermo$intake_kwh) / max(pv_tot, 1)
  ac_pv <- 1 - sum(r_pv$intake_kwh) / max(pv_tot, 1)

  expect_gte(ac_pv, ac_thermo)
})

test_that("Thermostat is the default mode", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl_default <- Baseline$new(tm)
  r_default <- bl_default$run(df, params)

  bl_thermo <- Baseline$new(tm)
  r_thermo <- bl_thermo$run(df, params, mode = "thermostat")

  expect_equal(r_default$t_ballon, r_thermo$t_ballon)
})

test_that("Baseline respects temperature bounds", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  for (mode in c("thermostat", "pv_tracking")) {
    if (mode == "pv_tracking") params$baseline_alpha <- 0.5
    bl <- Baseline$new(tm)
    result <- bl$run(df, params, mode = mode)

    expect_true(all(result$t_ballon >= max(20, params$t_min - 10)),
      info = paste("Mode:", mode))
    expect_true(all(result$t_ballon <= params$t_max + 5),
      info = paste("Mode:", mode))
  }
})

test_that("Legacy mode names are mapped correctly", {
  df <- make_test_df()
  params <- make_test_params()
  params$baseline_alpha <- 0.5
  tm <- ThermalModel$new(params)

  # Legacy "reactif" should map to thermostat
  bl1 <- Baseline$new(tm)
  r_legacy <- bl1$run(df, params, mode = "reactif")

  bl2 <- Baseline$new(tm)
  r_thermo <- bl2$run(df, params, mode = "thermostat")

  expect_equal(r_legacy$t_ballon, r_thermo$t_ballon)

  # Legacy "parametric" should map to pv_tracking
  bl3 <- Baseline$new(tm)
  r_parametric <- bl3$run(df, params, mode = "parametric")

  bl4 <- Baseline$new(tm)
  r_pv <- bl4$run(df, params, mode = "pv_tracking")

  expect_equal(r_parametric$t_ballon, r_pv$t_ballon)
})

test_that("Baseline get_result returns the last run", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  expect_null(bl$get_result())

  result <- bl$run(df, params)
  expect_identical(bl$get_result(), result)
})

test_that("Thermostat hysteresis works correctly", {
  # Create data where PAC needs to cycle
  df <- make_test_df(n = 20)
  params <- make_test_params()
  params$p_pac_kw <- 5  # strong PAC to see clear cycling
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  result <- bl$run(df, params, mode = "thermostat")

  # T should never stay permanently below t_min (PAC turns on)
  below_min <- result$t_ballon < params$t_min
  if (any(below_min)) {
    # After being below t_min, temperature should recover
    first_below <- which(below_min)[1]
    remaining <- result$t_ballon[(first_below + 1):nrow(result)]
    expect_true(any(remaining >= params$t_min),
      info = "PAC should recover temperature above t_min")
  }
})
