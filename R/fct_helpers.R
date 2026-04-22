#' Calculate COP (Coefficient of Performance)
#'
#' COP depends on external temperature (source) and optionally on
#' the tank temperature (condenser). Clamped to [1.5, 5.5].
#'
#' @param t_ext External temperature (degrees C)
#' @param cop_nominal Nominal COP at reference temperature (default 3.5)
#' @param t_ref Reference external temperature for nominal COP (default 7)
#' @param t_ballon Optional tank temperature (degrees C). If provided, COP
#'   is reduced by 1% per degree above t_ballon_ref.
#' @param t_ballon_ref Reference tank temperature (default 50)
#' @return Numeric vector of COP values, clamped to [1.5, 5.5]
#' @export
calc_cop <- function(t_ext, cop_nominal = 3.5, t_ref = 7, t_ballon = NULL, t_ballon_ref = 50) {
  # COP depends on T_ext (source temperature): +0.1 per C above reference
  cop <- cop_nominal + 0.1 * (t_ext - t_ref)
  # If T_ballon provided, COP also depends on condenser temperature:
  # -1% per C above reference (higher T_ballon = harder to heat = lower COP)
  if (!is.null(t_ballon)) {
    cop <- cop * (1 - 0.01 * (t_ballon - t_ballon_ref))
  }
  pmax(1.5, pmin(5.5, cop))
}

#' Auto-Aggregate Based on Period Length
#'
#' Automatically chooses aggregation level based on the time span:
#' <= 1 day: 15 min (no aggregation) | <= 3 days: hourly |
#' <= 7 days: daily | > 7 days: weekly
#'
#' @param df Data frame with a timestamp column
#' @param timestamp_col Name of the timestamp column (default "timestamp")
#' @return A list with \code{data} (aggregated data frame), \code{level}
#'   (aggregation level string), and \code{label} (display label)
#' @export
auto_aggregate <- function(df, timestamp_col = "timestamp") {
  period_days <- as.numeric(difftime(
    max(df[[timestamp_col]], na.rm = TRUE),
    min(df[[timestamp_col]], na.rm = TRUE),
    units = "days"
  ))
  if (period_days <= 1) {
    list(data = df, level = "15 min", label = "15 min")
  } else if (period_days <= 3) {
    agg <- df %>%
      dplyr::mutate(.h = lubridate::floor_date(!!rlang::sym(timestamp_col), "hour")) %>%
      dplyr::group_by(.h) %>%
      dplyr::summarise(dplyr::across(dplyr::where(is.numeric), ~sum(.x, na.rm = TRUE)), .groups = "drop") %>%
      dplyr::rename(!!timestamp_col := .h)
    list(data = agg, level = "hour", label = "Horaire")
  } else if (period_days <= 7) {
    agg <- df %>%
      dplyr::mutate(.d = lubridate::floor_date(!!rlang::sym(timestamp_col), "day")) %>%
      dplyr::group_by(.d) %>%
      dplyr::summarise(dplyr::across(dplyr::where(is.numeric), ~sum(.x, na.rm = TRUE)), .groups = "drop") %>%
      dplyr::rename(!!timestamp_col := .d)
    list(data = agg, level = "day", label = "Journalier")
  } else {
    agg <- df %>%
      dplyr::mutate(.w = lubridate::floor_date(!!rlang::sym(timestamp_col), "week")) %>%
      dplyr::group_by(.w) %>%
      dplyr::summarise(dplyr::across(dplyr::where(is.numeric), ~sum(.x, na.rm = TRUE)), .groups = "drop") %>%
      dplyr::rename(!!timestamp_col := .w)
    list(data = agg, level = "week", label = "Hebdomadaire")
  }
}
