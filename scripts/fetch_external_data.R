#!/usr/bin/env Rscript
# =============================================================================
# Fetch external data (ENTSO-E prices, Elia solar, CO2, Open-Meteo)
# up to today, save as CSV + rebuild .rda
# =============================================================================
# Usage:
#   Rscript scripts/fetch_external_data.R
#   Rscript scripts/fetch_external_data.R --year 2026
#   Rscript scripts/fetch_external_data.R --from 2026-01-01 --to 2026-06-04
#
# Requires: ENTSOE_API_KEY in .env or environment
# =============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(lubridate)
  library(httr)
})

# Load .env if present
if (file.exists(".env")) {
  env_lines <- readLines(".env", warn = FALSE)
  env_lines <- env_lines[grepl("=", env_lines) & !grepl("^\\s*#", env_lines)]
  env_lines <- env_lines[nchar(trimws(env_lines)) > 0]
  for (line in env_lines) {
    eq_pos <- regexpr("=", line, fixed = TRUE)
    if (eq_pos < 1) next
    key <- trimws(substr(line, 1, eq_pos - 1))
    val <- trimws(substr(line, eq_pos + 1, nchar(line)))
    val <- gsub("^['\"]|['\"]$", "", val)
    if (nchar(key) > 0) do.call(Sys.setenv, setNames(list(val), key))
  }
}

# Load app functions (without Shiny)
devtools::load_all(".", quiet = TRUE)

data_dir <- "data"

# ---- Parse arguments ----
args <- commandArgs(trailingOnly = TRUE)
year <- as.integer(format(Sys.Date(), "%Y"))
from_date <- NULL
to_date <- NULL

i <- 1
while (i <= length(args)) {
  switch(args[i],
    "--year" = { year <- as.integer(args[i + 1]); i <- i + 1 },
    "--from" = { from_date <- as.Date(args[i + 1]); i <- i + 1 },
    "--to"   = { to_date <- as.Date(args[i + 1]); i <- i + 1 },
    message(sprintf("Unknown argument: %s", args[i]))
  )
  i <- i + 1
}

if (is.null(from_date)) from_date <- as.Date(sprintf("%d-01-01", year))
if (is.null(to_date)) to_date <- Sys.Date()

cat(sprintf("=== Fetching external data: %s -> %s ===\n\n", from_date, to_date))

api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
if (nchar(api_key) == 0) {
  cat("WARNING: ENTSOE_API_KEY not set. Prices will not be fetched.\n")
  cat("Set it in .env or export ENTSOE_API_KEY=...\n\n")
}

# =============================================================================
# 1. ENTSO-E Day-Ahead Prices
# =============================================================================
if (nchar(api_key) > 0) {
  cat("[1/4] Fetching ENTSO-E prices...\n")
  prices <- tryCatch({
    fetch_entsoe_chunked(api_key, as.POSIXct(from_date), as.POSIXct(to_date + 1))
  }, error = function(e) {
    message(sprintf("  Error: %s", e$message))
    NULL
  })

  if (!is.null(prices) && nrow(prices) > 0) {
    # Split by year and save/append CSV
    prices$year <- year(prices$datetime)
    for (yr in unique(prices$year)) {
      csv_path <- file.path(data_dir, sprintf("entsoe_prices_%d.csv", yr))
      yr_data <- prices %>% filter(year == yr) %>% select(-year)

      # Merge with existing CSV if present
      if (file.exists(csv_path)) {
        existing <- read_csv(csv_path, show_col_types = FALSE,
          col_types = cols(datetime = col_character()))
        existing$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "",
          existing$datetime)), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
        yr_data <- bind_rows(existing, yr_data) %>%
          distinct(datetime, .keep_all = TRUE) %>%
          arrange(datetime)
      }

      yr_data$datetime <- format(yr_data$datetime, "%Y-%m-%dT%H:%M:%SZ")
      write_csv(yr_data, csv_path)
      cat(sprintf("  %s: %d records\n", csv_path, nrow(yr_data)))
    }
  } else {
    cat("  No price data fetched.\n")
  }
} else {
  cat("[1/4] Skipping ENTSO-E (no API key)\n")
}

# =============================================================================
# 2. Elia Solar PV (ODS032)
# =============================================================================
cat("\n[2/4] Fetching Elia solar...\n")
solar <- tryCatch({
  fetch_solar_elia(as.POSIXct(from_date), as.POSIXct(to_date + 1), region = "Namur")
}, error = function(e) {
  message(sprintf("  Error: %s", e$message))
  NULL
})

