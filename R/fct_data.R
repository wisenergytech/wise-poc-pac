# =============================================================================
# Data preparation functions
# =============================================================================
# Standalone functions for data loading and enrichment.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

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
  belpex <- load_belpex_prices(
    start_date = min(df$timestamp),
    end_date = max(df$timestamp),
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

  df %>%
    dplyr::mutate(heure_join = lubridate::floor_date(timestamp, unit = "hour")) %>%
    dplyr::left_join(belpex_h, by = "heure_join") %>%
    dplyr::mutate(prix_eur_kwh = dplyr::coalesce(prix_belpex, prix_eur_kwh)) %>%
    dplyr::select(-heure_join, -prix_belpex)
}
