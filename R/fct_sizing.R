# =============================================================================
# Installation sizing functions
# =============================================================================
# Standalone functions for auto-sizing thermal storage (ballon) and PV.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Auto-size thermal storage volume
#'
#' Calculates the recommended tank volume to store 2 hours of heat pump
#' output within the temperature tolerance band.
#'
#' Formula: \code{V = P_PAC * COP * 2h / (2 * tolerance * 0.001163)},
#' rounded to the nearest 50 L.
#'
#' @param p_pac_kw Heat pump electrical power (kW)
#' @param cop_nominal Nominal COP at reference temperature
#' @param t_tolerance Temperature tolerance (degrees C). The usable
#'   temperature range is \code{2 * t_tolerance}.
#' @return Tank volume in litres (rounded to nearest 50 L)
#'
#' @examples
#' calculate_ballon_volume_auto(60, cop_nominal = 3.5, t_tolerance = 5)
#' # => 36400 L (simplified example)
#' @export
calculate_ballon_volume_auto <- function(p_pac_kw, cop_nominal, t_tolerance) {
  delta_t <- 2 * t_tolerance
  heures_stockage <- 2
  energie_kwh <- p_pac_kw * cop_nominal * heures_stockage
  vol <- energie_kwh / (delta_t * 0.001163)
  round(vol / 50) * 50
}

#' Auto-size PV installation
#'
#' Estimates the optimal PV capacity to cover annual heat pump electricity
#' consumption, based on an average Belgian yield of 950 kWh/kWc/year.
#'
#' Two sizing strategies depending on heat pump power:
#' \describe{
#'   \item{P_PAC <= 10 kW (domestic ECS)}{Sizes based on daily hot water
#'     demand + standing losses.}
#'   \item{P_PAC > 10 kW (collective/heating)}{Sizes based on 5 equivalent
#'     full-load hours per day.}
#' }
#'
#' @param p_pac_kw Heat pump electrical power (kW)
#' @param volume_ballon_l Tank volume in litres (used for ECS estimation)
#' @param cop_nominal Nominal COP
#' @param t_consigne Target tank temperature (degrees C, default 55)
#' @return PV capacity in kWc (rounded to nearest 0.5 kWc)
#'
#' @examples
#' calculate_pv_auto(60, volume_ballon_l = 2000, cop_nominal = 3.5)
#' @export
calculate_pv_auto <- function(p_pac_kw, volume_ballon_l, cop_nominal,
                              t_consigne = 55) {
  if (p_pac_kw <= 10) {
    pertes_jour_kwh <- 0.004 * (t_consigne - 20) * 24
    ecs_jour_kwh <- 6 * volume_ballon_l / 200
    conso_pac_an <- (ecs_jour_kwh + pertes_jour_kwh) / cop_nominal * 365
  } else {
    heq_jour <- 5
    conso_pac_an <- p_pac_kw * heq_jour * 365 / cop_nominal
  }
  kwc <- conso_pac_an / 950
  round(kwc * 2) / 2
}

#' Compute autoconsommation bounds for parametric baseline
#'
#' Runs two baseline simulations with alpha = 0 (no PV tracking) and
#' alpha = 1 (maximum PV tracking) to determine the achievable range
#' of self-consumption rates.
#'
#' @param df Raw data dataframe (as loaded from CSV or demo generator)
#' @param params Parameter list containing at least: t_consigne, t_tolerance,
#'   p_pac_kw, cop_nominal, volume_ballon_l, pv_kwc, pv_kwc_ref, dt_h,
#'   type_contrat, and price parameters
#' @return A list with \code{ac_floor} (minimum AC\%) and \code{ac_ceiling}
#'   (maximum AC\%) achievable by the parametric baseline
#'
#' @examples
#' \dontrun{
#' bounds <- compute_ac_bounds(df, params)
#' # bounds$ac_floor  => e.g. 25.3
#' # bounds$ac_ceiling => e.g. 68.7
#' }
#' @export
compute_ac_bounds <- function(df, params) {
  bounds <- list(ac_floor = 15, ac_ceiling = 70)
  tryCatch({
    for (a in c(0, 1)) {
      p_tmp <- params
      p_tmp$baseline_alpha <- a
      sim_tmp <- Simulation$new(p_tmp)
      sim_tmp$load_raw_dataframe(df)
      p_tmp <- sim_tmp$get_params()
      bl <- Baseline$new(ThermalModel$new(p_tmp))
      df_bl <- bl$run(sim_tmp$get_prepared_data(), p_tmp, mode = "pv_tracking")
      pv_total <- sum(df_bl$pv_kwh, na.rm = TRUE)
      inj <- sum(df_bl$intake_kwh, na.rm = TRUE)
      ac <- if (pv_total > 0) (1 - inj / pv_total) * 100 else 0
      if (a == 0) bounds$ac_floor <- round(ac, 1)
      if (a == 1) bounds$ac_ceiling <- round(ac, 1)
    }
    if (bounds$ac_floor > bounds$ac_ceiling) {
      tmp <- bounds$ac_floor
      bounds$ac_floor <- bounds$ac_ceiling
      bounds$ac_ceiling <- tmp
    }
  }, error = function(e) {
    message("[AC bounds] Error: ", e$message)
  })
  bounds
}
