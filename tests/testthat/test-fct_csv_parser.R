# Tests: fct_csv_parser (006-dual-csv-import)

test_that("detect_timestep identifies 5-min data", {
  ts <- seq(as.POSIXct("2025-01-01 00:00:00", tz = "UTC"), by = "5 min", length.out = 20)
  expect_equal(detect_timestep(ts), "5min")
})

test_that("detect_timestep identifies 15-min data", {
  ts <- seq(as.POSIXct("2025-01-01 00:00:00", tz = "UTC"), by = "15 min", length.out = 20)
  expect_equal(detect_timestep(ts), "15min")
})

test_that("detect_timestep identifies 60-min data", {
  ts <- seq(as.POSIXct("2025-01-01 00:00:00", tz = "UTC"), by = "60 min", length.out = 20)
  expect_equal(detect_timestep(ts), "60min")
})

test_that("detect_timestep returns irregular for random timestamps", {
  # Diffs of 7, 13, 42, 3, 91, 120, 5, 8, 200 seconds — no standard step
  ts <- as.POSIXct("2025-01-01", tz = "UTC") + cumsum(c(0, 7, 13, 42, 3, 91, 120, 5, 8, 200))
  expect_equal(detect_timestep(ts), "irregular")
})

test_that("parse_installation_csv works with Profondeville raw data", {
  skip_if_not(file.exists(file.path(project_root, "inst/extdata/bq_k0001_raw.csv")))
  result <- parse_installation_csv(file.path(project_root, "inst/extdata/bq_k0001_raw.csv"))

  expect_type(result, "list")
  expect_true("df" %in% names(result))
  expect_true("timestamp" %in% names(result$df))
  expect_true("elec_kwh" %in% names(result$df))
  expect_equal(result$timestep, "5min")
  # Aggregated to 15 min: should have ~13000 rows (46000 raw / 3)
  expect_gt(nrow(result$df), 10000)
  expect_lt(nrow(result$df), 20000)
  # All elec_kwh should be non-negative (sum of positive values)
  expect_true(all(result$df$elec_kwh >= 0, na.rm = TRUE))
})

test_that("parse_ores_csv works with Profondeville raw data", {
  skip_if_not(file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv")))
  result <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))

  expect_type(result, "list")
  expect_true("df" %in% names(result))
  expect_true("offtake_kwh" %in% names(result$df))
  expect_true("feedin_kwh" %in% names(result$df))
  # Deltas should be non-negative (pmax applied)
  expect_true(all(result$df$offtake_kwh >= 0, na.rm = TRUE))
  expect_true(all(result$df$feedin_kwh >= 0, na.rm = TRUE))
})

test_that("join_sources produces expected result", {
  skip_if_not(
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_raw.csv")) &&
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  )
  install <- parse_installation_csv(file.path(project_root, "inst/extdata/bq_k0001_raw.csv"))
  ores <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  result <- join_sources(install$df, ores$df)

  expect_type(result, "list")
  expect_gt(result$n_points, 10000)
  # Joined df should have both installation and ORES columns
  expect_true("elec_kwh" %in% names(result$df))
  expect_true("offtake_kwh" %in% names(result$df))
  expect_true("feedin_kwh" %in% names(result$df))
})

test_that("filter_outliers_iqr replaces extreme values", {
  x <- c(rep(1, 100), 500, rep(1.5, 100), 800)
  result <- filter_outliers_iqr(x, k = 3)
  expect_equal(result$n_replaced, 2)
  # Outliers should be replaced with local median (close to 1-1.5)
  expect_lt(result$filtered[101], 10)
  expect_lt(result$filtered[202], 10)
})

test_that("filter_outliers_iqr does not touch normal data", {
  x <- rnorm(100, mean = 5, sd = 1)
  result <- filter_outliers_iqr(x, k = 3)
  # With k=3, very few points should be flagged in normal data
  expect_lt(result$n_replaced, 3)
})

test_that("parse_ores_csv with outlier_filter removes spikes", {
  skip_if_not(file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv")))

  # Without filter
  no_filt <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"),
    outlier_filter = FALSE)
  # With filter
  with_filt <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"),
    outlier_filter = TRUE)

  # Max should be lower with filter (the 1374 kWh spike is gone)
  expect_lt(max(with_filt$df$offtake_kwh, na.rm = TRUE),
    max(no_filt$df$offtake_kwh, na.rm = TRUE))
  # Same number of rows
  expect_equal(nrow(with_filt$df), nrow(no_filt$df))
})
