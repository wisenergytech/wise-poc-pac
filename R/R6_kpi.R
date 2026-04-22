# =============================================================================
# R6 Class: KPICalculator
# =============================================================================
# Computes simulation KPIs: energy, financial, comfort, and comparisons
# between baseline and optimized scenarios. All methods are usable standalone
# (outside Shiny) for testing, reporting, or batch analysis.
# =============================================================================

#' @title KPI Calculator
#' @description R6 class for computing simulation KPIs. Provides individual
#'   methods for each metric (bill, self-consumption, self-sufficiency,
#'   conformity, offtake/injection costs) and a bulk [compute()] method that
#'   returns all KPIs at once. All methods are pure functions of data — no
#'   Shiny dependency.
#'
#' @details
#' ## Energy KPIs
#' \describe{
#'   \item{pv_total}{Total PV production (kWh)}
#'   \item{ac_baseline / ac_opti}{Self-consumption rate (\%). PV consumed
#'     on-site / total PV production.}
#'   \item{as_baseline / as_opti}{Self-sufficiency rate (\%). PV consumed
#'     on-site / total consumption.}
#'   \item{soutirage_baseline / soutirage_opti}{Grid offtake (kWh)}
#'   \item{injection_baseline / injection_opti}{Grid injection (kWh)}
#'   \item{conso_pac_baseline / conso_pac_opti}{Heat pump electricity
#'     consumption (kWh)}
#' }
#'
#' ## Financial KPIs
#' \describe{
#'   \item{facture_baseline / facture_opti}{Net bill (EUR): offtake cost
#'     minus injection revenue.}
#'   \item{cout_soutirage_baseline / cout_soutirage_opti}{Grid offtake
#'     cost (EUR).}
#'   \item{rev_injection_baseline / rev_injection_opti}{Injection revenue
#'     (EUR).}
#'   \item{gain_eur / gain_pct}{Savings vs baseline (EUR and \%).}
#'   \item{gain_eur_per_day / gain_eur_per_year}{Annualised savings.}
#' }
#'
#' ## CO2 KPIs (optional, requires co2_15min)
#' \describe{
#'   \item{co2_baseline_kg / co2_opti_kg}{Total emissions (kg CO2eq)}
#'   \item{co2_intensity_baseline / co2_intensity_opti}{Consumption-weighted
#'     carbon intensity (gCO2/kWh)}
#'   \item{co2_saved_kg}{CO2 avoided (kg)}
#'   \item{co2_pct_reduction}{Intensity reduction (\%)}
#'   \item{co2_equiv_car_km}{Car-km equivalent}
#'   \item{co2_equiv_trees_year}{Trees equivalent per year}
#' }
#'
#' ## Comfort KPI
#' \describe{
#'   \item{conformite_baseline / conformite_opti}{Thermal comfort conformity
#'     (\%): share of time-steps within [t_min, t_max].}
#' }
#'
#' @examples
#' kpi <- KPICalculator$new()
#'
#' # Individual method
#' kpi$get_autoconsommation(baseline_df, pv_total = 100, type = "baseline")
#'
#' # Bulk computation
#' result <- kpi$compute(sim_data, baseline_data, params)
#' result$gain_eur
#' @export
KPICalculator <- R6::R6Class("KPICalculator",
  public = list(
    #' @description Compute all KPIs for a simulation run.
    #' @param sim_data Optimized simulation dataframe (with sim_offtake,
    #'   sim_intake, sim_t_ballon, sim_pac_on, prix_offtake, prix_injection,
    #'   pv_kwh)
    #' @param baseline_data Baseline dataframe (with offtake_kwh, intake_kwh,
    #'   t_ballon, prix_offtake, prix_injection, pv_kwh, conso_hors_pac)
    #' @param params Parameter list (or SimulationParams$as_list()) containing
    #'   at least: t_min, t_max, dt_h, p_pac_kw
    #' @param co2_15min Optional numeric vector of grid carbon intensity
    #'   (gCO2eq/kWh), same length as \code{nrow(sim_data)}. If provided,
    #'   CO2 KPIs are included in the result.
    #' @return A named list of all KPIs (see Details)
    compute = function(sim_data, baseline_data, params, co2_15min = NULL) {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }

      # --- Energy totals ---
      pv_total <- sum(sim_data$pv_kwh, na.rm = TRUE)
      soutirage_baseline <- sum(baseline_data$offtake_kwh, na.rm = TRUE)
      soutirage_opti <- sum(sim_data$sim_offtake, na.rm = TRUE)
      injection_baseline <- sum(baseline_data$intake_kwh, na.rm = TRUE)
      injection_opti <- sum(sim_data$sim_intake, na.rm = TRUE)

      # --- Self-consumption & self-sufficiency ---
      ac_baseline <- self$get_autoconsommation(baseline_data, pv_total, type = "baseline")
      ac_opti <- self$get_autoconsommation(sim_data, pv_total, type = "optimized")
      as_baseline <- self$get_autosuffisance(baseline_data, pv_total, type = "baseline")
      as_opti <- self$get_autosuffisance(sim_data, pv_total, type = "optimized")

      # --- PAC consumption ---
      pac_qt <- params$p_pac_kw * params$dt_h
      conso_pac_opti <- sum(sim_data$sim_pac_on * pac_qt, na.rm = TRUE)
      conso_pac_baseline <- max(0, sum(
        baseline_data$offtake_kwh + baseline_data$pv_kwh -
        baseline_data$intake_kwh - baseline_data$conso_hors_pac,
        na.rm = TRUE
      ))

      # --- Financial ---
      facture_baseline <- self$get_facture(baseline_data, params, type = "baseline")
      facture_opti <- self$get_facture(sim_data, params, type = "optimized")
      gain_eur <- facture_baseline - facture_opti
      gain_pct <- if (abs(facture_baseline) > 0.001) {
        gain_eur / abs(facture_baseline) * 100
      } else {
        0
      }

      cout_soutirage_baseline <- self$get_cout_soutirage(baseline_data, type = "baseline")
      cout_soutirage_opti <- self$get_cout_soutirage(sim_data, type = "optimized")
      rev_injection_baseline <- self$get_rev_injection(baseline_data, type = "baseline")
      rev_injection_opti <- self$get_rev_injection(sim_data, type = "optimized")

      # --- Conformity ---
      conformite_baseline <- self$get_conformite(
        baseline_data$t_ballon, params$t_min, params$t_max
      )
      conformite_opti <- self$get_conformite(
        sim_data$sim_t_ballon, params$t_min, params$t_max
      )

      # --- CO2 (optional) ---
      co2_kpis <- if (!is.null(co2_15min)) {
        co2_impact <- compute_co2_impact(sim_data, co2_15min)
        co2_base_kg <- sum(co2_impact$co2_baseline_g, na.rm = TRUE) / 1000
        co2_opti_kg <- sum(co2_impact$co2_opti_g, na.rm = TRUE) / 1000
        list(
          co2_baseline_kg = co2_base_kg,
          co2_opti_kg = co2_opti_kg,
          co2_saved_kg = co2_impact$co2_saved_kg,
          co2_pct_reduction = co2_impact$co2_pct_reduction,
          co2_intensity_baseline = co2_impact$intensity_before,
          co2_intensity_opti = co2_impact$intensity_after,
          co2_equiv_car_km = co2_impact$equiv_car_km,
          co2_equiv_trees_year = co2_impact$equiv_trees_year
        )
      }

      # --- Battery (optional) ---
      batt_kpis <- if (isTRUE(params$batterie_active) &&
                       "batt_flux" %in% names(sim_data)) {
        charge_tot <- sum(pmax(0, sim_data$batt_flux), na.rm = TRUE)
        list(
          batt_cycles = round(charge_tot / max(params$batt_kwh, 1), 1)
        )
      }

      # --- Period ---
      n_days <- if ("timestamp" %in% names(sim_data) && nrow(sim_data) > 1) {
        as.numeric(difftime(
          max(sim_data$timestamp), min(sim_data$timestamp), units = "days"
        ))
      } else {
        nrow(sim_data) * params$dt_h / 24
      }

      private$kpis <- c(
        list(
          # Energy
          pv_total = pv_total,
          ac_baseline = ac_baseline,
          ac_opti = ac_opti,
          as_baseline = as_baseline,
          as_opti = as_opti,
          soutirage_baseline = soutirage_baseline,
          soutirage_opti = soutirage_opti,
          injection_baseline = injection_baseline,
          injection_opti = injection_opti,
          conso_pac_baseline = conso_pac_baseline,
          conso_pac_opti = conso_pac_opti,
          # Financial
          facture_baseline = facture_baseline,
          facture_opti = facture_opti,
          gain_eur = gain_eur,
          gain_pct = gain_pct,
          cout_soutirage_baseline = cout_soutirage_baseline,
          cout_soutirage_opti = cout_soutirage_opti,
          rev_injection_baseline = rev_injection_baseline,
          rev_injection_opti = rev_injection_opti,
          gain_eur_per_day = if (n_days > 0) gain_eur / n_days else 0,
          gain_eur_per_year = if (n_days > 0) gain_eur / n_days * 365 else 0,
          # Comfort
          conformite_baseline = conformite_baseline,
          conformite_opti = conformite_opti,
          # Period
          n_days = n_days
        ),
        co2_kpis,
        batt_kpis
      )

      private$kpis
    },

    #' @description Get all computed KPIs.
    #' @return Named list of KPIs, or NULL if [compute()] hasn't been called
    get_all = function() private$kpis,

    #' @description Calculate the electricity bill (net cost: offtake - injection).
    #' @param data Dataframe with offtake/intake columns and prix_offtake,
    #'   prix_injection price columns
    #' @param params Parameter list (unused, kept for API compatibility)
    #' @param type "baseline" (uses offtake_kwh, intake_kwh) or "optimized"
    #'   (uses sim_offtake, sim_intake)
    #' @return Net bill in EUR
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

    #' @description Calculate grid offtake cost.
    #' @param data Dataframe with offtake and prix_offtake columns
    #' @param type "baseline" or "optimized"
    #' @return Offtake cost in EUR
    get_cout_soutirage = function(data, type = "baseline") {
      col <- if (type == "optimized") "sim_offtake" else "offtake_kwh"
      sum(data[[col]] * data$prix_offtake, na.rm = TRUE)
    },

    #' @description Calculate grid injection revenue.
    #' @param data Dataframe with injection and prix_injection columns
    #' @param type "baseline" or "optimized"
    #' @return Injection revenue in EUR
    get_rev_injection = function(data, type = "baseline") {
      col <- if (type == "optimized") "sim_intake" else "intake_kwh"
      sum(data[[col]] * data$prix_injection, na.rm = TRUE)
    },

    #' @description Calculate self-consumption rate.
    #' @param data Dataframe with injection column
    #' @param pv_total Total PV production in kWh
    #' @param type "baseline" or "optimized"
    #' @return Self-consumption percentage (0-100): share of PV production
    #'   consumed on-site rather than injected into the grid
    get_autoconsommation = function(data, pv_total, type = "baseline") {
      intake_col <- if (type == "optimized") "sim_intake" else "intake_kwh"
      inj <- sum(data[[intake_col]], na.rm = TRUE)
      round((1 - inj / max(pv_total, 1)) * 100, 1)
    },

    #' @description Calculate self-sufficiency rate.
    #' @param data Dataframe with offtake and injection columns
    #' @param pv_total Total PV production in kWh
    #' @param type "baseline" or "optimized"
    #' @return Self-sufficiency percentage (0-100): share of total consumption
    #'   covered by on-site PV production
    get_autosuffisance = function(data, pv_total, type = "baseline") {
      if (type == "optimized") {
        offtake_col <- "sim_offtake"
        intake_col <- "sim_intake"
      } else {
        offtake_col <- "offtake_kwh"
        intake_col <- "intake_kwh"
      }
      inj <- sum(data[[intake_col]], na.rm = TRUE)
      offt <- sum(data[[offtake_col]], na.rm = TRUE)
      autoconso <- pv_total - inj
      conso_totale <- offt + autoconso
      if (conso_totale <= 0) return(0)
      round(autoconso / conso_totale * 100, 1)
    },

    #' @description Calculate thermal comfort conformity.
    #' @param sim_t_ballon Numeric vector of tank temperatures (degrees C)
    #' @param t_min Lower comfort bound (degrees C)
    #' @param t_max Upper comfort bound (degrees C)
    #' @return Conformity percentage (0-100): share of time-steps where
    #'   temperature stays within [t_min, t_max]
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
