# =============================================================================
# Data preparation functions
# =============================================================================
# Standalone functions for data loading and enrichment.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Compute monthly BELIX averages (peak and off-peak)
#'
#' BELIX peak = average spot price during 8h-20h per month.
#' BELIX off-peak = average spot price during 20h-8h per month.
#'
#' @param df Dataframe with \code{timestamp} and \code{prix_eur_kwh} columns
#' @return A dataframe with columns: year_month, belix_peak_eur_kwh, belix_offpeak_eur_kwh
#' @export
compute_belix_monthly <- function(df) {
  h <- as.integer(format(df$timestamp, "%H", tz = "Europe/Brussels"))
  is_belix_peak <- h >= 8 & h < 20

  df_belix <- dplyr::tibble(
    year_month = format(df$timestamp, "%Y-%m", tz = "Europe/Brussels"),
    prix_eur_kwh = df$prix_eur_kwh,
    is_belix_peak = is_belix_peak
  )

  df_belix %>%
    dplyr::group_by(year_month) %>%
    dplyr::summarise(
      belix_peak_eur_kwh = mean(prix_eur_kwh[is_belix_peak], na.rm = TRUE),
      belix_offpeak_eur_kwh = mean(prix_eur_kwh[!is_belix_peak], na.rm = TRUE),
      .groups = "drop"
    )
}

#' Determine if each timestamp falls in contract peak hours
#'
#' @param timestamps POSIXct vector
#' @param peak_hours List of c(start, end) pairs defining peak hours (e.g. list(c(7,11), c(17,22)))
#' @return Logical vector, TRUE = peak
#' @export
is_contract_peak <- function(timestamps, peak_hours) {
  h <- as.integer(format(timestamps, "%H", tz = "Europe/Brussels"))
  is_peak <- rep(FALSE, length(h))
  for (slot in peak_hours) {
    is_peak <- is_peak | (h >= slot[1] & h < slot[2])
  }
  is_peak
}

#' Inject real Belpex prices into simulation dataframe
#'
#' Loads Belpex (ENTSO-E) day-ahead prices from local CSV cache or API,
#' then joins them onto the simulation dataframe, replacing synthetic prices
#' where real prices are available.
#'
#' @param df Dataframe with \code{timestamp} and \code{prix_eur_kwh} columns
#' @param api_key ENTSO-E API key (from env var \code{ENTSOE_API_KEY})
#' @param data_dir Path to local price data directory (default \code{"data"})
#' @return The input dataframe with \code{prix_eur_kwh} updated where real
#'   Belpex prices are available. Returns \code{df} unchanged if no prices
#'   are found.
#' @export
inject_belpex_prices <- function(df, api_key = "", data_dir = "data") {
  ts_min <- min(df$timestamp, na.rm = TRUE)
  ts_max <- max(df$timestamp, na.rm = TRUE)
  if (is.na(ts_min) || is.na(ts_max)) return(df)
  belpex <- load_belpex_prices(
    start_date = ts_min,
    end_date = ts_max,
    api_key = api_key,
    data_dir = data_dir
  )

  if (is.null(belpex$data) || nrow(belpex$data) == 0) {
    return(df)
  }

  belpex_h <- belpex$data %>%
    dplyr::mutate(
      datetime_bxl = lubridate::with_tz(datetime, tzone = "Europe/Brussels"),
      heure_join = lubridate::floor_date(datetime_bxl, unit = "hour"),
      prix_belpex = price_eur_mwh / 1000
    ) %>%
    dplyr::distinct(heure_join, .keep_all = TRUE) %>%
    dplyr::select(heure_join, prix_belpex)

  if (!"prix_eur_kwh" %in% names(df)) df$prix_eur_kwh <- NA_real_

  df <- df %>%
    dplyr::mutate(heure_join = lubridate::floor_date(timestamp, unit = "hour")) %>%
    dplyr::left_join(belpex_h, by = "heure_join") %>%
    dplyr::mutate(prix_eur_kwh = dplyr::coalesce(prix_belpex, prix_eur_kwh)) %>%
    dplyr::select(-heure_join, -prix_belpex)

  # Fill remaining NAs (end of price data, gaps) with median price
  # to prevent solver crashes on NA coefficients
  n_na <- sum(is.na(df$prix_eur_kwh))
  if (n_na > 0) {
    med_prix <- stats::median(df$prix_eur_kwh, na.rm = TRUE)
    df$prix_eur_kwh[is.na(df$prix_eur_kwh)] <- med_prix
    message(sprintf("[Belpex] %d NAs remplaces par le prix median (%.4f EUR/kWh)", n_na, med_prix))
  }

  df
}
