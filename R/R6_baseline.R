# =============================================================================
# R6 Class: Baseline
# =============================================================================
# Encapsulates the baseline (reference) simulation with 5 modes:
# reactif, programmateur, surplus_pv, ingenieur, proactif.
# Contains the full run_baseline() logic from app.R.
# =============================================================================

#' @title Baseline Simulation
#' @description R6 class for baseline (reference) simulation with 5 modes.
#'   The baseline represents the "before optimization" scenario (thermostat,
#'   programmer, PV surplus follower, engineer, or proactive).
#' @export
Baseline <- R6::R6Class("Baseline",
  public = list(
    #' @description Create a new Baseline.
    #' @param thermal_model A ThermalModel R6 instance
    initialize = function(thermal_model) {
      private$thermal_model <- thermal_model
    },

    #' @description Run the baseline simulation.
    #'   Contains the full run_baseline() logic from app.R, using the same
    #'   thermal model (proportional heat loss) as the optimizers.
    #' @param df Prepared dataframe (output of DataGenerator$prepare_df)
    #' @param params Parameter list (or SimulationParams$as_list())
    #' @param mode Baseline mode: "reactif", "programmateur", "surplus_pv",
    #'   "ingenieur" (default), or "proactif"
    #' @return The input df with added columns: t_ballon, offtake_kwh, intake_kwh
    run = function(df, params, mode = "ingenieur") {
      if (inherits(params, "SimulationParams")) {
        params <- params$as_list()
      }

      n <- nrow(df)
      pac_qt <- params$p_pac_kw * params$dt_h
      cap <- params$capacite_kwh_par_degre
      k_perte <- 0.004 * params$dt_h
      t_amb <- 20

      t_consigne_bas  <- params$t_min
      t_consigne_haut <- params$t_consigne

      pv    <- df$pv_kwh
      conso <- df$conso_hors_pac
      ecs   <- df$soutirage_estime_kwh
      t_ext_v <- df$t_ext

      h <- if ("timestamp" %in% names(df)) {
        lubridate::hour(df$timestamp) + lubridate::minute(df$timestamp) / 60
      } else {
        rep(12, n)
      }
      surplus_pv_qt <- pv - conso

      # Average COP over the period (for ingenieur mode)
      cop_moyen <- mean(calc_cop(t_ext_v, params$cop_nominal, params$t_ref_cop), na.rm = TRUE)

      t_bal  <- rep(NA_real_, n)
      pac_on <- rep(0, n)
      t_bal[1] <- params$t_consigne

      for (i in seq_len(n)) {
        t_prev <- if (i == 1) params$t_consigne else t_bal[i - 1]
        cop_i <- calc_cop(t_ext_v[i], params$cop_nominal, params$t_ref_cop, t_ballon = t_prev)
        surplus_i <- surplus_pv_qt[i]

        # Projected T without heating
        t_sans_pac <- (t_prev * (cap - k_perte) + k_perte * t_amb - ecs[i]) / cap

        # --- Decision by mode ---
        if (mode == "programmateur") {
          if (h[i] >= 11 & h[i] < 15 & t_prev < params$t_max) {
            pac_on[i] <- 1
          } else if (t_prev < t_consigne_bas) {
            pac_on[i] <- 1
          } else if (t_prev > t_consigne_haut) {
            pac_on[i] <- 0
          } else {
            pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
          }

        } else if (mode == "surplus_pv") {
          seuil_surplus <- 0.5 * params$dt_h
          if (surplus_i > seuil_surplus & t_prev < params$t_max) {
            pac_on[i] <- 1
          } else if (t_prev < t_consigne_bas) {
            pac_on[i] <- 1
          } else if (t_prev > t_consigne_haut) {
            pac_on[i] <- 0
          } else {
            pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
          }

        } else if (mode == "ingenieur") {
          if (t_prev < t_consigne_bas) {
            pac_on[i] <- 1
          } else if (t_prev >= params$t_max) {
            pac_on[i] <- 0
          } else if (surplus_i > 0 & t_prev < params$t_max) {
            pac_on[i] <- min(1, max(0.1, surplus_i / pac_qt))
          } else if (t_sans_pac < t_consigne_bas) {
            pac_on[i] <- 1
          } else if (t_prev < params$t_consigne & cop_i > cop_moyen * 1.05) {
            pac_on[i] <- 0.3
          } else {
            pac_on[i] <- 0
          }

        } else {
          # Reactif or proactif: pure thermostat with hysteresis
          if (t_prev < t_consigne_bas) {
            pac_on[i] <- 1
          } else if (t_prev > t_consigne_haut) {
            pac_on[i] <- 0
          } else {
            pac_on[i] <- if (i > 1) pac_on[i - 1] else 0
          }
        }

        # Proactive constraints (proactif mode only)
        if (mode == "proactif") {
          chaleur_pac_i <- pac_qt * cop_i
          t_min_i <- if (ecs[i] > chaleur_pac_i) params$t_min - 10 else params$t_min
          if (pac_on[i] == 0) {
            if (t_sans_pac < t_min_i) pac_on[i] <- 1
          }
          if (pac_on[i] == 1) {
            t_avec_pac <- (t_prev * (cap - k_perte) + pac_qt * cop_i + k_perte * t_amb - ecs[i]) / cap
            if (t_avec_pac > params$t_max) pac_on[i] <- 0
          }
        }

        # Thermal equation (identical for all modes)
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
    result = NULL
  )
)
