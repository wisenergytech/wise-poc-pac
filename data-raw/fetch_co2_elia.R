#!/usr/bin/env Rscript
# =============================================================================
# Fetch CO2 intensity from Elia and save as CSV
#
# Strategy:
#   1. ODS192 (consumption-based, historical) — best quality, but incomplete
#   2. ODS201 (generation mix) — compute production-based via IPCC factors
#      for any hours missing from ODS192
#   3. Merge, deduplicate, save per year
#
# Output: data/co2_historical_YYYY.csv (datetime UTC, co2_g_per_kwh)
# =============================================================================

library(httr)
library(dplyr)
library(readr)
library(lubridate)

ELIA_BASE_URL  <- "https://opendata.elia.be/api/explore/v2.1/catalog/datasets"
ELIA_PAGE_SIZE <- 100    # max for most datasets
ELIA_PAGE_SIZE_ODS201 <- 100  # ODS201 also caps at 100
ELIA_TIMEOUT   <- 60

`%||%` <- function(x, y) if (is.null(x)) y else x

# IPCC AR5 emission factors (gCO2eq/kWh) by ENTSO-E fuel type
IPCC_EMISSION_FACTORS <- c(
  "Nuclear"                         = 12.0,
  "Wind Onshore"                    = 11.0,
  "Wind Offshore"                   = 12.0,
  "Solar"                           = 41.0,
  "Hydro Run-of-river and poundage" = 4.0,
  "Hydro Pumped Storage"            = 30.0,
  "Fossil Gas"                      = 490.0,
  "Fossil Oil"                      = 650.0,
  "Biomass"                         = 230.0,
  "Waste"                           = 350.0,
  "Energy Storage"                  = 0.0,
  "Other"                           = 300.0
)

# ---------------------------------------------------------------------------
# Generic paginated Elia API fetch
# ---------------------------------------------------------------------------
fetch_elia_paginated <- function(dataset_id, where_clause, select_fields,
                                 order_by = "datetime") {
  url <- sprintf("%s/%s/records", ELIA_BASE_URL, dataset_id)

  # Get total count first
  resp <- GET(url,
    query = list(limit = 1, offset = 0, where = where_clause, select = select_fields),
    timeout(ELIA_TIMEOUT)
  )
  if (status_code(resp) != 200) {
    message(sprintf("  [%s] HTTP %d", dataset_id, status_code(resp)))
    return(NULL)
  }
  meta <- content(resp, as = "parsed", simplifyVector = TRUE)
  total <- meta$total_count %||% 0
  message(sprintf("  [%s] %d records to fetch", dataset_id, total))
  if (total == 0) return(NULL)

  all_records <- list()
  offset <- 0
  while (offset < total) {
    if (offset %% 1000 == 0 && offset > 0) {
      message(sprintf("  [%s] %d / %d ...", dataset_id, offset, total))
    }
    resp <- GET(url,
      query = list(
        limit = ELIA_PAGE_SIZE, offset = offset, order_by = order_by,
        where = where_clause, select = select_fields
      ),
      timeout(ELIA_TIMEOUT)
    )
    if (status_code(resp) != 200) break
    data <- content(resp, as = "parsed", simplifyVector = TRUE)
    records <- data$results
    if (is.null(records) || nrow(records) == 0) break
    all_records[[length(all_records) + 1]] <- records
    offset <- offset + nrow(records)
    Sys.sleep(0.1)  # be nice to the API
  }

  if (length(all_records) == 0) return(NULL)
  bind_rows(all_records)
}

