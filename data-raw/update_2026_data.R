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
# 3. Elia CO2 intensity
#    - ODS192 (historical consumption-based) for forward-fill
#    - ODS201 (generation mix + IPCC factors) for backfill when ODS192 unavailable
# =============================================================================
cat("\n=== Updating Elia CO2 intensity 2026 ===\n")

co2_file <- "data/elia_co2_2026.csv"
existing_co2 <- read_csv(co2_file, show_col_types = FALSE,
  col_types = cols(datetime = col_character()))
existing_co2$datetime_parsed <- as.POSIXct(
  gsub("Z$", "", existing_co2$datetime),
  format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"
)

last_co2 <- max(existing_co2$datetime_parsed, na.rm = TRUE)
first_co2 <- min(existing_co2$datetime_parsed, na.rm = TRUE)
cat(sprintf("  Existing range: %s to %s (%d records)\n",
  format(first_co2, "%Y-%m-%d %H:%M"),
  format(last_co2, "%Y-%m-%d %H:%M"),
  nrow(existing_co2)))

year_start <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
now_utc <- as.POSIXct(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), tz = "UTC")

elia_base <- "https://opendata.elia.be/api/explore/v2.1/catalog/datasets"
page_size <- 100

# --- Helper: paginated fetch from ODS192 (consumption-based) ---
fetch_ods192_range <- function(start_dt, end_dt) {
  start_str <- format(start_dt, "%Y-%m-%dT%H:%M:%S")
  end_str   <- format(end_dt,   "%Y-%m-%dT%H:%M:%S")
  url <- sprintf("%s/ods192/records", elia_base)

  all_records <- list()
  offset <- 0

  repeat {
    resp <- GET(url,
      query = list(
        limit    = page_size,
        offset   = offset,
        order_by = "datetime",
        where    = sprintf('datetime >= "%s" AND datetime <= "%s"', start_str, end_str),
        select   = "datetime,consumption"
      ),
      timeout(30)
    )
    if (status_code(resp) != 200) {
      cat(sprintf("  ODS192 HTTP %d at offset %d\n", status_code(resp), offset))
      break
    }
    data <- content(resp, as = "parsed", simplifyVector = TRUE)
    records <- data$results
    if (is.null(records) || length(records) == 0 || nrow(records) == 0) break
    all_records[[length(all_records) + 1]] <- records
    total <- data$total_count %||% 0
    offset <- offset + nrow(records)
    cat(sprintf("\r  ODS192: %d / %d", offset, total))
    if (offset >= total) break
  }
  cat("\n")
  if (length(all_records) == 0) return(NULL)

  df <- bind_rows(all_records)
  df$datetime_parsed <- as.POSIXct(
    sub("[+-]\\d{2}:\\d{2}$", "", df$datetime),
    format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"
  )
  df$datetime_parsed <- lubridate::floor_date(df$datetime_parsed, "hour")
  df %>%
    transmute(
      datetime = format(datetime_parsed, "%Y-%m-%dT%H:%M:%SZ"),
      co2_g_per_kwh = as.numeric(consumption)
    ) %>%
    filter(!is.na(co2_g_per_kwh)) %>%
    distinct(datetime, .keep_all = TRUE)
}

# --- Helper: production-based CO2 from ODS201 generation mix ---
ipcc_ef <- c(
  "Nuclear" = 12, "Wind Onshore" = 11, "Wind Offshore" = 12,
  "Solar" = 41, "Hydro Run-of-river and poundage" = 4,
  "Hydro Pumped Storage" = 30, "Fossil Gas" = 490, "Fossil Oil" = 650,
  "Biomass" = 230, "Waste" = 350, "Energy Storage" = 0, "Other" = 300
)

fetch_ods201_co2_range <- function(start_dt, end_dt) {
  start_str <- format(start_dt, "%Y-%m-%dT%H:%M:%S")
  end_str   <- format(end_dt,   "%Y-%m-%dT%H:%M:%S")
  url <- sprintf("%s/ods201/records", elia_base)

  all_records <- list()
  offset <- 0

  repeat {
    resp <- GET(url,
      query = list(
        limit    = page_size,
        offset   = offset,
        order_by = "datetime",
        where    = sprintf('datetime >= "%s" AND datetime <= "%s"', start_str, end_str),
        select   = "datetime,fueltypeentsoe,generatedpower"
      ),
      timeout(30)
    )
    if (status_code(resp) != 200) {
      cat(sprintf("  ODS201 HTTP %d at offset %d\n", status_code(resp), offset))
      break
    }
    data <- content(resp, as = "parsed", simplifyVector = TRUE)
    records <- data$results
    if (is.null(records) || length(records) == 0 || nrow(records) == 0) break
    all_records[[length(all_records) + 1]] <- records
    total <- data$total_count %||% 0
    offset <- offset + nrow(records)
    cat(sprintf("\r  ODS201: %d / %d", offset, total))
    if (offset >= total) break
  }
  cat("\n")
  if (length(all_records) == 0) return(NULL)

  df <- bind_rows(all_records)
  df$datetime_parsed <- as.POSIXct(
    sub("[+-]\\d{2}:\\d{2}$", "", df$datetime),
    format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"
  )
  df$datetime_parsed <- lubridate::floor_date(df$datetime_parsed, "hour")
  df$generatedpower <- as.numeric(df$generatedpower)
  df <- df %>% filter(!is.na(generatedpower), generatedpower > 0)
  if (nrow(df) == 0) return(NULL)

  df$ef <- ipcc_ef[df$fueltypeentsoe]
  df$ef[is.na(df$ef)] <- 300
  df$co2_g <- df$generatedpower * df$ef

  hourly <- df %>%
    group_by(datetime_parsed) %>%
    summarise(co2_g_per_kwh = sum(co2_g) / sum(generatedpower), .groups = "drop") %>%
    filter(!is.na(co2_g_per_kwh)) %>%
    transmute(
      datetime = format(datetime_parsed, "%Y-%m-%dT%H:%M:%SZ"),
      co2_g_per_kwh = round(co2_g_per_kwh, 3)
    ) %>%
    distinct(datetime, .keep_all = TRUE)
  hourly
}

