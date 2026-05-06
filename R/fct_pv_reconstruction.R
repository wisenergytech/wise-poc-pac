#' Reconstruct real PV production from energy balance
#'
#' PV = Elec_consumption - offtake + feedin (clamped to >= 0)
#'
#' @param df Dataframe with elec_kwh, offtake_kwh, feedin_kwh columns
#' @return Numeric vector of pv_reel (kWh per timestep)
#' @noRd
reconstruct_pv <- function(df) {
  pmax(0, df$elec_kwh - df$offtake_kwh + df$feedin_kwh)
}

#' Assess PV stability over time
#'
#' Computes monthly PV totals and evaluates the coefficient of variation.
#' A CV > 30% indicates progressive commissioning or unstable production.
#'
#' @param pv_reel Numeric vector of reconstructed PV (kWh per timestep)
#' @param timestamps POSIXct vector (same length as pv_reel)
#' @param pv_elia Optional numeric vector of Elia-scaled PV for ratio comparison
#' @return List with: stable (logical), cv (numeric), msg (character)
#' @noRd
assess_pv_stability <- function(pv_reel, timestamps, pv_elia = NULL) {
  n_days <- as.numeric(difftime(max(timestamps), min(timestamps), units = "days"))
  if (n_days < 60) {
    return(list(stable = TRUE, cv = NA_real_, msg = "P\u00e9riode trop courte pour \u00e9valuer la stabilit\u00e9 PV"))
  }

  monthly_df <- data.frame(
    month = format(timestamps, "%Y-%m"),
    pv_reel = pv_reel
  )

  if (!is.null(pv_elia)) {
    monthly_df$pv_elia <- pv_elia
    monthly_agg <- stats::aggregate(cbind(pv_reel, pv_elia) ~ month, data = monthly_df, FUN = sum, na.rm = TRUE)
    monthly_agg <- monthly_agg[monthly_agg$pv_elia > 10, ]
    if (nrow(monthly_agg) < 3) {
      return(list(stable = TRUE, cv = NA_real_, msg = "Pas assez de mois avec PV Elia pour \u00e9valuer"))
    }
    ratios <- monthly_agg$pv_reel / monthly_agg$pv_elia
    cv <- stats::sd(ratios) / mean(ratios)
  } else {
    monthly_agg <- stats::aggregate(pv_reel ~ month, data = monthly_df, FUN = sum, na.rm = TRUE)
    monthly_agg <- monthly_agg[monthly_agg$pv_reel > 10, ]
    if (nrow(monthly_agg) < 3) {
      return(list(stable = TRUE, cv = NA_real_, msg = "Pas assez de mois pour \u00e9valuer"))
    }
    cv <- stats::sd(monthly_agg$pv_reel) / mean(monthly_agg$pv_reel)
  }

  stable <- cv < 0.3
  msg <- if (stable) {
    sprintf("PV stable (CV = %.0f%%)", cv * 100)
  } else {
    sprintf("PV instable (CV = %.0f%%) \u2014 mise en service progressive probable", cv * 100)
  }

  list(stable = stable, cv = cv, msg = msg)
}

