# =============================================================================
# Energy domain functions
# =============================================================================
# Standalone functions for energy data preparation and flow analysis.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Prepare energy time-series for baseline vs optimised comparison
#'
#' Aggregates simulation data (via [auto_aggregate()]) and computes derived
#' columns for soutirage, injection, autoconsommation, and autosuffisance,
#' both baseline and optimised.
#'
#' @param sim Simulation dataframe with columns: \code{timestamp},
#'   \code{offtake_kwh}, \code{sim_offtake}, \code{intake_kwh},
#'   \code{sim_intake}, \code{pv_kwh}
#' @return A list with:
#'   \describe{
#'     \item{data}{Aggregated dataframe with derived comparison columns}
#'     \item{label}{Display label for the aggregation level (e.g. "Horaire")}
#'   }
#' @export
prepare_energy_timeseries <- function(sim) {
  agg <- auto_aggregate(sim)
  d <- agg$data %>% dplyr::mutate(
    soutirage_baseline = offtake_kwh,
    soutirage_opti = sim_offtake,
    injection_baseline = intake_kwh,
    injection_opti = sim_intake,
    autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
    autoconso_opti = pmax(0, pv_kwh - sim_intake),
    conso_tot_baseline = offtake_kwh + pmax(0, pv_kwh - intake_kwh),
    conso_tot_opti = sim_offtake + pmax(0, pv_kwh - sim_intake),
    autosuff_baseline = dplyr::if_else(conso_tot_baseline > 0,
      pmax(0, pv_kwh - intake_kwh) / conso_tot_baseline * 100, 0),
    autosuff_opti = dplyr::if_else(conso_tot_opti > 0,
      pmax(0, pv_kwh - sim_intake) / conso_tot_opti * 100, 0)
  )
  list(data = d, label = agg$label, level = agg$level)
}

#' Compute Sankey energy flow data
#'
#' Calculates the energy flows between PV, grid, heat pump, residual
#' consumption, and injection nodes for a given scenario (baseline or
#' optimised).
#'
#' @param sim Simulation dataframe with columns: \code{pv_kwh},
#'   \code{offtake_kwh}, \code{intake_kwh}, \code{sim_offtake},
#'   \code{sim_intake}, \code{sim_pac_on}
#' @param scenario Character. \code{"baseline"} or \code{"optimise"}
#' @return A named list with:
#'   \describe{
#'     \item{nodes}{List of node labels, values (kWh), and colors}
#'     \item{links}{List of source, target, value, and color vectors
#'       (zero-value links already filtered out)}
#'   }
#' @export
compute_sankey_flows <- function(sim, scenario = "baseline") {
  is_opti <- scenario == "optimise"

  pv_tot <- sum(sim$pv_kwh, na.rm = TRUE)
  if (is_opti) {
    inj <- sum(sim$sim_intake, na.rm = TRUE)
    off <- sum(sim$sim_offtake, na.rm = TRUE)
  } else {
    inj <- sum(sim$intake_kwh, na.rm = TRUE)
    off <- sum(sim$offtake_kwh, na.rm = TRUE)
  }
  pv_auto <- pv_tot - inj
  pac_elec <- if (is_opti) {
    sum(sim$sim_pac_on * 0.5, na.rm = TRUE)
  } else {
    sum((sim$offtake_kwh > 0.4) * 0.5, na.rm = TRUE)
  }
  maison <- max(0, pv_auto + off - pac_elec)

  node_labels <- c("PV", "Reseau", "PAC", "Conso residuelle", "Injection")
  node_values <- c(round(pv_tot), round(off), round(pac_elec),
                   round(maison), round(inj))

  link_source <- c(0, 0, 0, 1, 1)
  link_target <- c(2, 3, 4, 2, 3)
  link_value <- c(
    min(pv_auto, pac_elec),
    max(0, pv_auto - pac_elec),
    inj,
    max(0, pac_elec - pv_auto),
    max(0, off - max(0, pac_elec - pv_auto))
  )
  link_color <- c(
    "rgba(245,158,11,0.4)", "rgba(245,158,11,0.2)",
    "rgba(217,119,6,0.4)", "rgba(220,38,38,0.4)",
    "rgba(220,38,38,0.2)"
  )

  # Filter out negligible flows

mask <- link_value > 0.5
  list(
    nodes = list(
      label = node_labels,
      value = node_values
    ),
    links = list(
      source = link_source[mask],
      target = link_target[mask],
      value = round(link_value[mask]),
      color = link_color[mask]
    )
  )
}
