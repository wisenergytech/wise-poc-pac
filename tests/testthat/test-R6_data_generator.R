# =============================================================================
# Tests: DataGenerator$load_delaunoy()
# =============================================================================

test_that("load_delaunoy scales correctly for 10 kWc", {
  gen <- DataGenerator$new()
  file_path <- file.path(project_root, "..", "delaunoy", "data", "inverters_data_delaunoy.xlsx")
  skip_if_not(file.exists(file_path), "Delaunoy data file not available")

  # Load at reference capacity (16 kWc) to get raw values
  df_ref <- gen$load_delaunoy(file_path, target_kwc = 16, ref_kwc = 16)
  # Load at 10 kWc

  df_10 <- gen$load_delaunoy(file_path, target_kwc = 10, ref_kwc = 16)

  expect_s3_class(df_10, "tbl_df")
  expect_named(df_10, c("timestamp", "pv_kwh"))
  expect_true(nrow(df_10) > 20000)

  # Check scaling: 10/16 = 0.625
  non_zero <- df_ref$pv_kwh > 0
  expect_equal(df_10$pv_kwh[non_zero], df_ref$pv_kwh[non_zero] * 0.625, tolerance = 1e-6)
})

test_that("load_delaunoy returns all zeros when target_kwc is 0", {
  gen <- DataGenerator$new()
  file_path <- file.path(project_root, "..", "delaunoy", "data", "inverters_data_delaunoy.xlsx")
  skip_if_not(file.exists(file_path), "Delaunoy data file not available")

  df <- gen$load_delaunoy(file_path, target_kwc = 0)

  expect_s3_class(df, "tbl_df")
  expect_true(all(df$pv_kwh == 0))
})

test_that("load_delaunoy returns NULL for missing file", {
  gen <- DataGenerator$new()

  expect_warning(
    result <- gen$load_delaunoy("/nonexistent/path.xlsx", target_kwc = 10),
    "introuvable"
  )
  expect_null(result)
})

test_that("load_delaunoy output has correct structure", {
  gen <- DataGenerator$new()
  file_path <- file.path(project_root, "..", "delaunoy", "data", "inverters_data_delaunoy.xlsx")
  skip_if_not(file.exists(file_path), "Delaunoy data file not available")

  df <- gen$load_delaunoy(file_path, target_kwc = 16)

  expect_s3_class(df, "tbl_df")
  expect_named(df, c("timestamp", "pv_kwh"))
  expect_s3_class(df$timestamp, "POSIXct")
  expect_type(df$pv_kwh, "double")
  expect_true(all(df$pv_kwh >= 0))
})
