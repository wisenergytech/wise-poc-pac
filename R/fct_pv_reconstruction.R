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
#' For each month, computes the equivalent kWc by dividing the reconstructed
#' PV total by the Elia 1-kWc profile total. This gives the effective installed
#' capacity per month, handling progressive commissioning.
#'
#' @param pv_reel Numeric vector of reconstructed PV (kWh per timestep)
#' @param timestamps POSIXct vector (same length as pv_reel)
#' @param pv_elia_1kwc Numeric vector of Elia PV normalized to 1 kWc (kWh per timestep)
#' @return List with:
#'   - monthly: dataframe (month, pv_reel, pv_elia_1kwc, kwc_equiv)
#'   - kwc_current: numeric (stabilized kWc from last 2 complete months)
#'   - kwc_profile: named numeric vector (kWc per month, for adaptive scaling)
#' @noRd
compute_adaptive_kwc <- function(pv_reel, timestamps, pv_elia_1kwc) {
  monthly_df <- data.frame(
    month = format(timestamps, "%Y-%m"),
    pv_reel = pv_reel,
    pv_elia_1kwc = pv_elia_1kwc
  )

  monthly_agg <- stats::aggregate(
    cbind(pv_reel, pv_elia_1kwc) ~ month,
    data = monthly_df, FUN = sum, na.rm = TRUE
  )

  # Exclude months with negligible Elia production (avoid division by ~0)
  monthly_agg <- monthly_agg[monthly_agg$pv_elia_1kwc > 0.5, ]

  if (nrow(monthly_agg) == 0) {
    return(list(
      monthly = data.frame(month = character(0), pv_reel = numeric(0),
        pv_elia_1kwc = numeric(0), kwc_equiv = numeric(0)),
      kwc_current = NA_real_,
      kwc_profile = numeric(0)
    ))
  }

  monthly_agg$kwc_equiv <- monthly_agg$pv_reel / monthly_agg$pv_elia_1kwc

  # Stabilized kWc = median of last 2 complete months (most recent = full capacity)
  n <- nrow(monthly_agg)
  last_months <- utils::tail(monthly_agg, min(2, n))
  kwc_current <- stats::median(last_months$kwc_equiv)

  # Named profile for adaptive scaling
  kwc_profile <- stats::setNames(monthly_agg$kwc_equiv, monthly_agg$month)

  list(
    monthly = monthly_agg,
    kwc_current = kwc_current,
    kwc_profile = kwc_profile
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
