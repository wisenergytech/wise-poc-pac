#' Energy perimeter diagnostic for CSV data
#'
#' Validates the coherence between pac_kwh (Elec_consumption from BQ) and
#' ORES meter data (offtake/injection). Returns a character vector of HTML
#' diagnostic lines for display in the import report.
#'
#' @param df Data frame with columns: timestamp, pac_kwh, offtake_kwh,
#'   intake_kwh, pv_kwh. Optionally: cop.
#' @return Character vector of HTML diagnostic lines (empty if pac_kwh absent).
#' @noRd
diagnose_energy_perimeter <- function(df) {
  # Use elec_kwh (total installation) if available, otherwise pac_kwh (legacy)
  elec_col <- if ("elec_kwh" %in% names(df)) "elec_kwh" else if ("pac_kwh" %in% names(df)) "pac_kwh" else NULL
  if (is.null(elec_col)) return(character(0))

  # Temporarily set pac_kwh to the total installation column for sub-functions
  if (elec_col != "pac_kwh") df[["pac_kwh"]] <- df[[elec_col]]

  lines <- character(0)
  hour_col <- as.integer(format(df$timestamp, "%H"))

  perim <- diagnose_nighttime_perimeter(df, hour_col)
  if (!is.null(perim)) lines <- c(lines, perim)

  autocons <- diagnose_pv_selfconsumption(df)
  if (!is.null(autocons)) lines <- c(lines, autocons)

  pac_power <- diagnose_pac_power(df)
  if (!is.null(pac_power)) lines <- c(lines, pac_power)

  n_jours <- as.numeric(difftime(max(df$timestamp), min(df$timestamp), units = "days"))
  pv_stab <- diagnose_pv_stability(df, n_jours)
  if (!is.null(pv_stab)) lines <- c(lines, pv_stab)

  lines
}

#' Nighttime coherence check
#'
#' At night (22h-5h) with no PV, the energy balance must hold:
#' pac_kwh = offtake - feedin. Deviations indicate different metering perimeters.
#'
#' @param df Data frame with pac_kwh, offtake_kwh, intake_kwh columns.
#' @param hour_col Integer vector of hours (0-23).
#' @return Single HTML string or NULL.
#' @noRd
diagnose_nighttime_perimeter <- function(df, hour_col) {
  is_night <- hour_col >= 22 | hour_col <= 5
  if (sum(is_night) < 50) return(NULL)

  ecart <- df[["pac_kwh"]][is_night] - df[["offtake_kwh"]][is_night] + df[["intake_kwh"]][is_night]
  median_ecart <- stats::median(ecart, na.rm = TRUE)
  pct_gt01 <- 100 * sum(abs(ecart) > 0.1, na.rm = TRUE) / sum(is_night)

  if (abs(median_ecart) < 0.05 && pct_gt01 < 5) {
    "&#9989; <b>P\u00e9rim\u00e8tre</b> : pac_kwh \u2248 offtake \u2212 injection la nuit &rarr; m\u00eame compteur confirm\u00e9"
  } else {
    sprintf(
      "&#9888; <b>P\u00e9rim\u00e8tre</b> : \u00e9cart nocturne m\u00e9dian = %.3f kWh, %.1f%% des pas &gt; 0.1 kWh &rarr; p\u00e9rim\u00e8tres potentiellement diff\u00e9rents",
      median_ecart, pct_gt01)
  }
}

