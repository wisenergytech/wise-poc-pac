# =============================================================================
# Finance domain functions
# =============================================================================
# Standalone functions for financial data preparation and analysis.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

# Monthly weights for Belgian climate (normalized to sum = 1.0)
#
# Heating degree-days: Synergrid normales 30 ans (1996-2025), DJ 16.5 C
# Source: https://www.synergrid.be/fr/centre-de-documentation/statistiques-et-donnees/degres-jours
# Raw DJ: Jan=396, Feb=335, Mar=290, Apr=185, May=95, Jun=28, Jul=10, Aug=9, Sep=51, Oct=148, Nov=272, Dec=367
# Total = 2186
.monthly_dj <- c(
  Jan = 396, Feb = 335, Mar = 290, Apr = 185, May = 95, Jun = 28,
  Jul = 10, Aug = 9, Sep = 51, Oct = 148, Nov = 272, Dec = 367
)
.monthly_heating_weight <- .monthly_dj / sum(.monthly_dj)

# Solar irradiation: PVGIS-SARAH3, Namur (50.47N, 4.87E), horizontal plane
# Source: https://re.jrc.ec.europa.eu/api/v5_3/MRcalc (year 2020)
# Raw kWh/m2/month: Jan=27.73, Feb=39.75, Mar=93.83, Apr=158.79, May=195.32, Jun=162.61,
#   Jul=159.46, Aug=146.77, Sep=112.31, Oct=48.98, Nov=36.10, Dec=20.34
# Total = 1201.99
.monthly_pv_weight <- c(
  Jan = 27.73, Feb = 39.75, Mar = 93.83, Apr = 158.79, May = 195.32, Jun = 162.61,
  Jul = 159.46, Aug = 146.77, Sep = 112.31, Oct = 48.98, Nov = 36.10, Dec = 20.34
) / 1201.99

#' Compute monthly COP and price spread profiles from historical data
#'
#' Loads local BELPEX prices and Open-Meteo temperatures (2024-2026) to build
#' monthly average COP and price spread for each calendar month. Used by
#' \code{project_annual_kpis()} to weight seasonal corrections.
#'
#' @param cop_nominal Nominal COP at reference temperature (default 3.5)
#' @param t_ref Reference external temperature for nominal COP (default 7)
#' @param data_dir Directory containing CSV data files
#' @return Named list with \code{cop} (named numeric, 12 months) and
#'   \code{spread} (named numeric, 12 months, EUR/MWh interquartile spread)
#' @keywords internal
.compute_monthly_profiles <- function(cop_nominal = 3.5, t_ref = 7,
                                      data_dir = "data") {
  month_names <- names(.monthly_dj)

  # --- Temperature -> COP per month ---
  temp_files <- list.files(data_dir, pattern = "openmeteo_temperature_.*\\.csv$",
                           full.names = TRUE)
  if (length(temp_files) > 0) {
    temp_df <- do.call(rbind, lapply(temp_files, function(f) {
      d <- utils::read.csv(f, stringsAsFactors = FALSE)
      d$timestamp <- as.POSIXct(d$timestamp, tz = "UTC")
      d
    }))
    temp_df$month <- format(temp_df$timestamp, "%b")
    monthly_t <- tapply(temp_df$t_ext, temp_df$month, mean, na.rm = TRUE)
    cop_monthly <- calc_cop(as.numeric(monthly_t[month_names]),
                            cop_nominal, t_ref)
    names(cop_monthly) <- month_names
  } else {
    cop_monthly <- rep(cop_nominal, 12)
    names(cop_monthly) <- month_names
  }

  # --- Prices -> spread per month (IQR of hourly prices) ---
  price_files <- list.files(data_dir, pattern = "entsoe_prices_.*\\.csv$",
                            full.names = TRUE)
  if (length(price_files) > 0) {
    price_df <- do.call(rbind, lapply(price_files, function(f) {
      d <- utils::read.csv(f, stringsAsFactors = FALSE)
      names(d) <- c("datetime", "price_eur_mwh")
      d$datetime <- as.POSIXct(gsub("Z$", "", d$datetime), tz = "UTC")
      d
    }))
    price_df$month <- format(price_df$datetime, "%b")
    # Spread = IQR (Q75 - Q25) of daily prices, averaged per month
    # This captures the room for ToU arbitrage
    spread_monthly <- tapply(price_df$price_eur_mwh, price_df$month,
                             function(x) {
                               q <- quantile(x, c(0.25, 0.75), na.rm = TRUE)
                               q[2] - q[1]
                             })
    spread_monthly <- as.numeric(spread_monthly[month_names])
    names(spread_monthly) <- month_names
  } else {
    spread_monthly <- rep(1, 12)
    names(spread_monthly) <- month_names
  }

  list(cop = cop_monthly, spread = spread_monthly)
}

