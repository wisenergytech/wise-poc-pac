# =============================================================================
# Grid search / scenario analysis functions
# =============================================================================
# Standalone functions for running parameter sweeps and scenario comparisons.
# No Shiny dependency — usable in scripts, reports, and tests.
# =============================================================================

#' Run a single simulation scenario
#'
#' Executes a full baseline + optimisation cycle for one parameter set and
#' returns summary KPIs. Used as the building block for [run_grid_search()].
#'
#' @param df Raw data dataframe
#' @param params Parameter list for this scenario
#' @param mode Optimisation mode: \code{"smart"}, \code{"milp"}, \code{"lp"},
#'   or \code{"qp"}
#' @param baseline_mode Baseline mode (default \code{"parametric"})
#' @return A single-row tibble with columns: \code{Cout_EUR},
#'   \code{Autoconso_pct}, \code{Injection_kWh}, \code{Soutirage_kWh},
#'   or \code{NULL} on failure
#' @export
run_scenario <- function(df, params, mode = "smart",
                         baseline_mode = "thermostat") {
  sim_obj <- Simulation$new(params)
  sim_obj$load_raw_dataframe(df)
  sim_obj$run_baseline(mode = baseline_mode)
  sim_obj$run_optimization(mode)
  sim <- sim_obj$get_results()

  pv_tot  <- sum(sim$pv_kwh, na.rm = TRUE)
  inj_tot <- sum(sim$sim_intake, na.rm = TRUE)
  off_tot <- sum(sim$sim_offtake, na.rm = TRUE)
  cout_net <- sum(sim$sim_offtake * sim$prix_offtake -
                  sim$sim_intake * sim$prix_injection, na.rm = TRUE)
  autoconso <- if (pv_tot > 0) (1 - inj_tot / pv_tot) * 100 else 0

  tibble::tibble(
    Cout_EUR = round(cout_net),
    Autoconso_pct = round(autoconso, 1),
    Injection_kWh = round(inj_tot),
    Soutirage_kWh = round(off_tot)
  )
}

#' Run grid search over PV, battery, mode, and contract combinations
#'
#' Sweeps over all combinations of PV capacity, battery size, optimisation
#' mode, and contract type, running a full simulation for each. Returns
#' results sorted by ascending net cost.
#'
#' @param df Raw data dataframe
#' @param params Base parameter list (PV, battery, etc. will be overridden
#'   per scenario)
#' @param pv_range Numeric vector of PV capacities to test (kWc)
#' @param batt_range Numeric vector of battery capacities to test (kWh)
#' @param modes Character vector of optimisation modes. Use sidebar names:
#'   \code{"smart"}, \code{"optimizer"}, \code{"optimizer_lp"},
#'   \code{"optimizer_qp"}
#' @param contrats Character vector of contract types: \code{"fixe"},
#'   \code{"dynamique"}
#' @param baseline_mode Baseline mode (default \code{"parametric"})
#' @param progress_fn Optional callback \code{function(k, total, detail)}
#'   for progress reporting (e.g. Shiny progress bar). Default \code{NULL}.
#' @return A tibble with columns: \code{PV_kWc}, \code{Batterie_kWh},
#'   \code{Mode}, \code{Contrat}, \code{Cout_EUR}, \code{Autoconso_pct},
#'   \code{Injection_kWh}, \code{Soutirage_kWh}, sorted by \code{Cout_EUR}
#'
#' @examples
#' \dontrun{
#' results <- run_grid_search(
#'   df, params,
#'   pv_range = seq(5, 15, by = 2),
#'   batt_range = c(0, 10),
#'   modes = c("smart", "optimizer"),
#'   contrats = "dynamique"
#' )
#' head(results)
#' }
#' @export
run_grid_search <- function(df, params,
                            pv_range, batt_range,
                            modes = c("smart", "optimizer", "optimizer_lp",
                                      "optimizer_qp"),
                            contrats = c("fixe", "dynamique"),
                            baseline_mode = "thermostat",
                            progress_fn = NULL) {

  # Map sidebar mode names to R6 optimizer modes
  mode_map <- c(
    optimizer = "milp", optimizer_lp = "lp", optimizer_qp = "qp",
    smart = "smart"
  )

  total <- length(pv_range) * length(batt_range) * length(modes) * length(contrats)
  resultats <- vector("list", total)
  k <- 0

  for (ct in contrats) {
    p_ct <- params
    p_ct$type_contrat <- ct
    if (ct == "fixe") {
      p_ct$taxe_transport_eur_kwh <- 0
    }

    for (pv_kwc in pv_range) {
      p_ct$pv_kwc <- pv_kwc
      df_pv <- df
      ratio <- pv_kwc / params$pv_kwc_ref
      df_pv$pv_kwh <- df$pv_kwh * ratio

      for (bkwh in batt_range) {
        p_sim <- p_ct
        p_sim$batterie_active <- bkwh > 0
        p_sim$batt_kwh <- bkwh
        p_sim$batt_kw <- min(bkwh / 2, 5)

        for (m in modes) {
          k <- k + 1
          if (!is.null(progress_fn)) {
            progress_fn(k, total, sprintf(
              "%d/%d -- PV %dkWc Batt %dkWh %s %s",
              k, total, pv_kwc, bkwh, m, ct
            ))
          }

          r6_m <- mode_map[m]
          if (is.na(r6_m)) r6_m <- "smart"

          if (m == "optimizer_qp") {
            p_sim$qp_w_comfort <- 0.1
            p_sim$qp_w_smooth <- 0.05
          }

          row <- tryCatch({
            res <- run_scenario(df_pv, p_sim, mode = r6_m,
                                baseline_mode = baseline_mode)
            res$PV_kWc <- pv_kwc
            res$Batterie_kWh <- bkwh
            res$Mode <- m
            res$Contrat <- ct
            res
          }, error = function(e) {
            tibble::tibble(
              PV_kWc = pv_kwc, Batterie_kWh = bkwh,
              Mode = m, Contrat = ct,
              Cout_EUR = NA_real_, Autoconso_pct = NA_real_,
              Injection_kWh = NA_real_, Soutirage_kWh = NA_real_
            )
          })
          resultats[[k]] <- row
        }
      }
    }
  }

  dplyr::bind_rows(resultats) %>%
    dplyr::filter(!is.na(Cout_EUR)) %>%
    dplyr::arrange(Cout_EUR)
}
