# Tests: fct_pv_reconstruction (006-dual-csv-import)

test_that("reconstruct_pv returns non-negative values", {
  df <- data.frame(
    elec_kwh = c(1, 2, 3, 0.5),
    offtake_kwh = c(0.5, 1, 2, 1),
    feedin_kwh = c(0, 0.5, 1, 0)
  )
  pv <- reconstruct_pv(df)
  expect_true(all(pv >= 0))
  # pv = elec - offtake + feedin, clamped to 0
  expect_equal(pv[1], 0.5)  # 1 - 0.5 + 0 = 0.5
  expect_equal(pv[4], 0)    # 0.5 - 1 + 0 = -0.5 → 0
})

test_that("reconstruct_pv gives ~0 at night on Profondeville data", {
  skip_if_not(
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_raw.csv")) &&
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  )
  install <- parse_installation_csv(file.path(project_root, "inst/extdata/bq_k0001_raw.csv"))
  ores <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  joined <- join_sources(install$df, ores$df)
  df <- joined$df

  pv <- reconstruct_pv(df)
  hour <- as.integer(format(df$timestamp, "%H"))
  night_pv <- pv[hour >= 23 | hour <= 4]

  # 95% of nighttime values should be < 0.05 kWh
  pct_near_zero <- sum(night_pv < 0.05, na.rm = TRUE) / length(night_pv)
  expect_gt(pct_near_zero, 0.90)
})

test_that("assess_pv_stability detects instability on Profondeville", {
  skip_if_not(
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_raw.csv")) &&
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  )
  install <- parse_installation_csv(file.path(project_root, "inst/extdata/bq_k0001_raw.csv"))
  ores <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  joined <- join_sources(install$df, ores$df)
  df <- joined$df

  pv <- reconstruct_pv(df)
  result <- assess_pv_stability(pv, df$timestamp)

  # Profondeville has progressive commissioning → CV > 30%
  expect_false(result$stable)
  expect_gt(result$cv, 0.3)
})

test_that("compute_adaptive_kwc detects progressive commissioning", {
  # Simulate 4 months: kWc growing from 10 to 40
  timestamps <- seq(as.POSIXct("2025-12-01", tz = "UTC"),
    as.POSIXct("2026-04-01", tz = "UTC"), by = "15 min")
  months <- format(timestamps, "%Y-%m")

  # Elia 1-kWc profile: simple sinusoidal (same shape each month)
  hour <- as.integer(format(timestamps, "%H"))
  pv_elia_1kwc <- pmax(0, sin((hour - 6) / 12 * pi) * 0.25) # peak ~0.25 kWh/qt at noon

  # Real PV = Elia × growing kWc
  kwc_by_month <- c("2025-12" = 10, "2026-01" = 15, "2026-02" = 25, "2026-03" = 40)
  pv_reel <- pv_elia_1kwc * kwc_by_month[months]

  result <- compute_adaptive_kwc(pv_reel, timestamps, pv_elia_1kwc)

  expect_equal(nrow(result$monthly), 4)
  # kWc should approximately match our input
  expect_true(all(abs(result$monthly$kwc_equiv - c(10, 15, 25, 40)) < 1))
  # Current kWc = median of last 2 months (25, 40) → ~32.5
  expect_gt(result$kwc_current, 25)
  expect_lt(result$kwc_current, 45)
})

test_that("estimate_kwc_robust produces smooth curve on synthetic data", {
  # 120 days, kWc growing from 10 to 40
  n_days <- 120
  dates <- seq(as.Date("2025-12-01"), by = "day", length.out = n_days)
  timestamps <- rep(as.POSIXct(dates, tz = "UTC"), each = 96) +
    rep(seq(0, 95) * 900, times = n_days)
  hour <- as.integer(format(timestamps, "%H"))

  # Elia 1-kWc: solar bell curve
  elia_1kwc <- pmax(0, sin((hour - 6) / 12 * pi) * 0.20)
  elia_1kwc[hour < 7 | hour > 19] <- 0

  # Real PV = Elia × growing kWc + noise
  day_num <- as.integer(as.Date(timestamps) - as.Date("2025-12-01"))
  kwc_true <- 10 + day_num * 0.25  # 10 → 40 over 120 days
  set.seed(42)
  pv_reel <- elia_1kwc * kwc_true * (1 + rnorm(length(elia_1kwc), 0, 0.05))
  pv_reel <- pmax(0, pv_reel)

  result <- estimate_kwc_robust(pv_reel, timestamps, elia_1kwc)

  expect_true(!is.null(result$daily))
  expect_true(!is.na(result$kwc_current))
  # Final kWc should be close to 40
  expect_gt(result$kwc_current, 30)
  expect_lt(result$kwc_current, 50)
  # Should have clear-sky days
  expect_gt(sum(result$daily$is_clear), 20)
})

test_that("estimate_kwc_robust is resistant to outliers", {
  n_days <- 90
  dates <- seq(as.Date("2026-01-01"), by = "day", length.out = n_days)
  timestamps <- rep(as.POSIXct(dates, tz = "UTC"), each = 96) +
    rep(seq(0, 95) * 900, times = n_days)
  hour <- as.integer(format(timestamps, "%H"))

  elia_1kwc <- pmax(0, sin((hour - 6) / 12 * pi) * 0.20)
  elia_1kwc[hour < 7 | hour > 19] <- 0

  # Constant 30 kWc
  pv_reel <- elia_1kwc * 30
  # Inject 5 outlier days with 10x spike
  spike_days <- c(10, 30, 50, 70, 85)
  for (d in spike_days) {
    idx <- ((d - 1) * 96 + 1):(d * 96)
    pv_reel[idx] <- pv_reel[idx] * 10
  }

  result <- estimate_kwc_robust(pv_reel, timestamps, elia_1kwc)

  # kWc should still be close to 30 despite 5 outlier days
  expect_gt(result$kwc_current, 25)
  expect_lt(result$kwc_current, 35)
})

test_that("scale_pv_adaptive applies per-month kWc", {
  timestamps <- as.POSIXct(c("2026-01-15 12:00", "2026-02-15 12:00", "2026-03-15 12:00"), tz = "UTC")
  pv_elia_1kwc <- c(0.2, 0.25, 0.3)  # kWh per timestep for 1 kWc
  kwc_profile <- c("2026-01" = 10, "2026-02" = 20, "2026-03" = 30)

  result <- scale_pv_adaptive(timestamps, pv_elia_1kwc, kwc_profile)

  expect_equal(result, c(0.2 * 10, 0.25 * 20, 0.3 * 30))
})
