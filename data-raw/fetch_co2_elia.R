#!/usr/bin/env Rscript
# =============================================================================
# Fetch CO2 intensity from Elia ODS192 (consumption-based) and save as CSV
# Same pattern as belpex_historical_YYYY.csv
# Output: data/co2_historical_YYYY.csv (datetime UTC, co2_g_per_kwh)
# =============================================================================

library(httr)
library(dplyr)
library(readr)

ELIA_BASE_URL  <- "https://opendata.elia.be/api/explore/v2.1/catalog/datasets"
ELIA_PAGE_SIZE <- 100
ELIA_TIMEOUT   <- 30
DATASET_ID     <- "ods192"  # consumption-based historical

# -- Paginated fetch for one year ------------------------------------------------
fetch_year <- function(year) {
  start_str <- sprintf("%d-01-01T00:00:00", year)
  end_str   <- sprintf("%d-12-31T23:59:59", year)
  url <- sprintf("%s/%s/records", ELIA_BASE_URL, DATASET_ID)

  where_clause <- sprintf(
    'datetime >= "%s" AND datetime <= "%s"',
    start_str, end_str
  )

  # First request: get total_count
  resp <- GET(url,
    query = list(
      limit  = 1,
      offset = 0,
      where  = where_clause,
      select = "datetime,consumption"
    ),
    timeout(ELIA_TIMEOUT)
  )
  stop_for_status(resp)
  meta <- content(resp, as = "parsed", simplifyVector = TRUE)
  total <- meta$total_count %||% 0
  message(sprintf("[%d] %d records to fetch", year, total))

  if (total == 0) return(NULL)

  # Fetch all pages
  all_records <- list()
  offset <- 0
  while (offset < total) {
    message(sprintf("  offset %d / %d", offset, total))
    resp <- GET(url,
      query = list(
        limit    = ELIA_PAGE_SIZE,
        offset   = offset,
        order_by = "datetime",
        where    = where_clause,
        select   = "datetime,consumption"
      ),
      timeout(ELIA_TIMEOUT)
    )
    stop_for_status(resp)
    data <- content(resp, as = "parsed", simplifyVector = TRUE)
    records <- data$results
    if (is.null(records) || nrow(records) == 0) break
    all_records[[length(all_records) + 1]] <- records
    offset <- offset + nrow(records)
  }

  if (length(all_records) == 0) return(NULL)

  df <- bind_rows(all_records)
  # Normalize datetime to UTC ISO format
  df$datetime <- sub("[+-]\\d{2}:\\d{2}$", "", df$datetime)
  df <- df %>%
    rename(co2_g_per_kwh = consumption) %>%
    mutate(datetime = paste0(datetime, "Z")) %>%
    filter(!is.na(co2_g_per_kwh)) %>%
    distinct(datetime, .keep_all = TRUE) %>%
    arrange(datetime)

  df
}

# -- Main ----------------------------------------------------------------------
`%||%` <- function(x, y) if (is.null(x)) y else x
years <- c(2024, 2025)
out_dir <- file.path(getwd(), "data")

for (year in years) {
  message(sprintf("\n=== Fetching CO2 Elia ODS192 for %d ===", year))
  df <- tryCatch(fetch_year(year), error = function(e) {
    message(sprintf("ERROR for %d: %s", year, e$message))
    NULL
  })
  if (!is.null(df) && nrow(df) > 0) {
    out_file <- file.path(out_dir, sprintf("co2_historical_%d.csv", year))
    write_csv(df, out_file)
    message(sprintf("Saved %d rows -> %s", nrow(df), out_file))
  } else {
    message(sprintf("No data for %d", year))
  }
}

message("\nDone.")
