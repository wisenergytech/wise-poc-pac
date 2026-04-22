# =============================================================================
# R6 Class: Baseline
# =============================================================================
# Encapsulates the baseline (reference) simulation representing the "before
# optimization" scenario. Two modes:
#   - "thermostat" (default): pure ON/OFF hysteresis, no PV awareness
#   - "pv_tracking": parametric PV surplus following via alpha coefficient
# =============================================================================

#' @title Baseline Simulation
#' @description R6 class for baseline (reference) simulation. The baseline
#'   represents the "before optimization" scenario — what happens without
#'   an intelligent EMS.
#'
#' @details
#' ## Modes
#' \describe{
#'   \item{thermostat}{(default) Pure ON/OFF hysteresis control. The heat pump
#'     turns ON when tank temperature drops below \code{t_min} and OFF when
#'     it reaches \code{t_consigne}. This is the behaviour of ~95\% of
#'     non-intelligent PAC installations (simple aquastat). The resulting
#'     PV self-consumption is purely incidental.}
#'   \item{pv_tracking}{Parametric PV surplus following. The heat pump follows
#'     PV surplus proportionally to an \code{alpha} parameter (0 = thermostat,
#'     1 = maximum PV tracking). This models installations with basic
#'     domotics or surplus-following inverters (e.g. SolarEdge, Fronius).
#'     Requires \code{params$baseline_alpha}.}
#' }
#'
#' ## Thermal model
#' Both modes use the same thermal equation per timestep:
#' \deqn{T_{i} = \frac{T_{i-1} \cdot (C - k) + Q_{pac} + k \cdot T_{amb} - Q_{ecs}}{C}}
#' where \eqn{C} is tank heat capacity (kWh/K), \eqn{k} is loss coefficient,
#' \eqn{Q_{pac}} is heat pump output, and \eqn{Q_{ecs}} is hot water draw.
#'
#' @examples
#' params <- list(
#'   t_consigne = 50, t_tolerance = 5, t_min = 45, t_max = 55,
#'   p_pac_kw = 2, cop_nominal = 3.5, t_ref_cop = 7,
#'   volume_ballon_l = 200, capacite_kwh_par_degre = 200 * 0.001163,
#'   dt_h = 0.25
#' )
#' tm <- ThermalModel$new(params)
#' bl <- Baseline$new(tm)
#'
#' # Default: thermostat
#' result <- bl$run(df, params)
#'
#' # Advanced: PV tracking with alpha = 0.6
#' params$baseline_alpha <- 0.6
#' result <- bl$run(df, params, mode = "pv_tracking")
#' @export
Baseline <- R6::R6Class("Baseline",
  public = list(
    #' @description Create a new Baseline.
    #' @param thermal_model A ThermalModel R6 instance
    initialize = function(thermal_model) {
      private$thermal_model <- thermal_model
    },

    #' @description Run the baseline simulation.
    #' @param df Prepared dataframe (output of DataGenerator$prepare_df) with
    #'   columns: pv_kwh, t_ext, conso_hors_pac, soutirage_estime_kwh,
    #'   prix_offtake, prix_injection, and optionally timestamp
    #' @param params Parameter list with at least: t_consigne, t_min, t_max,
    #'   p_pac_kw, cop_nominal, t_ref_cop, capacite_kwh_par_degre, dt_h.
    #'   For \code{"pv_tracking"} mode, also requires baseline_alpha.
    #' @param mode Baseline mode: \code{"thermostat"} (default) or
    #'   \code{"pv_tracking"}
    #' @return The input df with added columns: t_ballon, offtake_kwh, intake_kwh
    run = function(df, params, mode = "thermostat") {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }

      # Support legacy mode names
      mode <- private$normalize_mode(mode)

      n <- nrow(df)
      pac_qt <- params$p_pac_kw * params$dt_h
      cap <- params$capacite_kwh_par_degre
      k_perte <- 0.004 * params$dt_h
      t_amb <- 20

      pv    <- df$pv_kwh
      conso <- df$conso_hors_pac
      ecs   <- df$soutirage_estime_kwh
      t_ext_v <- df$t_ext
      surplus_pv_qt <- pv - conso

      # Pre-compute mean COP (used by pv_tracking mode)
      cop_moyen <- if (mode == "pv_tracking") {
        mean(calc_cop(t_ext_v, params$cop_nominal, params$t_ref_cop), na.rm = TRUE)
      } else {
        NULL
      }

      alpha <- if (mode == "pv_tracking") {
        if (!is.null(params$baseline_alpha)) params$baseline_alpha else 0.5
      } else {
        NULL
      }

      t_bal  <- rep(NA_real_, n)
      pac_on <- rep(0, n)
      t_bal[1] <- params$t_consigne

      for (i in seq_len(n)) {
        t_prev <- if (i == 1) params$t_consigne else t_bal[i - 1]
        cop_i <- calc_cop(t_ext_v[i], params$cop_nominal, params$t_ref_cop,
                          t_ballon = t_prev)

        # --- Decision ---
        if (mode == "pv_tracking") {
          pac_on[i] <- private$decide_pv_tracking(
            t_prev, surplus_pv_qt[i], pac_qt, cop_i, cop_moyen, alpha,
            cap, k_perte, t_amb, ecs[i], params
          )
        } else {
          pac_on[i] <- private$decide_thermostat(
            t_prev, pac_on[if (i > 1) i - 1 else 1], params
          )
        }

        # --- Thermal equation (identical for all modes) ---
        chaleur <- pac_on[i] * pac_qt * cop_i
        t_bal[i] <- (t_prev * (cap - k_perte) + chaleur + k_perte * t_amb - ecs[i]) / cap
        t_bal[i] <- max(max(20, params$t_min - 10), min(params$t_max + 5, t_bal[i]))
      }

      # Electrical balance
      conso_totale <- conso + pac_on * pac_qt
      surplus  <- pv - conso_totale
      offtake  <- pmax(0, -surplus)
      intake   <- pmax(0, surplus)

      private$result <- df %>% dplyr::mutate(
        t_ballon    = t_bal,
        offtake_kwh = offtake,
        intake_kwh  = intake
      )

      private$result
    },

    #' @description Get the last baseline result.
    #' @return The baseline dataframe, or NULL if run() hasn't been called
    get_result = function() private$result
  ),

  private = list(
    thermal_model = NULL,
    result = NULL,

    # Map legacy mode names to current modes
    normalize_mode = function(mode) {
      legacy_map <- c(
        reactif = "thermostat", programmateur = "thermostat",
        proactif = "thermostat", surplus_pv = "pv_tracking",
        ingenieur = "pv_tracking", parametric = "pv_tracking"
      )
      if (mode %in% names(legacy_map)) legacy_map[[mode]] else mode
    },

    # Pure thermostat with hysteresis: ON below t_min, OFF above t_consigne
    decide_thermostat = function(t_prev, pac_on_prev, params) {
      if (t_prev < params$t_min) {
        1
      } else if (t_prev > params$t_consigne) {
        0
      } else {
        pac_on_prev
      }
    },

    # PV surplus tracking with alpha modulation
    decide_pv_tracking = function(t_prev, surplus_i, pac_qt, cop_i, cop_moyen,
                                  alpha, cap, k_perte, t_amb, ecs_i, params) {
      t_sans_pac <- (t_prev * (cap - k_perte) + k_perte * t_amb - ecs_i) / cap

      if (t_prev < params$t_min) {
        1
      } else if (t_prev >= params$t_max) {
        0
      } else if (surplus_i > 0) {
        alpha * min(1, max(0.1, surplus_i / pac_qt))
      } else if (t_sans_pac < params$t_min) {
        1
      } else {
        0
      }
    }
  )
)