# ---------------------------------------------------------------------------
# Source 1: ODS192 consumption-based (best quality)
# ---------------------------------------------------------------------------
fetch_ods192 <- function(year) {
  where_clause <- sprintf(
    'datetime >= "%d-01-01T00:00:00" AND datetime <= "%d-12-31T23:59:59"',
    year, year
  )
  df <- fetch_elia_paginated("ods192", where_clause, "datetime,consumption")
  if (is.null(df)) return(NULL)

  df$datetime <- sub("[+-]\\d{2}:\\d{2}$", "", df$datetime)
  df$datetime <- as.POSIXct(df$datetime, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  df$datetime <- floor_date(df$datetime, "hour")
  df %>%
    rename(co2_g_per_kwh = consumption) %>%
    filter(!is.na(co2_g_per_kwh)) %>%
    distinct(datetime, .keep_all = TRUE) %>%
    arrange(datetime)
}

# ---------------------------------------------------------------------------
# Source 2: ODS201 generation mix → production-based (IPCC factors)
# Fetches month by month to avoid hitting API pagination limits
# (~35K records/month × 12 = ~420K/year, 100 per page)
# ---------------------------------------------------------------------------
fetch_ods201 <- function(year) {
  # Fetch week by week to stay under Elia API 10K record limit
  # (1 week = 7 days × 96 qt × ~12 fuels ≈ 8064 records < 10K)
  start <- as.Date(sprintf("%d-01-01", year))
  end <- as.Date(sprintf("%d-12-31", year))
  weeks <- seq(start, end, by = "7 days")

  all_weeks <- list()
  for (i in seq_along(weeks)) {
    w_start <- weeks[i]
    w_end <- min(w_start + 6, end)
    message(sprintf("  ODS201 %s to %s...", w_start, w_end))

    where_clause <- sprintf(
      'datetime >= "%sT00:00:00" AND datetime <= "%sT23:59:59" AND resolutioncode = "PT15M"',
      w_start, w_end
    )
    df <- tryCatch(
      fetch_elia_paginated("ods201", where_clause,
        "datetime,fueltypeentsoe,generatedpower"),
      error = function(e) {
        message(sprintf("    Error: %s", e$message)); NULL
      }
    )
    if (is.null(df) || nrow(df) == 0) next

    df$datetime <- sub("[+-]\\d{2}:\\d{2}$", "", df$datetime)
    df$datetime <- as.POSIXct(df$datetime, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    df$datetime <- floor_date(df$datetime, "hour")
    df$generatedpower <- as.numeric(df$generatedpower)
    df <- df %>% filter(!is.na(generatedpower), generatedpower > 0)
    if (nrow(df) == 0) next

    df$ef <- IPCC_EMISSION_FACTORS[df$fueltypeentsoe]
    df$ef[is.na(df$ef)] <- 300.0
    df$co2_g <- df$generatedpower * df$ef

    hourly <- df %>%
      group_by(datetime) %>%
      summarise(co2_g_per_kwh = sum(co2_g) / sum(generatedpower), .groups = "drop") %>%
      filter(!is.na(co2_g_per_kwh))

    if (nrow(hourly) > 0) {
      all_weeks[[length(all_weeks) + 1]] <- hourly
      message(sprintf("    -> %d hourly records", nrow(hourly)))
    }
  }
  if (length(all_weeks) == 0) return(NULL)
  bind_rows(all_weeks) %>% distinct(datetime, .keep_all = TRUE) %>% arrange(datetime)
}

# ---------------------------------------------------------------------------
# Merge: ODS192 priority, fill gaps with ODS201
# ---------------------------------------------------------------------------
merge_sources <- function(ods192, ods201, year) {
  # Build complete hourly grid for the year
  grid <- tibble(
    datetime = seq(
      as.POSIXct(sprintf("%d-01-01 00:00:00", year), tz = "UTC"),
      as.POSIXct(sprintf("%d-12-31 23:00:00", year), tz = "UTC"),
      by = "1 hour"
    )
  )

  n_expected <- nrow(grid)

  # Start with ODS192
  if (!is.null(ods192) && nrow(ods192) > 0) {
    grid <- grid %>% left_join(ods192, by = "datetime")
    n_ods192 <- sum(!is.na(grid$co2_g_per_kwh))
    message(sprintf("  ODS192: %d / %d hours (%.1f%%)",
      n_ods192, n_expected, n_ods192 / n_expected * 100))
  } else {
    grid$co2_g_per_kwh <- NA_real_
    n_ods192 <- 0
    message("  ODS192: 0 records")
  }

  # Fill gaps with ODS201
  if (!is.null(ods201) && nrow(ods201) > 0) {
    missing_idx <- is.na(grid$co2_g_per_kwh)
    n_missing <- sum(missing_idx)
    if (n_missing > 0) {
      ods201_lookup <- ods201 %>% distinct(datetime, .keep_all = TRUE)
      grid_filled <- grid %>%
        left_join(ods201_lookup %>% rename(co2_ods201 = co2_g_per_kwh),
                  by = "datetime")
      grid$co2_g_per_kwh[missing_idx] <- grid_filled$co2_ods201[missing_idx]
      n_ods201 <- sum(!is.na(grid$co2_g_per_kwh)) - n_ods192
      message(sprintf("  ODS201: filled %d / %d missing hours", n_ods201, n_missing))
    }
  }

  # Report final coverage
  n_final <- sum(!is.na(grid$co2_g_per_kwh))
  n_still_missing <- n_expected - n_final
  message(sprintf("  Final: %d / %d hours (%.1f%%), %d still missing",
    n_final, n_expected, n_final / n_expected * 100, n_still_missing))

  # Drop rows with no data
  grid %>% filter(!is.na(co2_g_per_kwh))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
years <- c(2024, 2025)
out_dir <- file.path(getwd(), "data")

for (year in years) {
  message(sprintf("\n=== Fetching CO2 Elia for %d ===", year))

  message("Step 1: ODS192 (consumption-based)...")
  ods192 <- tryCatch(fetch_ods192(year), error = function(e) {
    message(sprintf("  ODS192 error: %s", e$message)); NULL
  })

  message("Step 2: ODS201 (generation mix)...")
  ods201 <- tryCatch(fetch_ods201(year), error = function(e) {
    message(sprintf("  ODS201 error: %s", e$message)); NULL
  })

  message("Step 3: Merging...")
  df <- merge_sources(ods192, ods201, year)

  if (nrow(df) > 0) {
    # Format datetime as UTC ISO string
    df <- df %>%
      mutate(datetime = format(datetime, "%Y-%m-%dT%H:%M:%SZ")) %>%
      arrange(datetime)
    out_file <- file.path(out_dir, sprintf("co2_historical_%d.csv", year))
    write_csv(df, out_file)
    message(sprintf("Saved %d rows -> %s", nrow(df), out_file))
  } else {
    message(sprintf("No data for %d", year))
  }
}

message("\nDone.")