#' Compute adaptive kWc from PV balance vs Elia profile
#'
#' Uses the robust rolling-median method (clear-sky days) as primary estimate.
#' Falls back to monthly ratio if not enough data for rolling median.
#' Returns both the smooth daily kWc curve and per-month summaries for the UI.
#'
#' @param pv_reel Numeric vector of reconstructed PV (kWh per timestep)
#' @param timestamps POSIXct vector (same length as pv_reel)
#' @param pv_elia_1kwc Numeric vector of Elia PV normalized to 1 kWc (kWh per timestep)
#' @return List with:
#'   - monthly: dataframe (month, pv_reel, pv_elia_1kwc, kwc_equiv)
#'   - kwc_current: numeric (stabilized kWc)
#'   - kwc_profile: named numeric vector (kWc per month, for adaptive scaling)
#'   - robust: output from estimate_kwc_robust() or NULL
#' @noRd
compute_adaptive_kwc <- function(pv_reel, timestamps, pv_elia_1kwc) {
  # Primary: robust rolling median on clear-sky days
  robust <- tryCatch(
    estimate_kwc_robust(pv_reel, timestamps, pv_elia_1kwc),
    error = function(e) NULL
  )

  # Monthly summary (always computed, for the chart)
  monthly_df <- data.frame(
    month = format(timestamps, "%Y-%m"),
    pv_reel = pv_reel,
    pv_elia_1kwc = pv_elia_1kwc
  )
  monthly_agg <- stats::aggregate(
    cbind(pv_reel, pv_elia_1kwc) ~ month,
    data = monthly_df, FUN = sum, na.rm = TRUE
  )
  monthly_agg <- monthly_agg[monthly_agg$pv_elia_1kwc > 0.5, ]

  if (nrow(monthly_agg) > 0) {
    monthly_agg$kwc_equiv <- monthly_agg$pv_reel / monthly_agg$pv_elia_1kwc
  } else {
    monthly_agg$kwc_equiv <- numeric(0)
  }

  # Use robust kWc if available, otherwise fallback to monthly median
  if (!is.null(robust) && !is.na(robust$kwc_current)) {
    kwc_current <- robust$kwc_current
    # Per-month profile from robust daily data (median per month)
    if (!is.null(robust$daily)) {
      daily_valid <- robust$daily[!is.na(robust$daily$kwc_rolling), ]
      if (nrow(daily_valid) > 0) {
        daily_valid$month <- format(daily_valid$date, "%Y-%m")
        month_from_robust <- stats::aggregate(
          kwc_rolling ~ month, data = daily_valid, FUN = stats::median, na.rm = TRUE
        )
        kwc_profile <- stats::setNames(month_from_robust$kwc_rolling, month_from_robust$month)
      } else {
        kwc_profile <- stats::setNames(monthly_agg$kwc_equiv, monthly_agg$month)
      }
    } else {
      kwc_profile <- stats::setNames(monthly_agg$kwc_equiv, monthly_agg$month)
    }
  } else {
    # Fallback: monthly ratio
    n <- nrow(monthly_agg)
    if (n > 0) {
      last_months <- utils::tail(monthly_agg, min(2, n))
      kwc_current <- stats::median(last_months$kwc_equiv)
      kwc_profile <- stats::setNames(monthly_agg$kwc_equiv, monthly_agg$month)
    } else {
      kwc_current <- NA_real_
      kwc_profile <- numeric(0)
    }
  }

  list(
    monthly = monthly_agg,
    kwc_current = kwc_current,
    kwc_profile = kwc_profile,
    robust = robust
  )
}

#' Scale Elia PV using adaptive monthly kWc
#'
#' Applies a per-month kWc factor to the Elia 1-kWc profile. Each timestep
#' gets the kWc of its month. This correctly handles installations where the
#' PV capacity changed over time (progressive commissioning).
#'
#' @param timestamps POSIXct vector
#' @param pv_elia_1kwc Numeric vector of Elia PV normalized to 1 kWc
#' @param kwc_profile Named numeric vector from compute_adaptive_kwc()$kwc_profile
#' @param kwc_fallback Numeric, kWc to use for months not in kwc_profile
#' @return Numeric vector of scaled PV (kWh per timestep)
#' @noRd
scale_pv_adaptive <- function(timestamps, pv_elia_1kwc, kwc_profile, kwc_fallback = NA_real_) {
  months <- format(timestamps, "%Y-%m")
  kwc_vec <- kwc_profile[months]

  # Use fallback for months without a computed kWc
  if (!is.na(kwc_fallback)) {
    kwc_vec[is.na(kwc_vec)] <- kwc_fallback
  } else {
    # Use the nearest known kWc (last known value)
    kwc_vec[is.na(kwc_vec)] <- utils::tail(kwc_profile[!is.na(kwc_profile)], 1)
  }

  pv_elia_1kwc * as.numeric(kwc_vec)
}

