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
#' When \code{sum_cols} is provided, those columns are aggregated with
#' \code{sum()} and all other numeric columns with \code{mean()}.
#' When \code{sum_cols} is NULL (default), all numeric columns are summed
#' (backward-compatible behaviour).
#'
#' @param df Data frame with a timestamp column
#' @param timestamp_col Name of the timestamp column (default "timestamp")
#' @param sum_cols Optional character vector of column names to aggregate
#'   with \code{sum()}. Other numeric columns use \code{mean()}.
#' @return A list with \code{data} (aggregated data frame), \code{level}
#'   (aggregation level string), and \code{label} (display label)
#' @export
auto_aggregate <- function(df, timestamp_col = "timestamp", sum_cols = NULL) {
  period_days <- as.numeric(difftime(
    max(df[[timestamp_col]], na.rm = TRUE),
    min(df[[timestamp_col]], na.rm = TRUE),
    units = "days"
  ))

  levels <- list(
    list(max_days = 1,   unit = NULL,   level = "15 min", label = "15 min"),
    list(max_days = 3,   unit = "hour", level = "hour",   label = "Horaire"),
    list(max_days = 7,   unit = "day",  level = "day",    label = "Journalier"),
    list(max_days = Inf, unit = "week", level = "week",   label = "Hebdomadaire")
  )
  chosen <- Find(function(l) period_days <= l$max_days, levels)

  if (is.null(chosen$unit)) {
    return(list(data = df, level = chosen$level, label = chosen$label))
  }

  df$.agg_key <- lubridate::floor_date(df[[timestamp_col]], chosen$unit)

  if (is.null(sum_cols)) {
    # Backward-compatible: sum everything
    agg <- df %>%
      dplyr::group_by(.agg_key) %>%
      dplyr::summarise(dplyr::across(dplyr::where(is.numeric), ~sum(.x, na.rm = TRUE)), .groups = "drop") %>%
      dplyr::rename(!!timestamp_col := .agg_key)
  } else {
    sum_cols_present <- intersect(sum_cols, names(df))
    mean_cols <- setdiff(names(df)[sapply(df, is.numeric)], c(sum_cols_present, ".agg_key"))
    agg <- df %>%
      dplyr::group_by(.agg_key) %>%
      dplyr::summarise(
        dplyr::across(dplyr::any_of(sum_cols_present), ~sum(.x, na.rm = TRUE)),
        dplyr::across(dplyr::any_of(mean_cols), ~mean(.x, na.rm = TRUE)),
        .groups = "drop") %>%
      dplyr::rename(!!timestamp_col := .agg_key)
  }

  list(data = agg, level = chosen$level, label = chosen$label)
}