if (!is.null(solar) && nrow(solar) > 0) {
  solar$year <- year(solar$datetime)
  for (yr in unique(solar$year)) {
    csv_path <- file.path(data_dir, sprintf("elia_solar_%d.csv", yr))
    yr_data <- solar %>% filter(year == yr) %>% select(-year)

    if (file.exists(csv_path)) {
      existing <- read_csv(csv_path, show_col_types = FALSE,
        col_types = cols(datetime = col_character()))
      existing$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "",
        existing$datetime)), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
      yr_data <- bind_rows(existing, yr_data) %>%
        distinct(datetime, .keep_all = TRUE) %>%
        arrange(datetime)
    }

    yr_data$datetime <- format(yr_data$datetime, "%Y-%m-%dT%H:%M:%SZ")
    write_csv(yr_data, csv_path)
    cat(sprintf("  %s: %d records\n", csv_path, nrow(yr_data)))
  }
} else {
  cat("  No solar data fetched.\n")
}

# =============================================================================
# 3. Elia CO2 intensity
# =============================================================================
cat("\n[3/4] Fetching Elia CO2...\n")
co2 <- tryCatch({
  result <- fetch_co2_intensity(from_date, to_date)
  result$df
}, error = function(e) {
  message(sprintf("  Error: %s", e$message))
  NULL
})

if (!is.null(co2) && nrow(co2) > 0) {
  co2$year <- year(co2$datetime)
  for (yr in unique(co2$year)) {
    csv_path <- file.path(data_dir, sprintf("elia_co2_%d.csv", yr))
    yr_data <- co2 %>% filter(year == yr) %>% select(-year)

    if (file.exists(csv_path)) {
      existing <- read_csv(csv_path, show_col_types = FALSE,
        col_types = cols(datetime = col_character()))
      existing$datetime <- as.POSIXct(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "",
        existing$datetime)), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
      yr_data <- bind_rows(existing, yr_data) %>%
        distinct(datetime, .keep_all = TRUE) %>%
        arrange(datetime)
    }

    yr_data$datetime <- format(yr_data$datetime, "%Y-%m-%dT%H:%M:%SZ")
    write_csv(yr_data, csv_path)
    cat(sprintf("  %s: %d records\n", csv_path, nrow(yr_data)))
  }
} else {
  cat("  No CO2 data fetched.\n")
}

# =============================================================================
# 4. Open-Meteo temperature (Profondeville: 50.37N, 4.87E)
# =============================================================================
cat("\n[4/4] Fetching Open-Meteo temperature...\n")
meteo <- tryCatch({
  lat <- 50.37; lon <- 4.87
  url <- sprintf(
    "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&hourly=temperature_2m&start_date=%s&end_date=%s&timezone=Europe%%2FBrussels",
    lat, lon, from_date, to_date)
  resp <- httr::GET(url, httr::timeout(30))
  if (httr::status_code(resp) == 200) {
    json <- httr::content(resp, as = "parsed")
    tibble(
      timestamp = as.POSIXct(unlist(json$hourly$time), tz = "Europe/Brussels"),
      t_ext = as.numeric(unlist(json$hourly$temperature_2m))
    )
  }
}, error = function(e) {
  message(sprintf("  Error: %s", e$message))
  NULL
})

if (!is.null(meteo) && nrow(meteo) > 0) {
  meteo$year <- year(meteo$timestamp)
  for (yr in unique(meteo$year)) {
    csv_path <- file.path(data_dir, sprintf("openmeteo_temperature_%d.csv", yr))
    yr_data <- meteo %>% filter(year == yr) %>% select(-year)

    if (file.exists(csv_path)) {
      existing <- read_csv(csv_path, show_col_types = FALSE)
      existing$timestamp <- as.POSIXct(existing$timestamp, tz = "Europe/Brussels")
      yr_data <- bind_rows(existing, yr_data) %>%
        distinct(timestamp, .keep_all = TRUE) %>%
        arrange(timestamp)
    }

    write_csv(yr_data, csv_path)
    cat(sprintf("  %s: %d records\n", csv_path, nrow(yr_data)))
  }
} else {
  cat("  No temperature data fetched.\n")
}

# =============================================================================
# 5. Rebuild .rda from all CSV files
# =============================================================================
cat("\n[5/5] Rebuilding .rda files...\n")
source("data-raw/build_rda.R")

cat("\n=== All done. ===\n")
