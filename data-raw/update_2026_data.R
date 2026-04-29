#!/usr/bin/env Rscript
# =============================================================================
# Update entsoe_prices_2026.csv and openmeteo_temperature_2026.csv to today
# Usage: Rscript data-raw/update_2026_data.R
# =============================================================================

library(httr)
library(tibble)
library(readr)
library(dplyr)
library(lubridate)

# Load .env
if (file.exists(".env")) {
  env_lines <- readLines(".env", warn = FALSE)
  for (line in env_lines) {
    if (grepl("^[A-Za-z_]", line) && grepl("=", line)) {
      parts <- strsplit(line, "=", fixed = TRUE)[[1]]
      key <- parts[1]
      val <- paste(parts[-1], collapse = "=")
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

# =============================================================================
# 1. ENTSO-E prices
# =============================================================================
cat("=== Updating ENTSO-E prices 2026 ===\n")

entsoe_file <- "data/entsoe_prices_2026.csv"
existing_entsoe <- read_csv(entsoe_file, show_col_types = FALSE)
last_entsoe <- max(as.POSIXct(existing_entsoe$datetime, tz = "UTC"))
cat(sprintf("  Last existing: %s\n", format(last_entsoe, "%Y-%m-%d %H:%M")))

# Fetch from day after last data
fetch_start <- as.POSIXct(format(as.Date(last_entsoe) + 1, "%Y-%m-%d 00:00:00"), tz = "UTC")
fetch_end <- as.POSIXct(format(Sys.Date(), "%Y-%m-%d 00:00:00"), tz = "UTC")

api_key <- Sys.getenv("ENTSO-E_API_KEY")
if (nchar(api_key) == 0) stop("ENTSO-E_API_KEY not found in .env")

fmt_entsoe <- function(d) format(d, "%Y%m%d%H%M")
cat(sprintf("  Fetching: %s to %s\n", fmt_entsoe(fetch_start), fmt_entsoe(fetch_end)))

resp <- GET(
  "https://web-api.tp.entsoe.eu/api",
  query = list(
    securityToken = api_key,
    documentType = "A44",
    in_Domain = "10YBE----------2",
    out_Domain = "10YBE----------2",
    periodStart = fmt_entsoe(fetch_start),
    periodEnd = fmt_entsoe(fetch_end)
  ),
  timeout(60)
)
cat(sprintf("  API status: %d\n", status_code(resp)))

if (status_code(resp) != 200) {
  cat(sprintf("  HTTP error %d\n", status_code(resp)))
  cat("  Response: ", content(resp, as = "text", encoding = "UTF-8"), "\n")
} else {
  # Parse XML
  xml_text_raw <- content(resp, as = "text", encoding = "UTF-8")
  doc <- xml2::read_xml(xml_text_raw)
  ns <- xml2::xml_ns(doc)
  ns_prefix <- names(ns)[1]

  time_series <- xml2::xml_find_all(doc, paste0(".//", ns_prefix, ":TimeSeries"))
  rows <- list()

  for (ts in time_series) {
    periods <- xml2::xml_find_all(ts, paste0(".//", ns_prefix, ":Period"))
    for (period in periods) {
      start_node <- xml2::xml_find_first(period, paste0(".//", ns_prefix, ":timeInterval/", ns_prefix, ":start"))
      resolution_node <- xml2::xml_find_first(period, paste0(".//", ns_prefix, ":resolution"))
      if (is.na(start_node) || is.na(resolution_node)) next

      start_time <- parse_date_time(xml2::xml_text(start_node), orders = c("ymd HMS", "ymd HM"), tz = "UTC")
      resolution <- xml2::xml_text(resolution_node)
      step_minutes <- if (resolution == "PT15M") 15L else 60L

      points <- xml2::xml_find_all(period, paste0(".//", ns_prefix, ":Point"))
      for (pt in points) {
        pos <- as.integer(xml2::xml_text(xml2::xml_find_first(pt, paste0(ns_prefix, ":position"))))
        price <- as.numeric(xml2::xml_text(xml2::xml_find_first(pt, paste0(ns_prefix, ":price.amount"))))
        dt <- start_time + minutes((pos - 1L) * step_minutes)
        rows <- c(rows, list(tibble(datetime = dt, price_eur_mwh = price)))
      }
    }
  }

  if (length(rows) > 0) {
    new_entsoe <- bind_rows(rows) %>%
      distinct(datetime, .keep_all = TRUE) %>%
      arrange(datetime) %>%
      filter(datetime > last_entsoe)

    cat(sprintf("  -> %d new records fetched\n", nrow(new_entsoe)))

    if (nrow(new_entsoe) > 0) {
      combined <- bind_rows(existing_entsoe, new_entsoe) %>%
        distinct(datetime, .keep_all = TRUE) %>%
        arrange(datetime)
      write_csv(combined, entsoe_file)
      cat(sprintf("  -> Saved %d total records (up to %s)\n",
                  nrow(combined), format(max(combined$datetime), "%Y-%m-%d %H:%M")))
    }
  } else {
    cat("  -> No new data found\n")
  }
}

# =============================================================================
# 2. Open-Meteo temperature
# =============================================================================
cat("\n=== Updating Open-Meteo temperature 2026 ===\n")

meteo_file <- "data/openmeteo_temperature_2026.csv"
existing_meteo <- read_csv(meteo_file, show_col_types = FALSE)
last_meteo <- max(as.POSIXct(existing_meteo$timestamp, tz = "Europe/Brussels"))
cat(sprintf("  Last existing: %s\n", format(last_meteo, "%Y-%m-%d %H:%M")))

meteo_start <- as.Date(last_meteo) + 1
meteo_end <- Sys.Date() - 5  # archive API has ~5 day lag

if (meteo_start > meteo_end) {
  cat(sprintf("  -> Already up to date (archive lag: data available up to %s)\n", meteo_end))
} else {
  cat(sprintf("  Fetching: %s to %s\n", meteo_start, meteo_end))

  resp_meteo <- GET(
    "https://archive-api.open-meteo.com/v1/archive",
    query = list(
      latitude = 50.38,
      longitude = 4.86,
      start_date = format(meteo_start, "%Y-%m-%d"),
      end_date = format(meteo_end, "%Y-%m-%d"),
      hourly = "temperature_2m",
      timezone = "Europe/Brussels"
    ),
    timeout(60)
  )

  if (status_code(resp_meteo) != 200) {
    cat(sprintf("  HTTP error %d\n", status_code(resp_meteo)))
  } else {
    data_meteo <- content(resp_meteo, as = "parsed", simplifyVector = TRUE)

    if (!is.null(data_meteo$hourly)) {
      new_meteo <- tibble(
        timestamp = as.POSIXct(data_meteo$hourly$time, format = "%Y-%m-%dT%H:%M", tz = "Europe/Brussels"),
        t_ext = as.numeric(data_meteo$hourly$temperature_2m)
      ) %>%
        filter(!is.na(timestamp), !is.na(t_ext), timestamp > last_meteo)

      cat(sprintf("  -> %d new records fetched\n", nrow(new_meteo)))

      if (nrow(new_meteo) > 0) {
        combined_meteo <- bind_rows(existing_meteo, new_meteo) %>%
          distinct(timestamp, .keep_all = TRUE) %>%
          arrange(timestamp)
        write_csv(combined_meteo, meteo_file)
        cat(sprintf("  -> Saved %d total records (up to %s)\n",
                    nrow(combined_meteo), format(max(combined_meteo$timestamp), "%Y-%m-%d %H:%M")))
      }
    } else {
      cat("  -> No hourly data in response\n")
    }
  }
}

# =============================================================================
# 3. Rebuild .rda files
# =============================================================================
cat("\n=== Rebuilding .rda files ===\n")
source("data-raw/build_rda.R")

cat("\nDone!\n")
