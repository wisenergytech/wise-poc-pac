# =============================================================================
# Finance domain functions
# =============================================================================
# Standalone functions for financial data preparation and analysis.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Compute cumulative bill time-series
#'
#' Calculates per-timestep net bill (offtake cost minus injection revenue)
#' and its cumulative sum, for both baseline and optimised scenarios.
#' Result is downsampled to hourly resolution to reduce plot density.
#'
#' @param sim Simulation dataframe with columns: \code{timestamp},
#'   \code{offtake_kwh}, \code{intake_kwh}, \code{sim_offtake},
#'   \code{sim_intake}, \code{prix_offtake}, \code{prix_injection}
#' @param sim_opti Optional second simulation dataframe for cross-contract
#'   comparison. When provided, baseline is taken from \code{sim} and
#'   optimised from \code{sim_opti}.
#' @return A dataframe with columns: \code{timestamp}, \code{cum_baseline},
#'   \code{cum_opti}
#' @export
compute_cumulative_bill <- function(sim, sim_opti = NULL) {
  baseline_qt <- sim$offtake_kwh * sim$prix_offtake -
    sim$intake_kwh * sim$prix_injection

  if (!is.null(sim_opti)) {
    opti_qt <- sim_opti$sim_offtake * sim_opti$prix_offtake -
      sim_opti$sim_intake * sim_opti$prix_injection
  } else {
    opti_qt <- sim$sim_offtake * sim$prix_offtake -
      sim$sim_intake * sim$prix_injection
  }

  d <- data.frame(
    timestamp = sim$timestamp,
    cum_baseline = cumsum(ifelse(is.na(baseline_qt), 0, baseline_qt)),
    cum_opti = cumsum(ifelse(is.na(opti_qt), 0, opti_qt))
  )

  # Downsample to hourly for plotting
  d %>%
    dplyr::mutate(.h = lubridate::floor_date(timestamp, "hour")) %>%
    dplyr::group_by(.h) %>%
    dplyr::slice_tail(n = 1) %>%
    dplyr::ungroup() %>%
    dplyr::select(timestamp, cum_baseline, cum_opti)
}

#' Compute waterfall savings decomposition
#'
#' Builds a waterfall from the real (non-optimised) bill down to the
#' optimised bill, decomposing the difference into offtake reduction,
#' injection loss, and hourly arbitrage.
#'
#' @param sim Simulation dataframe with columns: \code{offtake_kwh},
#'   \code{sim_offtake}, \code{intake_kwh}, \code{sim_intake},
#'   \code{prix_offtake}, \code{prix_injection}
#' @return A dataframe with columns: \code{label}, \code{value} (EUR),
#'   \code{measure} ("absolute", "relative", or "total")
#' @export
compute_waterfall <- function(sim) {
  moins_soutirage_kwh <- sum(sim$offtake_kwh, na.rm = TRUE) -
    sum(sim$sim_offtake, na.rm = TRUE)
  moins_injection_kwh <- sum(sim$intake_kwh, na.rm = TRUE) -
    sum(sim$sim_intake, na.rm = TRUE)
  prix_moy_offt <- mean(sim$prix_offtake, na.rm = TRUE)
  prix_moy_inj <- mean(sim$prix_injection, na.rm = TRUE)

  eco_soutirage <- moins_soutirage_kwh * prix_moy_offt
  perte_injection <- moins_injection_kwh * prix_moy_inj

  facture_reel <- sum(sim$offtake_kwh * sim$prix_offtake, na.rm = TRUE) -
    sum(sim$intake_kwh * sim$prix_injection, na.rm = TRUE)
  facture_opti <- sum(sim$sim_offtake * sim$prix_offtake, na.rm = TRUE) -
    sum(sim$sim_intake * sim$prix_injection, na.rm = TRUE)
  eco_totale <- facture_reel - facture_opti
  eco_arbitrage <- eco_totale - eco_soutirage + perte_injection

  data.frame(
    label = c("Facture reelle", "Moins de soutirage",
              "Moins d'injection", "Arbitrage horaire",
              "Facture optimisee"),
    value = c(facture_reel, -eco_soutirage, perte_injection,
              -eco_arbitrage, facture_opti),
    measure = c("absolute", "relative", "relative", "relative", "total"),
    detail = c(
      "Cout net sans optimisation (soutirage - injection)",
      paste0(round(moins_soutirage_kwh, 1), " kWh evites a ",
             round(prix_moy_offt * 100, 1), " c/kWh"),
      paste0(round(moins_injection_kwh, 1), " kWh non-injectes a ",
             round(prix_moy_inj * 100, 1), " c/kWh"),
      "Gain du decalage vers les heures moins cheres",
      paste0("Economie totale: ", round(eco_totale, 1), " EUR (",
             round(eco_totale / facture_reel * 100, 1), "%)")
    ),
    stringsAsFactors = FALSE
  )
}

#' Compute monthly billing summary
#'
#' Aggregates simulation data by month, computing PV production, baseline
#' and optimised bills, savings, and daily savings rate.
#'
#' @param sim Simulation dataframe with columns: \code{timestamp},
#'   \code{pv_kwh}, \code{offtake_kwh}, \code{intake_kwh},
#'   \code{sim_offtake}, \code{sim_intake}, \code{prix_offtake},
#'   \code{prix_injection}
#' @param sim_opti Optional second simulation dataframe for cross-contract
#'   comparison. When provided, baseline is taken from \code{sim} (current
#'   contract) and optimised from \code{sim_opti} (target contract).
#' @return A dataframe with columns: \code{Mois}, \code{PV},
#'   \code{Facture actuelle} or \code{Facture baseline},
#'   \code{Facture optimisee} or \code{Facture opti},
#'   \code{Economie}, \code{EUR/j}
#' @export
compute_monthly_summary <- function(sim, sim_opti = NULL) {
  cross <- !is.null(sim_opti)

  baseline_qt <- sim$offtake_kwh * sim$prix_offtake -
    sim$intake_kwh * sim$prix_injection

  if (cross) {
    opti_qt <- sim_opti$sim_offtake * sim_opti$prix_offtake -
      sim_opti$sim_intake * sim_opti$prix_injection
  } else {
    opti_qt <- sim$sim_offtake * sim$prix_offtake -
      sim$sim_intake * sim$prix_injection
  }

  df <- data.frame(
    timestamp = sim$timestamp,
    pv_kwh = sim$pv_kwh,
    baseline_qt = baseline_qt,
    opti_qt = opti_qt
  )

  col_bl <- if (cross) "Facture actuelle" else "Facture baseline"
  col_op <- if (cross) "Facture optimisee" else "Facture opti"

  df %>%
    dplyr::mutate(mois = lubridate::floor_date(timestamp, "month")) %>%
    dplyr::group_by(mois) %>%
    dplyr::summarise(
      PV = round(sum(pv_kwh, na.rm = TRUE)),
      bl = round(sum(baseline_qt, na.rm = TRUE)),
      op = round(sum(opti_qt, na.rm = TRUE)),
      .groups = "drop"
    ) %>%
    dplyr::mutate(
      Mois = format(mois, "%b %Y"),
      Economie = bl - op,
      `EUR/j` = round(Economie / lubridate::days_in_month(mois), 2)
    ) %>%
    dplyr::rename(!!col_bl := bl, !!col_op := op) %>%
    dplyr::select(Mois, PV, dplyr::all_of(col_bl), dplyr::all_of(col_op),
                  Economie, `EUR/j`)
}