new_co2_all <- list()

# Forward-fill from ODS192
if (last_co2 < now_utc - 3600) {
  cat(sprintf("  Forward: %s to %s (ODS192)\n",
    format(last_co2 + 1, "%Y-%m-%d %H:%M"), format(now_utc, "%Y-%m-%d %H:%M")))
  chunk <- fetch_ods192_range(last_co2 + 1, now_utc)
  if (!is.null(chunk) && nrow(chunk) > 0) {
    new_co2_all[["forward"]] <- chunk
    cat(sprintf("  -> %d records\n", nrow(chunk)))
  } else {
    cat("  -> No new ODS192 data\n")
  }
}

# Backfill from ODS201 (generation mix) for any gaps > 1 hour
# Merge existing + forward data first, then detect gaps
partial_co2 <- bind_rows(
  existing_co2 %>% select(datetime, co2_g_per_kwh),
  if (!is.null(new_co2_all[["forward"]])) new_co2_all[["forward"]] else tibble()
) %>%
  distinct(datetime, .keep_all = TRUE) %>%
  arrange(datetime)

partial_co2$dt <- as.POSIXct(gsub("Z$", "", partial_co2$datetime),
  format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")

# Check coverage from year_start
all_dts <- sort(unique(partial_co2$dt))
if (length(all_dts) > 0 && min(all_dts) > year_start + 3600) {
  # Gap before first record
  gap_ranges <- list(list(start = year_start, end = min(all_dts) - 1))
} else {
  gap_ranges <- list()
}
# Internal gaps > 1 hour
if (length(all_dts) > 1) {
  diffs <- diff(as.numeric(all_dts))
  gap_idx <- which(diffs > 3600)
  for (i in gap_idx) {
    gap_ranges[[length(gap_ranges) + 1]] <- list(
      start = all_dts[i] + 1,
      end = all_dts[i + 1] - 1
    )
  }
}

if (length(gap_ranges) > 0) {
  cat(sprintf("  Found %d gap(s) to backfill via ODS201\n", length(gap_ranges)))
  backfill_chunks <- list()
  for (g in gap_ranges) {
    # Split into 7-day chunks to avoid API offset limit
    chunk_start <- g$start
    while (chunk_start < g$end) {
      chunk_end <- min(chunk_start + days(7) - 1, g$end)
      cat(sprintf("  ODS201 chunk: %s to %s\n",
        format(chunk_start, "%Y-%m-%d"), format(chunk_end, "%Y-%m-%d")))
      ch <- fetch_ods201_co2_range(chunk_start, chunk_end)
      if (!is.null(ch) && nrow(ch) > 0) {
        backfill_chunks[[length(backfill_chunks) + 1]] <- ch
        cat(sprintf("  -> %d records\n", nrow(ch)))
      }
      chunk_start <- chunk_end + 1
    }
  }
  if (length(backfill_chunks) > 0) {
    new_co2_all[["backfill"]] <- bind_rows(backfill_chunks)
    cat(sprintf("  Total backfill: %d records (production-based)\n",
      nrow(new_co2_all[["backfill"]])))
  }
}

if (length(new_co2_all) > 0) {
  new_co2 <- bind_rows(new_co2_all)
  combined_co2 <- bind_rows(
    existing_co2 %>% select(datetime, co2_g_per_kwh),
    new_co2
  ) %>%
    distinct(datetime, .keep_all = TRUE) %>%
    arrange(datetime)
  write_csv(combined_co2, co2_file)
  cat(sprintf("  -> Saved %d total records (was %d)\n",
    nrow(combined_co2), nrow(existing_co2)))
} else {
  cat("  -> Already up to date\n")
}

# =============================================================================
# 4. Rebuild .rda files
# =============================================================================
cat("\n=== Rebuilding .rda files ===\n")
source("data-raw/build_rda.R")

cat("\nDone!\n")
