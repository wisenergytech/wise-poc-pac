# =============================================================================
# R6 Class: DataProvider
# =============================================================================
# Wraps the existing data loading functions for Belpex prices, Open-Meteo
# temperature, and Elia CO2 intensity. Delegates to the standalone functions
# in R/data_entsoe_prices.R, R/data_openmeteo_temperature.R, R/data_elia_co2.R.
# =============================================================================

#' @title Data Provider
#' @description R6 class for loading external data (Belpex prices, temperature,
#'   CO2 intensity). Provides a unified interface with optional caching.
#' @export
DataProvider <- R6::R6Class("DataProvider",
  public = list(
    #' @description Create a new DataProvider.
    #' @param data_dir Directory containing local data files (default "data")
    initialize = function(data_dir = "data") {
      private$data_dir <- data_dir
    },

    #' @description Load Belpex day-ahead prices.
    #'   Delegates to load_belpex_prices() from R/belpex.R.
    #' @param date_start Start date (Date or POSIXct)
    #' @param date_end End date (Date or POSIXct)
    #' @param api_key Optional ENTSO-E API key. If NULL, reads from env var.
    #' @return A list with $data (tibble with datetime, price_eur_mwh) and $source
    get_belpex = function(date_start, date_end, api_key = NULL) {
      if (is.null(api_key)) {
        api_key <- Sys.getenv("ENTSOE_API_KEY", Sys.getenv("ENTSO-E_API_KEY", ""))
      }
      load_belpex_prices(
        start_date = date_start,
        end_date = date_end,
        api_key = api_key,
        data_dir = private$data_dir
      )
    },

    #' @description Load historical temperatures from Open-Meteo CSV files.
    #'   Delegates to load_openmeteo_temperature() from R/openmeteo.R.
    #' @param date_start Start date
    #' @param date_end End date
    #' @return tibble with columns: timestamp (POSIXct), t_ext (degrees C),
    #'   or NULL if no data found
    get_temperature = function(date_start, date_end) {
      load_openmeteo_temperature(
        start_date = date_start,
        end_date = date_end,
        data_dir = private$data_dir
      )
    },

    #' @description Load CO2 intensity data from Elia.
    #'   Delegates to fetch_co2_intensity() from R/co2_elia.R.
    #' @param date_start Start date
    #' @param date_end End date
    #' @return A list with $df (tibble with datetime, co2_g_per_kwh) and $source
    get_co2 = function(date_start, date_end) {
      fetch_co2_intensity(
        start_date = date_start,
        end_date = date_end
      )
    },

    #' @description Interpolate hourly temperatures to 15-min resolution.
    #'   Delegates to interpolate_temperature_15min() from R/openmeteo.R.
    #' @param df_hourly tibble with timestamp and t_ext columns (hourly)
    #' @param ts_15min Vector of POSIXct timestamps at 15-min intervals
    #' @return Numeric vector of interpolated temperatures
    interpolate_temperature = function(df_hourly, ts_15min) {
      interpolate_temperature_15min(df_hourly, ts_15min)
    },

    #' @description Interpolate hourly CO2 intensity to 15-min resolution.
    #'   Delegates to interpolate_co2_15min() from R/co2_elia.R.
    #' @param co2_hourly tibble with datetime and co2_g_per_kwh (hourly, UTC)
    #' @param ts_15min Vector of timestamps at 15-min intervals
    #' @return Numeric vector of interpolated CO2 intensity
    interpolate_co2 = function(co2_hourly, ts_15min) {
      interpolate_co2_15min(co2_hourly, ts_15min)
    }
  ),

  private = list(
    data_dir = NULL
  )
)
