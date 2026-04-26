# =============================================================================
# Test helper: Source all R6 classes and dependencies
# =============================================================================
# This file is automatically loaded by testthat before running tests.
# It sources the R6 classes and their dependencies so tests can use them
# without requiring devtools::load_all() or golem.
# =============================================================================

library(dplyr)
library(lubridate)
library(R6)

# Project root (two levels up from tests/testthat/)
project_root <- normalizePath(file.path(dirname(getwd()), ".."))
if (!file.exists(file.path(project_root, "app.R"))) {
  # Fallback: try from the testthat working directory
  project_root <- normalizePath(file.path("..", ".."))
}

# Set working directory to project root so relative paths (e.g. "data/") resolve
setwd(project_root)

# Override DataProvider default to use absolute data_dir path
.test_data_dir <- file.path(project_root, "data")

# Load .env for API keys
env_file <- file.path(project_root, ".env")
if (file.exists(env_file)) {
  env_lines <- readLines(env_file, warn = FALSE)
  for (line in env_lines) {
    line <- trimws(line)
    if (nchar(line) == 0 || startsWith(line, "#")) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      val <- trimws(paste(parts[-1], collapse = "="))
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

# Source helpers and R6 classes in dependency order
source(file.path(project_root, "R", "fct_helpers.R"), local = FALSE)
source(file.path(project_root, "R", "data_entsoe_prices.R"), local = FALSE)
source(file.path(project_root, "R", "data_openmeteo_temperature.R"), local = FALSE)
source(file.path(project_root, "R", "optimizer_lp.R"), local = FALSE)
# optimizer_milp.R requires ROI.plugin.highs which may not be installed
tryCatch(
 source(file.path(project_root, "R", "optimizer_milp.R"), local = FALSE),
 error = function(e) message("[test helper] Skipping optimizer_milp.R: ", e$message)
)
source(file.path(project_root, "R", "optimizer_qp.R"), local = FALSE)
source(file.path(project_root, "R", "R6_data_provider.R"), local = FALSE)
source(file.path(project_root, "R", "R6_data_generator.R"), local = FALSE)
source(file.path(project_root, "R", "R6_thermal_model.R"), local = FALSE)
source(file.path(project_root, "R", "R6_baseline.R"), local = FALSE)
source(file.path(project_root, "R", "R6_optimizer.R"), local = FALSE)
source(file.path(project_root, "R", "R6_kpi.R"), local = FALSE)
source(file.path(project_root, "R", "R6_simulation.R"), local = FALSE)

# Utility: get project root for fixture paths
get_fixture_path <- function(filename) {
  file.path(project_root, "tests", "testthat", "fixtures", filename)
}
