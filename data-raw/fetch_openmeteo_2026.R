#!/usr/bin/env Rscript
# =============================================================================
# Fetch Open-Meteo temperature data for 2026 and rebuild .rda files
# Usage: Rscript data-raw/fetch_openmeteo_2026.R
# =============================================================================

library(httr)
library(tibble)
library(readr)

cat("=== Fetching Open-Meteo temperature 2026 ===\n")

end_date <- Sys.Date() - 5
start_date <- as.Date("2026-01-01")

if (start_date > end_date) {
  stop("2026 data not yet available (archive has ~5 day lag)")
}

cat(sprintf("  Period: %s to %s\n", start_date, end_date))

resp <- GET(
  "https://archive-api.open-meteo.com/v1/archive",
  query = list(
    latitude = 50.38,
    longitude = 4.86,
    start_date = format(start_date, "%Y-%m-%d"),
    end_date = format(end_date, "%Y-%m-%d"),
    hourly = "temperature_2m",
    timezone = "Europe/Brussels"
  ),
  timeout(60)
)

if (status_code(resp) != 200) {
  stop(sprintf("HTTP error %d", status_code(resp)))
}

data <- content(resp, as = "parsed", simplifyVector = TRUE)

if (is.null(data$hourly)) {
  stop("No hourly data in response")
}

df <- tibble(
  timestamp = as.POSIXct(data$hourly$time, format = "%Y-%m-%dT%H:%M", tz = "Europe/Brussels"),
  t_ext = as.numeric(data$hourly$temperature_2m)
)
df <- df[!is.na(df$timestamp) & !is.na(df$t_ext), ]

cat(sprintf("  -> %d hourly records\n", nrow(df)))

out_file <- "data/openmeteo_temperature_2026.csv"
write_csv(df, out_file)
cat(sprintf("  -> Saved to %s\n", out_file))

# Rebuild all .rda files
cat("\n=== Rebuilding .rda files ===\n")
source("data-raw/build_rda.R")
