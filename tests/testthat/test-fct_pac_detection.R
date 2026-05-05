# Tests: fct_pac_detection (006-dual-csv-import)

test_that("detect_pac_consumption uses COP heuristic on Profondeville data", {
  skip_if_not(
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_raw.csv")) &&
    file.exists(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  )
  install <- parse_installation_csv(file.path(project_root, "inst/extdata/bq_k0001_raw.csv"))
  ores <- parse_ores_csv(file.path(project_root, "inst/extdata/bq_k0001_ores_raw.csv"))
  joined <- join_sources(install$df, ores$df)

  result <- detect_pac_consumption(joined$df)

  expect_equal(result$method, "heuristique COP")
  expect_true(result$p95_kw > 10 && result$p95_kw < 16)
  expect_true(result$talon_w > 500 && result$talon_w < 4000)
  expect_equal(length(result$pac_kwh), nrow(joined$df))
})

test_that("detect_pac_consumption falls back when no COP", {
  df <- data.frame(
    elec_kwh = runif(100, 0.5, 2),
    offtake_kwh = runif(100, 0.3, 1.5),
    feedin_kwh = runif(100, 0, 0.5)
  )
  result <- detect_pac_consumption(df)
  expect_equal(result$method, "fallback (total installation, s\u00e9paration impossible)")
  expect_true(is.na(result$p95_kw))
})

test_that("detect_pac_consumption uses GSHP/ASHP when non-zero", {
  df <- data.frame(
    elec_kwh = rep(3, 50),
    cop = c(rep(0, 10), rep(3, 40)),
    gshp_kw = c(rep(0, 10), rep(8, 40)),
    ashp_kw = rep(0, 50)
  )
  result <- detect_pac_consumption(df)
  expect_equal(result$method, "sous-compteur (GSHP + ASHP)")
  expect_true(!is.na(result$p95_kw))
})
