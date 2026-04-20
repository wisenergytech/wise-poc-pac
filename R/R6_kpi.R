# =============================================================================
# R6 Class: KPICalculator
# =============================================================================
# Computes simulation KPIs: bill, self-consumption, comfort conformity,
# and comparisons between baseline and optimized scenarios.
# =============================================================================

#' @title KPI Calculator
#' @description R6 class for computing simulation KPIs. Provides methods for
#'   individual KPIs (bill, self-consumption, conformity) and a bulk compute()
#'   method that returns all KPIs at once.
#' @export
KPICalculator <- R6::R6Class("KPICalculator",
  public = list(
    #' @description Compute all KPIs for a simulation run.
    #' @param sim_data Optimized simulation dataframe (with sim_offtake,
    #'   sim_intake, sim_t_ballon, prix_offtake, prix_injection)
    #' @param baseline_data Baseline dataframe (with offtake_kwh, intake_kwh,
    #'   t_ballon, prix_offtake, prix_injection)
    #' @param params Parameter list (or SimulationParams$as_list())
    #' @return A named list of all KPIs
    compute = function(sim_data, baseline_data, params) {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }

      # Bills
      facture_baseline <- self$get_facture(baseline_data, params, type = "baseline")
      facture_opti <- self$get_facture(sim_data, params, type = "optimized")
      gain_eur <- facture_baseline - facture_opti
      gain_pct <- if (abs(facture_baseline) > 0.001) {
        gain_eur / abs(facture_baseline) * 100
      } else {
        0
      }

      # Self-consumption
      pv_total <- sum(sim_data$pv_kwh, na.rm = TRUE)
      ac_baseline <- self$get_autoconsommation(baseline_data, pv_total, type = "baseline")
      ac_opti <- self$get_autoconsommation(sim_data, pv_total, type = "optimized")

      # Conformity
      conformite_baseline <- self$get_conformite(
        baseline_data$t_ballon, params$t_min, params$t_max
      )
      conformite_opti <- self$get_conformite(
        sim_data$sim_t_ballon, params$t_min, params$t_max
      )

      # Energy totals
      soutirage_baseline <- sum(baseline_data$offtake_kwh, na.rm = TRUE)
      soutirage_opti <- sum(sim_data$sim_offtake, na.rm = TRUE)
      injection_baseline <- sum(baseline_data$intake_kwh, na.rm = TRUE)
      injection_opti <- sum(sim_data$sim_intake, na.rm = TRUE)

      # Period
      n_days <- if ("timestamp" %in% names(sim_data) && nrow(sim_data) > 1) {
        as.numeric(difftime(
          max(sim_data$timestamp), min(sim_data$timestamp), units = "days"
        ))
      } else {
        nrow(sim_data) * params$dt_h / 24
      }

      private$kpis <- list(
        facture_baseline = facture_baseline,
        facture_opti = facture_opti,
        gain_eur = gain_eur,
        gain_pct = gain_pct,
        ac_baseline = ac_baseline,
        ac_opti = ac_opti,
        conformite_baseline = conformite_baseline,
        conformite_opti = conformite_opti,
        soutirage_baseline = soutirage_baseline,
        soutirage_opti = soutirage_opti,
        injection_baseline = injection_baseline,
        injection_opti = injection_opti,
        pv_total = pv_total,
        n_days = n_days,
        gain_eur_per_day = if (n_days > 0) gain_eur / n_days else 0,
        gain_eur_per_year = if (n_days > 0) gain_eur / n_days * 365 else 0
      )

      private$kpis
    },

    #' @description Get all computed KPIs.
    #' @return Named list of KPIs, or NULL if compute() hasn't been called
    get_all = function() private$kpis,

    #' @description Calculate the electricity bill (net cost).
    #' @param data Dataframe with offtake/intake and price columns
    #' @param params Parameter list (used for column name inference)
    #' @param type "baseline" or "optimized" (determines which columns to use)
    #' @return Net bill in EUR (offtake cost - injection revenue)
    get_facture = function(data, params = NULL, type = "baseline") {
      if (type == "optimized") {
        offtake_col <- "sim_offtake"
        intake_col <- "sim_intake"
      } else {
        offtake_col <- "offtake_kwh"
        intake_col <- "intake_kwh"
      }

      sum(data[[offtake_col]] * data$prix_offtake, na.rm = TRUE) -
        sum(data[[intake_col]] * data$prix_injection, na.rm = TRUE)
    },

    #' @description Calculate self-consumption rate.
    #' @param data Dataframe with injection column
    #' @param pv_total Total PV production in kWh
    #' @param type "baseline" or "optimized"
    #' @return Self-consumption percentage (0-100)
    get_autoconsommation = function(data, pv_total, type = "baseline") {
      intake_col <- if (type == "optimized") "sim_intake" else "intake_kwh"
      inj <- sum(data[[intake_col]], na.rm = TRUE)
      round((1 - inj / max(pv_total, 1)) * 100, 1)
    },

    #' @description Calculate thermal comfort conformity.
    #' @param sim_t_ballon Vector of tank temperatures
    #' @param t_min Lower comfort bound
    #' @param t_max Upper comfort bound
    #' @return Conformity percentage (0-100)
    get_conformite = function(sim_t_ballon, t_min, t_max) {
      n_low <- sum(sim_t_ballon < t_min, na.rm = TRUE)
      n_high <- sum(sim_t_ballon > t_max, na.rm = TRUE)
      n_tot <- sum(!is.na(sim_t_ballon))
      if (n_tot == 0) return(100)
      round((1 - (n_low + n_high) / n_tot) * 100, 1)
    }
  ),

  private = list(
    kpis = NULL
  )
)
