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

#' Estimate PV kWc from CSV data using energy balance
#'
#' Uses the energy balance inconsistency rate to distinguish between
#' direct PV measurements (high peak capacity factor ~0.85) and
#' regional/scaled data like Elia profiles (lower effective capacity
#' factor ~0.70 due to geographic averaging).
#'
#' @param df Data frame with at least \code{pv_kwh}. Optionally
#'   \code{offtake_kwh} and \code{feedin_kwh} (or \code{intake_kwh})
#'   for balance-based refinement.
#' @return Estimated kWc (numeric), rounded to nearest 0.5
#' @export
estimate_pv_kwc <- function(df) {
  if (!"pv_kwh" %in% names(df) || all(is.na(df$pv_kwh))) return(6)

  p_peak <- max(df$pv_kwh, na.rm = TRUE) / 0.25

  # Resolve feedin column name
  feedin_col <- if ("feedin_kwh" %in% names(df)) "feedin_kwh" else
    if ("intake_kwh" %in% names(df)) "intake_kwh" else NULL

  has_balance <- "offtake_kwh" %in% names(df) && !is.null(feedin_col)

  if (has_balance) {
    # Balance: feedin > offtake + pv means PV is underrepresented
    daylight <- df$pv_kwh > 0.01
    deficit <- df[[feedin_col]] - df$offtake_kwh
    bad_rate <- mean(daylight & deficit > df$pv_kwh, na.rm = TRUE)

    # >0.5% inconsistencies = regional/scaled data (Elia-type, lower peak factor)
    # <0.5% = direct measurement (FusionSolar-type, higher peak factor)
    cf <- if (bad_rate > 0.005) 0.70 else 0.85
  } else {
    cf <- 0.85
  }

  est_kwc <- p_peak / cf
  max(1, min(200, round(est_kwc * 2) / 2))
}

#' Compute local PV performance correction factor
#'
#' When PV data comes from a regional profile (e.g. Elia) scaled to a
#' declared kWc, it may underestimate actual site production due to better
#' local conditions (orientation, tilt, microclimate). This function
#' computes a correction factor from the energy balance: at timesteps
#' where injection > 0, the real PV must have been at least
#' feedin + consumption - offtake.
#'
#' @param pv_kwh Numeric vector, PV production (already scaled to declared kWc)
#' @param offtake_kwh Numeric vector, grid offtake (from meter)
#' @param feedin_kwh Numeric vector, grid injection (from meter)
#' @return A single numeric correction factor (>= 1). Multiply pv_kwh by
#'   this factor to obtain corrected production.
#' @export
compute_pv_local_factor <- function(pv_kwh, offtake_kwh, feedin_kwh) {
  # Minimum PV needed for energy balance: pv >= feedin - offtake
  pv_min_needed <- pmax(0, feedin_kwh - offtake_kwh, na.rm = TRUE)

  # Only consider timesteps where both PV and deficit are positive
  mask <- pv_kwh > 0.01 & pv_min_needed > 0.01
  if (sum(mask, na.rm = TRUE) < 10) return(1)

  # Factor needed per timestep
  factors <- pv_min_needed[mask] / pv_kwh[mask]

  # Use 95th percentile to cover most cases without overfitting outliers
  factor <- as.numeric(stats::quantile(factors, 0.95, na.rm = TRUE))
  max(1, factor)
}