#' PV self-consumption diagnostic
#'
#' Computes the real PV by energy balance and checks how much is self-consumed
#' vs injected. Near-zero self-consumption indicates the PV and the metered
#' installation are on separate circuits.
#'
#' @param df Data frame with pac_kwh, offtake_kwh, intake_kwh columns.
#' @return Single HTML string or NULL.
#' @noRd
diagnose_pv_selfconsumption <- function(df) {
  pv_reel <- pmax(0, df[["pac_kwh"]] - df[["offtake_kwh"]] + df[["intake_kwh"]])
  pv_reel_total <- sum(pv_reel, na.rm = TRUE)
  if (pv_reel_total <= 10) return(NULL)

  feedin_total <- sum(df[["intake_kwh"]], na.rm = TRUE)
  taux_autocons <- (pv_reel_total - feedin_total) / pv_reel_total

  if (taux_autocons < 0.05) {
    sprintf(
      "&#9888; <b>Autoconsommation PV</b> : %.1f%% &rarr; le PV est quasi int\u00e9gralement inject\u00e9 (circuits s\u00e9par\u00e9s ou pas d'autocons.)",
      taux_autocons * 100)
  } else {
    sprintf(
      "&#9989; <b>Autoconsommation PV</b> : %.1f%% (PV alimente partiellement l'installation)",
      taux_autocons * 100)
  }
}

#' PAC power sanity check via COP
#'
#' Uses COP > 0 as a PAC-active indicator to separate PAC consumption from
#' the installation baseline (talon). Reports P95 power and talon wattage.
#'
#' @param df Data frame with pac_kwh and cop columns.
#' @return Single HTML string or NULL.
#' @noRd
diagnose_pac_power <- function(df) {
  if (!"cop" %in% names(df)) return(NULL)
  if (!any(!is.na(df$cop) & df$cop > 0)) return(NULL)

  pac_off_mask <- !is.na(df$cop) & df$cop == 0
  pac_on_mask <- !is.na(df$cop) & df$cop > 0 & df$cop < 7
  if (sum(pac_off_mask) < 20 || sum(pac_on_mask) < 20) return(NULL)

  talon_median <- stats::median(df[["pac_kwh"]][pac_off_mask], na.rm = TRUE)
  pac_pure <- pmax(0, df[["pac_kwh"]][pac_on_mask] - talon_median)
  p_max_kw <- stats::quantile(pac_pure, 0.95, na.rm = TRUE) * 4

  sprintf(
    "&#128268; <b>Puissance PAC</b> (P95 via COP) : %.1f kW | Talon installation : %.0f W",
    p_max_kw, talon_median * 4000)
}

#' PV stability check (progressive commissioning detection)
#'
#' Computes the monthly ratio of real PV (from energy balance) to estimated PV
#' (e.g. Elia-scaled). A high coefficient of variation indicates that the PV
#' capacity changed over time (progressive commissioning), making a fixed
#' scaling factor unreliable.
#'
#' @param df Data frame with timestamp, pac_kwh, offtake_kwh, intake_kwh, pv_kwh.
#' @param n_jours Numeric, number of days covered.
#' @return Single HTML string or NULL.
#' @noRd
diagnose_pv_stability <- function(df, n_jours) {
  if (n_jours <= 60) return(NULL)

  pv_reel <- pmax(0, df[["pac_kwh"]] - df[["offtake_kwh"]] + df[["intake_kwh"]])
  monthly_df <- data.frame(
    month = format(df$timestamp, "%Y-%m"),
    pv_reel = pv_reel,
    pv_kwh = df[["pv_kwh"]]
  )
  monthly_agg <- stats::aggregate(
    cbind(pv_reel, pv_kwh) ~ month, data = monthly_df, FUN = sum, na.rm = TRUE
  )
  monthly_agg <- monthly_agg[monthly_agg$pv_kwh > 10, ]
  if (nrow(monthly_agg) < 3) return(NULL)

  ratios <- monthly_agg$pv_reel / monthly_agg$pv_kwh
  cv_ratio <- stats::sd(ratios) / mean(ratios)

  if (cv_ratio > 0.3) {
    sprintf(
      "&#9888; <b>PV instable</b> : ratio PV r\u00e9el/estim\u00e9 varie de %.2f \u00e0 %.2f (CV=%.0f%%) &rarr; mise en service progressive probable, scaling fixe non applicable",
      min(ratios), max(ratios), cv_ratio * 100)
  } else {
    sprintf(
      "&#9989; <b>PV stable</b> : ratio PV r\u00e9el/estim\u00e9 \u2248 %.2f (CV=%.0f%%) &rarr; scaling fiable",
      mean(ratios), cv_ratio * 100)
  }
}
