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

test_that("Baseline produces results for all 5 modes", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  modes <- c("reactif", "programmateur", "surplus_pv", "ingenieur", "proactif")
  results <- list()

  for (mode in modes) {
    bl <- Baseline$new(tm)
    result <- bl$run(df, params, mode = mode)
    expect_true("t_ballon" %in% names(result), info = paste("Mode:", mode))
    expect_true("offtake_kwh" %in% names(result), info = paste("Mode:", mode))
    expect_true("intake_kwh" %in% names(result), info = paste("Mode:", mode))
    expect_equal(nrow(result), nrow(df), info = paste("Mode:", mode))
    results[[mode]] <- result
  }

  # Different modes should produce different bills
  bills <- sapply(results, function(r) {
    sum(r$offtake_kwh * r$prix_offtake - r$intake_kwh * r$prix_injection)
  })
  # Not all modes should produce the exact same bill
  expect_gt(length(unique(round(bills, 2))), 1)
})

test_that("Ingenieur mode has better autoconsommation than reactif", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl_react <- Baseline$new(tm)
  r_react <- bl_react$run(df, params, mode = "reactif")


  bl_ing <- Baseline$new(tm)
  r_ing <- bl_ing$run(df, params, mode = "ingenieur")

  # Autoconsommation = 1 - injection / PV_total
  pv_tot <- sum(df$pv_kwh)
  ac_react <- 1 - sum(r_react$intake_kwh) / max(pv_tot, 1)
  ac_ing <- 1 - sum(r_ing$intake_kwh) / max(pv_tot, 1)

  # Ingenieur should match surplus better than pure thermostat
  expect_gte(ac_ing, ac_react)
})

test_that("Baseline respects temperature bounds", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  result <- bl$run(df, params, mode = "ingenieur")

  # Temperature should stay within physical bounds
  # (t_min - 10 to t_max + 5 as per clamping logic)
  expect_true(all(result$t_ballon >= max(20, params$t_min - 10)))
  expect_true(all(result$t_ballon <= params$t_max + 5))
})

test_that("Baseline get_result returns the last run", {
  df <- make_test_df()
  params <- make_test_params()
  tm <- ThermalModel$new(params)

  bl <- Baseline$new(tm)
  expect_null(bl$get_result())

  result <- bl$run(df, params, mode = "reactif")
  expect_identical(bl$get_result(), result)
})