#' Project KPIs to a full year using seasonal weights
#'
#' Takes KPIs computed over a partial year (e.g. Nov-Apr) and projects them
#' to a full 12-month cycle using heating degree-days, COP seasonality
#' (from historical temperatures), and price spread seasonality (from
#' historical BELPEX prices).
#'
#' @param kpis Named list from KPICalculator$compute()
#' @param sim_data Simulation dataframe with \code{timestamp} column
#' @param cop_nominal Nominal COP at reference temperature (default 3.5)
#' @param t_ref Reference external temperature for nominal COP (default 7)
#' @param data_dir Directory for historical CSV data (default "data")
#' @return Named list with projected annual KPIs
#' @export
project_annual_kpis <- function(kpis, sim_data, cop_nominal = 3.5, t_ref = 7,
                                data_dir = "data") {
  # Identify which months are covered by simulation data
  months_covered <- unique(format(sim_data$timestamp, "%b"))
  month_names <- names(.monthly_dj)
  month_indices <- match(months_covered, month_names)
  month_indices <- month_indices[!is.na(month_indices)]
  unmeasured_indices <- setdiff(seq_len(12), month_indices)

  # DJ weights
  dj_measured <- sum(.monthly_dj[month_indices])
  dj_total <- sum(.monthly_dj)

  # PV weights (unchanged — irradiation-based)
  pv_measured <- sum(.monthly_pv_weight[month_indices])
  pv_total_weight <- sum(.monthly_pv_weight)
  pv_scale <- pv_total_weight / pv_measured

  # --- Load monthly COP and spread profiles from historical data ---
  profiles <- .compute_monthly_profiles(cop_nominal, t_ref, data_dir)
  cop_m <- profiles$cop      # COP by month (12 values)
  spread_m <- profiles$spread # price spread by month (12 values)

  # --- Measured-period averages (DJ-weighted) ---
  cop_measured_avg <- weighted.mean(cop_m[month_indices],
                                    .monthly_dj[month_indices])
  spread_measured_avg <- weighted.mean(spread_m[month_indices],
                                       .monthly_dj[month_indices])

  # --- Baseline projection with COP correction ---
  # Electricity cost per DJ is proportional to 1/COP: higher COP = less kWh
  # For each unmeasured month: contribution = DJ_m * (COP_measured / COP_m)
  # relative to measured where cost_per_DJ already embeds measured COP
  if (length(unmeasured_indices) > 0) {
    # Effective DJ for unmeasured months (COP-corrected)
    dj_unmeasured_eff <- sum(
      .monthly_dj[unmeasured_indices] * cop_measured_avg / cop_m[unmeasured_indices]
    )
  } else {
    dj_unmeasured_eff <- 0
  }
  baseline_scale <- (dj_measured + dj_unmeasured_eff) / dj_measured

  facture_baseline_an <- round(kpis$facture_baseline * baseline_scale)

  # --- Gain projection with COP + spread correction ---
  # ToU gain per month proportional to: DJ_m / COP_m * spread_m
  # (volume to shift × price differential)
  gain_weight_measured <- sum(
    .monthly_dj[month_indices] / cop_m[month_indices] * spread_m[month_indices]
  )

  if (length(unmeasured_indices) > 0) {
    gain_weight_unmeasured <- sum(
      .monthly_dj[unmeasured_indices] / cop_m[unmeasured_indices] *
        spread_m[unmeasured_indices]
    )
  } else {
    gain_weight_unmeasured <- 0
  }
  gain_scale <- (gain_weight_measured + gain_weight_unmeasured) /
    gain_weight_measured

  gain_measured <- kpis$facture_baseline - kpis$facture_opti
  gain_eur_an <- round(gain_measured * gain_scale)
  facture_opti_an <- facture_baseline_an - gain_eur_an

  gain_pct_an <- if (facture_baseline_an > 0) {
    round(gain_eur_an / facture_baseline_an * 100)
  } else 0

  # PV projection: scale by solar irradiation (unchanged)
  pv_total_an <- round(kpis$pv_total * pv_scale)

  # Self-consumption: in summer more PV but less demand -> ratio changes
  heat_summer <- 1 - sum(.monthly_heating_weight[month_indices])
  ac_summer_estimate <- max(20, kpis$ac_opti * 0.5)
  ac_opti_an <- round(
    (kpis$ac_opti * sum(.monthly_heating_weight[month_indices]) +
       ac_summer_estimate * heat_summer), 1
  )

  # CO2 projection (COP-corrected like baseline)
  co2_saved_an_kg <- if (!is.null(kpis$co2_saved_kg)) {
    round(kpis$co2_saved_kg * baseline_scale)
  } else 0

  list(
    measured_months = months_covered,
    n_months_measured = length(month_indices),
    heat_coverage_pct = round(dj_measured / dj_total * 100),
    facture_baseline_an = facture_baseline_an,
    facture_opti_an = facture_opti_an,
    gain_eur_an = gain_eur_an,
    gain_pct_an = gain_pct_an,
    pv_total_an = pv_total_an,
    ac_opti_an = ac_opti_an,
    co2_saved_an_kg = co2_saved_an_kg
  )
}

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
