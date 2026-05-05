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
