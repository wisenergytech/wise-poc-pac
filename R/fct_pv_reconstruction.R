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
