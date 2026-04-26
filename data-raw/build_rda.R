#!/usr/bin/env Rscript
# =============================================================================
# Build .rda package data objects from CSV files
#
# Reads all data/*.csv files and creates consolidated R data objects
# saved as data/*.rda for instant lazy-loading by the package.
# The CSV files are kept for traceability.
#
# Usage: Rscript data-raw/build_rda.R
# =============================================================================

library(readr)
library(dplyr)
library(lubridate)

data_dir <- "data"

# ---------------------------------------------------------------------------
# 1. ENTSO-E prices
# ---------------------------------------------------------------------------
cat("=== ENTSO-E prices ===\n")
files <- sort(list.files(data_dir, pattern = "^entsoe_prices_\\d{4}\\.csv$", full.names = TRUE))
entsoe_prices <- bind_rows(lapply(files, function(f) {
  cat(sprintf("  Reading %s\n", f))
  df <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
  df$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", df$datetime)),
    format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  df
}))
entsoe_prices <- distinct(entsoe_prices, datetime, .keep_all = TRUE)
entsoe_prices <- arrange(entsoe_prices, datetime)
cat(sprintf("  -> %d records (%s to %s)\n", nrow(entsoe_prices),
  min(entsoe_prices$datetime), max(entsoe_prices$datetime)))

# ---------------------------------------------------------------------------
# 2. Elia CO2 intensity
# ---------------------------------------------------------------------------
cat("\n=== Elia CO2 ===\n")
files <- sort(list.files(data_dir, pattern = "^elia_co2_\\d{4}\\.csv$", full.names = TRUE))
elia_co2 <- bind_rows(lapply(files, function(f) {
  cat(sprintf("  Reading %s\n", f))
  df <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
  df$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", df$datetime)),
    format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  df
}))
elia_co2 <- distinct(elia_co2, datetime, .keep_all = TRUE)
elia_co2 <- arrange(elia_co2, datetime)
cat(sprintf("  -> %d records (%s to %s)\n", nrow(elia_co2),
  min(elia_co2$datetime), max(elia_co2$datetime)))

# ---------------------------------------------------------------------------
# 3. Open-Meteo temperature
# ---------------------------------------------------------------------------
cat("\n=== Open-Meteo temperature ===\n")
files <- sort(list.files(data_dir, pattern = "^openmeteo_temperature_\\d{4}\\.csv$", full.names = TRUE))
openmeteo_temperature <- bind_rows(lapply(files, function(f) {
  cat(sprintf("  Reading %s\n", f))
  df <- read_csv(f, show_col_types = FALSE)
  df$timestamp <- as.POSIXct(df$timestamp, tz = "Europe/Brussels")
  df
}))
openmeteo_temperature <- distinct(openmeteo_temperature, timestamp, .keep_all = TRUE)
openmeteo_temperature <- arrange(openmeteo_temperature, timestamp)
cat(sprintf("  -> %d records (%s to %s)\n", nrow(openmeteo_temperature),
  min(openmeteo_temperature$timestamp), max(openmeteo_temperature$timestamp)))

# ---------------------------------------------------------------------------
# 4. Elia solar PV
# ---------------------------------------------------------------------------
cat("\n=== Elia solar ===\n")
files <- sort(list.files(data_dir, pattern = "^elia_solar_\\d{4}\\.csv$", full.names = TRUE))
elia_solar <- bind_rows(lapply(files, function(f) {
  cat(sprintf("  Reading %s\n", f))
  df <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
  df$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", df$datetime)),
    format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  df
}))
elia_solar <- distinct(elia_solar, datetime, .keep_all = TRUE)
elia_solar <- arrange(elia_solar, datetime)
cat(sprintf("  -> %d records (%s to %s)\n", nrow(elia_solar),
  min(elia_solar$datetime), max(elia_solar$datetime)))

# ---------------------------------------------------------------------------
# Save as .rda (compressed)
# ---------------------------------------------------------------------------
cat("\n=== Saving .rda files ===\n")
usethis::use_data(entsoe_prices, elia_co2, openmeteo_temperature, elia_solar,
  overwrite = TRUE, compress = "xz")

cat("\nDone.\n")
