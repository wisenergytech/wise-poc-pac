# =============================================================================
# R6 Class: ThermalModel
# =============================================================================
# Encapsulates thermal dynamics: COP calculation, heat balance, and energy
# balance for the PAC + tank system. Uses the same proportional heat loss
# model as app.R, optimizer_milp.R, optimizer_lp.R, and optimizer_qp.R.
# =============================================================================

#' @title Thermal Model
#' @description R6 class for thermal dynamics (COP, heat balance, losses).
#'   Provides the same thermal equations used throughout the simulation:
#'   baseline, smart mode, and all optimizer variants.
#' @export
ThermalModel <- R6::R6Class("ThermalModel",
  public = list(
    #' @description Create a new ThermalModel.
    #' @param params A list or SimulationParams R6 object. If R6, as_list() is
    #'   called automatically. Required fields: capacite_kwh_par_degre, dt_h,
    #'   p_pac_kw, cop_nominal, t_ref_cop, t_max.
    initialize = function(params) {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }
      private$cap <- params$capacite_kwh_par_degre
      private$k_perte <- 0.004 * params$dt_h
      private$t_amb <- 20
      private$pac_qt <- params$p_pac_kw * params$dt_h
      private$dt_h <- params$dt_h
      private$cop_nominal <- params$cop_nominal
      private$t_ref_cop <- params$t_ref_cop
      private$t_max <- params$t_max
      private$t_min <- params$t_min
    },

    #' @description Calculate COP (Coefficient of Performance).
    #'   Delegates to the standalone calc_cop() function in fct_helpers.R.
    #' @param t_ext External temperature (numeric vector)
    #' @param t_ballon Optional tank temperature (numeric vector). If provided,
    #'   COP is reduced by 1% per degree above 50C.
    #' @return Numeric vector of COP values, clamped to [1.5, 5.5]
    calc_cop = function(t_ext, t_ballon = NULL) {
      calc_cop(t_ext, private$cop_nominal, private$t_ref_cop, t_ballon = t_ballon)
    },

    #' @description Compute one time step of the thermal dynamics.
    #'   T(t) = (T(t-1) * (cap - k_perte) + pac_load * pac_qt * cop + k_perte * T_amb - ecs) / cap
    #'   Result is clamped to [max(20, t_min - 10), t_max + 5].
    #' @param t_prev Previous tank temperature (degrees C)
    #' @param pac_load PAC load fraction [0, 1] (1 = full power ON)
    #' @param cop COP at this time step
    #' @param ecs Hot water draw at this time step (kWh thermal)
    #' @return New tank temperature (degrees C), clamped
    thermal_step = function(t_prev, pac_load, cop, ecs) {
      chaleur <- pac_load * private$pac_qt * cop
      t_new <- (t_prev * (private$cap - private$k_perte) +
                  chaleur + private$k_perte * private$t_amb - ecs) / private$cap
      # Clamp to physical/comfort bounds
      t_floor <- max(20, private$t_min - 10)
      max(t_floor, min(private$t_max + 5, t_new))
    },

    #' @description Compute the electrical energy balance for one time step.
    #' @param pv PV production (kWh)
    #' @param conso Non-PAC consumption (kWh)
    #' @param pac_elec PAC electrical consumption (kWh)
    #' @param curtail_limit Injection limit per qt (kWh), Inf if no curtailment
    #' @return A list with offtake (kWh from grid) and intake (kWh injected)
    energy_balance = function(pv, conso, pac_elec, curtail_limit = Inf) {
      surplus <- pv - conso - pac_elec
      offtake <- max(0, -surplus)
      intake <- min(max(0, surplus), curtail_limit)
      list(offtake = offtake, intake = intake)
    },

    #' @description Get the PAC electrical energy per quarter-hour (kWh).
    #' @return Numeric scalar
    get_pac_qt = function() private$pac_qt,

    #' @description Get the thermal capacity (kWh per degree C).
    #' @return Numeric scalar
    get_cap = function() private$cap
  ),

  private = list(
    cap = NULL,
    k_perte = NULL,
    t_amb = 20,
    pac_qt = NULL,
    dt_h = NULL,
    cop_nominal = NULL,
    t_ref_cop = NULL,
    t_max = NULL,
    t_min = NULL
  )
)
