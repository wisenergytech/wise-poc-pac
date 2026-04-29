#' PAC Analysis Tab Module UI
#'
#' Visualizes heat pump behavior: hourly profile (baseline vs optimized),
#' price distribution of PAC consumption, and hourly distribution.
#'
#' @param id module id
#' @noRd
mod_pac_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::card(
      class = "border-warning bg-warning-subtle mb-3",
      bslib::card_body(
        shiny::tags$div(class = "d-flex align-items-center gap-2",
          shiny::tags$strong("Work in progress"),
          shiny::tags$span(class = "text-muted", "— Analyse PAC en cours de developpement")))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        card_header_tip("Profil horaire moyen de la PAC",
          "Puissance PAC moyenne par heure (0-23h). Compare le fonctionnement actuel (baseline) avec le pilotage optimise. Le fond colore indique le prix moyen par heure : plus c'est rouge, plus c'est cher."),
        bslib::card_body(plotly::plotlyOutput(ns("plot_profil_horaire"), height = "350px"))))
  )
}

#' PAC Analysis Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_pac_server <- function(id, sidebar) {
  moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered

    # ---- Helper: get sim data and params (handles cross-contract) ----
    get_sim_params <- function() {
      sim <- sim_filtered()
      sim_c <- sidebar$sim_filtered_cible()
      res <- sidebar$sim_result()
      p_r <- if (!is.null(sim_c) && !is.null(res$params_cible)) res$params_cible else sidebar$params_r()
      params <- if (inherits(p_r, "SimulationParams")) p_r$as_list() else p_r
      sim_data <- if (!is.null(sim_c)) sim_c else sim
      list(sim = sim_data, params = params)
    }

    # ---- Helper: extract PAC kWh vector ----
    get_pac_kwh <- function(sim, params, type = "baseline") {
      if (type == "optimized") {
        sim$sim_pac_on * params$p_pac_kw * params$dt_h
      } else if ("pac_kwh" %in% names(sim)) {
        sim$pac_kwh
      } else {
        pmax(0, sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac)
      }
    }

    # ---- Helper: compute hourly PAC profile ----
    compute_hourly_profile <- function(sim, params, type = "baseline") {
      pac_kwh <- get_pac_kwh(sim, params, type)
      h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))

      dplyr::tibble(hour = h, pac_kwh = pac_kwh) %>%
        dplyr::group_by(hour) %>%
        dplyr::summarise(
          pac_total_kwh = sum(pac_kwh, na.rm = TRUE),
          pac_moy_kw = mean(pac_kwh, na.rm = TRUE) / params$dt_h,
          .groups = "drop"
        ) %>%
        dplyr::mutate(pct = round(100 * pac_total_kwh / max(sum(pac_total_kwh), 1), 1))
    }

    # ---- Helper: mean price per hour ----
    compute_hourly_prix <- function(sim) {
      h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))
      dplyr::tibble(hour = h, prix = sim$prix_offtake) %>%
        dplyr::group_by(hour) %>%
        dplyr::summarise(prix_moy = mean(prix, na.rm = TRUE), .groups = "drop")
    }

    # ---- BELIX pilotage value boxes ----
    belix_data <- shiny::reactive({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      kpi_calc <- KPICalculator$new()
      kpi_calc$get_belix_pilotage(sp$sim, sp$params)
    })

    output$vb_belix_temps <- shiny::renderUI({
      b <- belix_data()
      shiny::tags$span(paste0(b$pct_temps_offpeak, "%"))
    })

    output$vb_belix_pac <- shiny::renderUI({
      b <- belix_data()
      shiny::tags$span(paste0(b$pct_pac_offpeak, "%"))
    })

    output$vb_belix_verdict <- shiny::renderUI({
      b <- belix_data()
      label <- switch(b$verdict,
        thermostat = "Thermostat pur",
        pilotage = "Pilotage detecte",
        `anti-pilotage` = "Anti-pilotage",
        "Inconnu")
      shiny::tags$span(
        label,
        shiny::tags$small(class = "text-muted d-block",
          paste0("Ecart: ", b$ecart_pp, " pp")))
    })

    # ---- Hourly profile chart with price gradient background ----
    output$plot_profil_horaire <- plotly::renderPlotly({
      shiny::req(sim_filtered())
      sp <- get_sim_params()
      sim <- sp$sim; params <- sp$params

      bl <- compute_hourly_profile(sim, params, "baseline")
      op <- compute_hourly_profile(sim, params, "optimized")
      hp <- compute_hourly_prix(sim)

      profil_data <- rbind(
        transform(bl, scenario = "Baseline"),
        transform(op, scenario = "Optimise")
      )
      plot_profil_horaire(profil_data, hp)
    })

  })
}