#' Estimate kWc using robust rolling median on clear-sky days
#'
#' For each day, computes the ratio PV_reel / PV_elia_1kwc. Only retains
#' "clear-sky days" (days where Elia production > monthly median) to avoid
#' noisy ratios on cloudy/low-production days. Then applies a rolling median
#' (30-day window) to produce a smooth, outlier-resistant kWc time series.
#'
#' This method is robust because:
#' - Clear-sky filter removes days where noise dominates the signal
#' - Daily aggregation smooths sub-hourly ORES spikes
#' - Rolling median is insensitive to individual outliers
#' - Elia normalizes seasonality (same latitude, same day length)
#'
#' @param pv_reel Numeric vector of reconstructed PV (kWh per timestep, 15 min)
#' @param timestamps POSIXct vector (same length as pv_reel)
#' @param pv_elia_1kwc Numeric vector of Elia PV at 1 kWc (kWh per timestep)
#' @param window_days Rolling median window size in days (default 30)
#' @return List with:
#'   - daily: dataframe (date, pv_reel_day, elia_day, ratio, is_clear, kwc_rolling)
#'   - kwc_current: numeric (last valid rolling median value)
#'   - kwc_ts: dataframe (timestamp, kwc) for each original timestep
#' @noRd
estimate_kwc_robust <- function(pv_reel, timestamps, pv_elia_1kwc, window_days = 30) {
  # Aggregate to daily
  daily_df <- data.frame(
    date = as.Date(timestamps),
    pv_reel = pv_reel,
    elia = pv_elia_1kwc
  )
  daily_agg <- stats::aggregate(
    cbind(pv_reel, elia) ~ date, data = daily_df, FUN = sum, na.rm = TRUE
  )

  # Compute daily ratio (only where Elia > 0)
  daily_agg$ratio <- ifelse(daily_agg$elia > 0.1, daily_agg$pv_reel / daily_agg$elia, NA_real_)

  # Clear-sky filter: keep only days where Elia > monthly median
  daily_agg$month <- format(daily_agg$date, "%Y-%m")
  monthly_medians <- stats::aggregate(elia ~ month, data = daily_agg, FUN = stats::median, na.rm = TRUE)
  names(monthly_medians)[2] <- "elia_median"
  daily_agg <- merge(daily_agg, monthly_medians, by = "month")
  daily_agg <- daily_agg[order(daily_agg$date), ]
  daily_agg$is_clear <- daily_agg$elia >= daily_agg$elia_median & !is.na(daily_agg$ratio)

  # Rolling median on clear-sky ratios
  n <- nrow(daily_agg)
  daily_agg$kwc_rolling <- NA_real_
  clear_ratios <- ifelse(daily_agg$is_clear, daily_agg$ratio, NA_real_)

  for (i in seq_len(n)) {
    window_start <- max(1, i - window_days + 1)
    window_vals <- clear_ratios[window_start:i]
    window_vals <- window_vals[!is.na(window_vals)]
    if (length(window_vals) >= 3) {
      daily_agg$kwc_rolling[i] <- stats::median(window_vals)
    }
  }

  # kWc current = last valid rolling value
  valid_rolling <- daily_agg$kwc_rolling[!is.na(daily_agg$kwc_rolling)]
  kwc_current <- if (length(valid_rolling) > 0) utils::tail(valid_rolling, 1) else NA_real_

  # Map back to original timestamps
  ts_dates <- as.Date(timestamps)
  kwc_by_date <- stats::setNames(daily_agg$kwc_rolling, as.character(daily_agg$date))
  kwc_ts <- as.numeric(kwc_by_date[as.character(ts_dates)])

  list(
    daily = daily_agg[, c("date", "pv_reel", "elia", "ratio", "is_clear", "kwc_rolling")],
    kwc_current = kwc_current,
    kwc_ts = data.frame(timestamp = timestamps, kwc = kwc_ts)
  )
}
