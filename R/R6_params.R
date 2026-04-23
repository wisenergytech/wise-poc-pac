# =============================================================================
# R6 Class: SimulationParams
# =============================================================================
# Encapsulates all simulation parameters (PAC, tank, contract, baseline,
# optimization, curtailment, battery) in a single R6 object.
# =============================================================================

#' @title Simulation Parameters
#' @description R6 class encapsulating all simulation parameters for PAC
#'   optimization. Provides active bindings for derived values (t_min, t_max,
#'   capacite_kwh_par_degre) and an as_list() method for backward compatibility
#'   with existing functions that expect a plain list.
#' @export
SimulationParams <- R6::R6Class("SimulationParams",
  public = list(
    # --- PAC / thermal ---
    t_consigne = NULL,
    t_tolerance = NULL,
    p_pac_kw = NULL,
    cop_nominal = NULL,
    t_ref_cop = NULL,
    dt_h = NULL,

    # --- Contract ---
    type_contrat = NULL,
    prix_fixe_offtake = NULL,
    prix_fixe_injection = NULL,
    taxe_transport_eur_kwh = NULL,
    coeff_injection = NULL,

    # --- Battery ---
    batterie_active = NULL,
    batt_kwh = NULL,
    batt_kw = NULL,
    batt_rendement = NULL,
    batt_soc_min = NULL,
    batt_soc_max = NULL,

    # --- Curtailment ---
    curtailment_active = NULL,
    curtail_kw = NULL,

    # --- Optimization ---
    slack_penalty = NULL,
    optim_bloc_h = NULL,
    poids_cout = NULL,
    horizon_qt = NULL,
    seuil_surplus_pct = NULL,

    # --- Baseline ---
    baseline_mode = NULL,
    autoconso_cible = NULL,
    baseline_alpha = NULL,

    # --- PV ---
    pv_kwc = NULL,
    pv_kwc_ref = NULL,
    pv_data_source = NULL,

    # --- Misc (set during prepare_df) ---
    perte_kwh_par_qt = NULL,

    # --- QP weights ---
    qp_w_comfort = NULL,
    qp_w_smooth = NULL,

    #' @description Create a new SimulationParams object.
    #' @param t_consigne Target tank temperature (degrees C, default 50)
    #' @param t_tolerance Temperature tolerance band (degrees C, default 5)
    #' @param p_pac_kw Heat pump electrical power (kW, default 60)
    #' @param cop_nominal Nominal COP at reference temperature (default 3.5)
    #' @param t_ref_cop Reference external temperature for COP (default 7)
    #' @param volume_ballon_l Tank volume in liters (NULL = auto-size based on PAC power)
    #' @param type_contrat Contract type: "dynamique" or "fixe" (default "dynamique")
    #' @param prix_fixe_offtake Fixed offtake price EUR/kWh (default 0.30)
    #' @param prix_fixe_injection Fixed injection price EUR/kWh (default 0.03)
    #' @param taxe_transport_eur_kwh Transport tax EUR/kWh (default 0.15)
    #' @param coeff_injection Injection coefficient (default 1.0)
    #' @param batterie_active Whether battery is enabled (default FALSE)
    #' @param batt_kwh Battery capacity in kWh (default 10)
    #' @param batt_kw Battery power in kW (default 5)
    #' @param batt_rendement Round-trip efficiency 0-1 (default 0.90)
    #' @param batt_soc_min Minimum SOC fraction 0-1 (default 0.10)
    #' @param batt_soc_max Maximum SOC fraction 0-1 (default 0.90)
    #' @param curtailment_active Whether curtailment is enabled (default FALSE)
    #' @param curtail_kw Curtailment power limit in kW (default 5)
    #' @param slack_penalty Penalty for temperature violations EUR/deg/qt (default 2.5)
    #' @param optim_bloc_h Optimization block size in hours (default 24)
    #' @param baseline_mode Baseline mode: "thermostat" (default) or "pv_tracking"
    #' @param autoconso_cible Target self-consumption percentage from slider (default NULL)
    #' @param baseline_alpha PV-affinity coefficient 0-1 for parametric baseline (default NULL)
    #' @param pv_kwc PV capacity in kWc (default 33)
    #' @param pv_kwc_ref Reference PV capacity for scaling (default 33)
    #' @param dt_h Time step in hours (default 0.25 = 15 min)
    #' @param poids_cout Cost weight for smart mode (default 0.5)
    #' @param horizon_qt Lookahead horizon in quarter-hours (default 16)
    #' @param seuil_surplus_pct Surplus threshold percentage (default 0.3)
    #' @param perte_kwh_par_qt Heat loss per quarter-hour (default 0.05)
    #' @param qp_w_comfort QP comfort weight (default 0.001)
    #' @param qp_w_smooth QP smoothing weight (default 0.01)
    initialize = function(
      t_consigne = 50, t_tolerance = 5,
      p_pac_kw = 60, cop_nominal = 3.5, t_ref_cop = 7,
      volume_ballon_l = NULL,
      type_contrat = "dynamique",
      prix_fixe_offtake = 0.30, prix_fixe_injection = 0.03,
      taxe_transport_eur_kwh = 0.15, coeff_injection = 1.0,
      batterie_active = FALSE, batt_kwh = 10, batt_kw = 5,
      batt_rendement = 0.90, batt_soc_min = 0.10, batt_soc_max = 0.90,
      curtailment_active = FALSE, curtail_kw = 5,
      slack_penalty = 2.5, optim_bloc_h = 24,
      baseline_mode = "thermostat",
      autoconso_cible = NULL,
      baseline_alpha = NULL,
      pv_kwc = 33, pv_kwc_ref = 33, pv_data_source = "synthetic",
      dt_h = 0.25,
      poids_cout = 0.5,
      horizon_qt = 16,
      seuil_surplus_pct = 0.3,
      perte_kwh_par_qt = 0.05,
      qp_w_comfort = 0.001,
      qp_w_smooth = 0.01
    ) {
      self$t_consigne <- t_consigne
      self$t_tolerance <- t_tolerance
      self$p_pac_kw <- p_pac_kw
      self$cop_nominal <- cop_nominal
      self$t_ref_cop <- t_ref_cop
      self$dt_h <- dt_h

      # Auto-size tank volume if NULL: ~15 L per kW of PAC power, minimum 200L
      if (is.null(volume_ballon_l)) {
        private$.volume_ballon_l <- max(200, round(p_pac_kw * 15))
      } else {
        private$.volume_ballon_l <- volume_ballon_l
      }

      self$type_contrat <- type_contrat
      self$prix_fixe_offtake <- prix_fixe_offtake
      self$prix_fixe_injection <- prix_fixe_injection
      self$taxe_transport_eur_kwh <- taxe_transport_eur_kwh
      self$coeff_injection <- coeff_injection

      self$batterie_active <- batterie_active
      self$batt_kwh <- batt_kwh
      self$batt_kw <- batt_kw
      self$batt_rendement <- batt_rendement
      self$batt_soc_min <- batt_soc_min
      self$batt_soc_max <- batt_soc_max

      self$curtailment_active <- curtailment_active
      self$curtail_kw <- curtail_kw

      self$slack_penalty <- slack_penalty
      self$optim_bloc_h <- optim_bloc_h
      self$poids_cout <- poids_cout
      self$horizon_qt <- horizon_qt
      self$seuil_surplus_pct <- seuil_surplus_pct

      self$baseline_mode <- baseline_mode
      self$autoconso_cible <- autoconso_cible
      self$baseline_alpha <- baseline_alpha
      self$pv_kwc <- pv_kwc
      self$pv_kwc_ref <- pv_kwc_ref
      self$pv_data_source <- pv_data_source
      self$perte_kwh_par_qt <- perte_kwh_par_qt
      self$qp_w_comfort <- qp_w_comfort
      self$qp_w_smooth <- qp_w_smooth
    },

    #' @description Convert to a named list compatible with existing functions.
    #' @return A named list with all parameters, identical in structure to
    #'   what params_r() returns in the current app.R.
    as_list = function() {
      list(
        t_consigne = self$t_consigne,
        t_tolerance = self$t_tolerance,
        t_min = self$t_min,
        t_max = self$t_max,
        p_pac_kw = self$p_pac_kw,
        cop_nominal = self$cop_nominal,
        t_ref_cop = self$t_ref_cop,
        volume_ballon_l = self$volume_ballon_l,
        capacite_kwh_par_degre = self$capacite_kwh_par_degre,
        horizon_qt = self$horizon_qt,
        seuil_surplus_pct = self$seuil_surplus_pct,
        dt_h = self$dt_h,
        type_contrat = self$type_contrat,
        taxe_transport_eur_kwh = self$taxe_transport_eur_kwh,
        coeff_injection = self$coeff_injection,
        prix_fixe_offtake = self$prix_fixe_offtake,
        prix_fixe_injection = self$prix_fixe_injection,
        perte_kwh_par_qt = self$perte_kwh_par_qt,
        autoconso_cible = self$autoconso_cible,
        baseline_alpha = self$baseline_alpha,
        pv_kwc = self$pv_kwc,
        pv_kwc_ref = self$pv_kwc_ref,
        pv_data_source = self$pv_data_source,
        batterie_active = self$batterie_active,
        batt_kwh = self$batt_kwh,
        batt_kw = self$batt_kw,
        batt_rendement = self$batt_rendement,
        batt_soc_min = self$batt_soc_min,
        batt_soc_max = self$batt_soc_max,
        poids_cout = self$poids_cout,
        slack_penalty = self$slack_penalty,
        curtailment_active = self$curtailment_active,
        curtail_kwh_per_qt = self$curtail_kwh_per_qt,
        optim_bloc_h = self$optim_bloc_h,
        qp_w_comfort = self$qp_w_comfort,
        qp_w_smooth = self$qp_w_smooth
      )
    }
  ),

  active = list(
    #' @field t_min Lower comfort bound (t_consigne - t_tolerance)
    t_min = function() self$t_consigne - self$t_tolerance,

    #' @field t_max Upper comfort bound (t_consigne + t_tolerance)
    t_max = function() self$t_consigne + self$t_tolerance,

    #' @field capacite_kwh_par_degre Thermal capacity (kWh per degree C)
    capacite_kwh_par_degre = function() private$.volume_ballon_l * 0.001163,

    #' @field curtail_kwh_per_qt Curtailment limit per quarter-hour (kWh), Inf if disabled
    curtail_kwh_per_qt = function() {
      if (self$curtailment_active) self$curtail_kw * self$dt_h else Inf
    },

    #' @field volume_ballon_l Tank volume in liters
    volume_ballon_l = function(value) {
      if (missing(value)) return(private$.volume_ballon_l)
      private$.volume_ballon_l <- value
    }
  ),

  private = list(
    .volume_ballon_l = NULL
  )
)
