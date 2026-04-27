#' Comparaison Tab Module UI
#'
#' Explorateur de donnees progressif : sources externes (toujours disponible),
#' baseline (apres simulation), optimise (apres simulation).
#'
#' @param id module id
#' @noRd
mod_comparaison_ui <- function(id) {

  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        bslib::card_header(shiny::tags$span(
          "Explorateur de donn\u00e9es",
          tip("Comparez 2 ou 3 series temporelles. Les donnees externes sont disponibles immediatement. Les series baseline et optimisees apparaissent apres simulation."))),
        bslib::card_body(
          bslib::layout_columns(col_widths = c(3, 3, 3, 3),
            shiny::selectInput(ns("compare_var1"), "Serie 1 (axe gauche)",
              choices = NULL, selected = NULL),
            shiny::selectInput(ns("compare_var2"), "Serie 2 (axe droit)",
              choices = NULL, selected = NULL),
            shiny::selectInput(ns("compare_var3"), "Serie 3 (optionnelle)",
              choices = NULL, selected = NULL),
            shiny::dateRangeInput(ns("compare_range"), "Zoom periode",
              start = Sys.Date() - 60, end = Sys.Date() - 5, language = "fr")),
          plotly::plotlyOutput(ns("plot_compare"), height = "480px")))))
}

#' Comparaison Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_comparaison_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_result   <- sidebar$sim_result
    date_range   <- sidebar$date_range

    # ---- Variable definitions by category ----
    vars_external <- c(
      "[ENTSO-E] Prix spot (EUR/kWh)"          = "ext_prix",
      "[Open-Meteo] Temp\u00e9rature ext. (\u00b0C)" = "ext_temperature",
      "[Elia] Intensit\u00e9 CO2 (gCO2/kWh)"   = "ext_co2",
      "[Elia] Production PV Namur (kWh)"        = "ext_pv"
    )

    vars_baseline <- c(
      "Production PV (kWh)"              = "pv_kwh",
      "Soutirage baseline (kWh)"         = "offtake_kwh",
      "Injection baseline (kWh)"         = "intake_kwh",
      "Autoconsommation baseline (kWh)"  = "autoconso_baseline",
      "Facture baseline (EUR)"           = "facture_baseline",
      "Conso hors PAC (kWh)"             = "conso_hors_pac",
      "Conso PAC mesur\u00e9e (kWh)"     = "pac_kwh",
      "Soutirage ECS (kWh)"              = "soutirage_estime_kwh",
      "Temp\u00e9rature ballon baseline (\u00b0C)" = "t_ballon",
      "Temp\u00e9rature ext\u00e9rieure sim (\u00b0C)" = "t_ext",
      "Prix soutirage (EUR/kWh)"         = "prix_offtake",
      "Prix injection (EUR/kWh)"         = "prix_injection"
    )

    vars_optimised <- c(
      "Soutirage optimis\u00e9 (kWh)"         = "sim_offtake",
      "Injection optimis\u00e9e (kWh)"         = "sim_intake",
      "Autoconsommation optimis\u00e9e (kWh)"  = "autoconso_opti",
      "Facture optimis\u00e9e (EUR)"            = "facture_opti",
      "Temp\u00e9rature ballon optimis\u00e9e (\u00b0C)" = "sim_t_ballon",
      "COP"                                     = "sim_cop",
      "PAC on (optimis\u00e9)"                  = "sim_pac_on"
    )

    all_vars <- c(vars_external, vars_baseline, vars_optimised)

    # Color palettes per category (primary + fallbacks for dedup)
    palette_baseline  <- c(cl$reel, cl$pv, cl$accent2)
    palette_optimised <- c(cl$opti, cl$pac, cl$accent)
    palette_external  <- c(cl$external1, cl$external2, cl$external3)

    get_palette <- function(var) {
      if (var %in% vars_baseline) palette_baseline
      else if (var %in% vars_optimised) palette_optimised
      else palette_external
    }

    pick_colors <- function(vars) {
      cols <- character(length(vars))
      used <- character(0)
      for (i in seq_along(vars)) {
        pal <- get_palette(vars[i])
        available <- setdiff(pal, used)
        cols[i] <- if (length(available) > 0) available[1] else pal[1]
        used <- c(used, cols[i])
      }
      cols
    }

    summable <- c("ext_pv", "pv_kwh", "offtake_kwh", "sim_offtake",
      "intake_kwh", "sim_intake", "conso_hors_pac", "soutirage_estime_kwh",
      "sim_pac_on", "autoconso_baseline", "autoconso_opti",
      "facture_baseline", "facture_opti")

    get_unit <- function(var) {
      if (is.null(var) || var == "") return(NA_character_)
      label <- names(all_vars)[all_vars == var]
      if (length(label) == 0) return(NA_character_)
      m <- regmatches(label, regexpr("\\(([^)]+)\\)", label))
      if (length(m) == 0) return(NA_character_)
      gsub("[()]", "", m)
    }

    # ---- State tracking ----
    has_sim <- shiny::reactiveVal(FALSE)

    shiny::observeEvent(sim_result(), {
      has_sim(TRUE)
    })

    # ---- External data reactive (loads on date range change) ----
    external_data <- shiny::reactive({
      shiny::req(date_range())
      dr <- date_range()
      dp <- DataProvider$new()

      # Prix Belpex
      belpex <- tryCatch({
        b <- dp$get_belpex(dr[1], dr[2])
        if (!is.null(b$data) && nrow(b$data) > 0) {
          df <- b$data
          df$timestamp <- lubridate::with_tz(df$datetime, "Europe/Brussels")
          df$ext_prix <- df$price_eur_mwh / 1000
          df[, c("timestamp", "ext_prix")]
        }
      }, error = function(e) NULL)

      # Temperature
      temp <- tryCatch({
        t <- dp$get_temperature(dr[1], dr[2])
        if (!is.null(t) && nrow(t) > 0) {
          t$ext_temperature <- t$t_ext
          t[, c("timestamp", "ext_temperature")]
        }
      }, error = function(e) NULL)

      # CO2
      co2 <- tryCatch({
        c <- dp$get_co2(dr[1], dr[2])
        if (!is.null(c$df) && nrow(c$df) > 0) {
          df <- c$df
          df$timestamp <- lubridate::with_tz(df$datetime, "Europe/Brussels")
          df$ext_co2 <- df$co2_g_per_kwh
          df[, c("timestamp", "ext_co2")]
        }
      }, error = function(e) NULL)

      # Solar PV
      solar <- tryCatch({
        s <- fetch_solar_elia(dr[1], dr[2], region = "Namur")
        if (!is.null(s$df) && nrow(s$df) > 0) {
          pv_kwc <- tryCatch(sidebar$pv_kwc_eff(), error = function(e) 30)
          scaled <- scale_solar_to_local(s$df, pv_kwc)
          scaled$timestamp <- lubridate::with_tz(scaled$datetime, "Europe/Brussels")
          scaled[, c("timestamp", "pv_kwh")]
          dplyr::rename(scaled[, c("timestamp", "pv_kwh")], ext_pv = pv_kwh)
        }
      }, error = function(e) NULL)

      # Build quarter-hourly grid and join all
      ts_start <- as.POSIXct(paste0(dr[1], " 00:00:00"), tz = "Europe/Brussels")
      ts_end   <- as.POSIXct(paste0(dr[2], " 23:45:00"), tz = "Europe/Brussels")
      grid <- dplyr::tibble(timestamp = seq(ts_start, ts_end, by = "15 min"))

      # Join each source by nearest timestamp (floor to hour for hourly sources)
      if (!is.null(belpex)) {
        belpex$join_h <- lubridate::floor_date(belpex$timestamp, "hour")
        grid$join_h <- lubridate::floor_date(grid$timestamp, "hour")
        grid <- dplyr::left_join(grid, dplyr::distinct(belpex[, c("join_h", "ext_prix")], join_h, .keep_all = TRUE), by = "join_h")
        grid$join_h <- NULL
      }
      if (!is.null(temp)) {
        temp$join_h <- lubridate::floor_date(temp$timestamp, "hour")
        grid$join_h <- lubridate::floor_date(grid$timestamp, "hour")
        grid <- dplyr::left_join(grid, dplyr::distinct(temp[, c("join_h", "ext_temperature")], join_h, .keep_all = TRUE), by = "join_h")
        grid$join_h <- NULL
      }
      if (!is.null(co2)) {
        co2$join_h <- lubridate::floor_date(co2$timestamp, "hour")
        grid$join_h <- lubridate::floor_date(grid$timestamp, "hour")
        grid <- dplyr::left_join(grid, dplyr::distinct(co2[, c("join_h", "ext_co2")], join_h, .keep_all = TRUE), by = "join_h")
        grid$join_h <- NULL
      }
      if (!is.null(solar)) {
        grid <- dplyr::left_join(grid, solar, by = "timestamp")
      }

      grid
    })

    # ---- Build grouped choices based on data availability ----
    build_choices <- function() {
      ext <- external_data()
      ext_avail <- vars_external[vars_external %in% names(ext)]

      if (has_sim()) {
        sim <- sim_result()$sim
        bl_avail <- vars_baseline[vars_baseline %in% names(sim)]
        op_avail <- vars_optimised[vars_optimised %in% names(sim)]
        # Add derived columns
        bl_avail <- c(bl_avail, vars_baseline[vars_baseline %in% c("autoconso_baseline", "facture_baseline")])
        op_avail <- c(op_avail, vars_optimised[vars_optimised %in% c("autoconso_opti", "facture_opti")])
        bl_avail <- bl_avail[!duplicated(bl_avail)]
        op_avail <- op_avail[!duplicated(op_avail)]
      } else {
        bl_avail <- stats::setNames("", "\u26a0 Lancez une simulation")
        op_avail <- stats::setNames("", "\u26a0 Lancez une simulation")
      }

      list(
        "\U0001f4e1 Sources externes" = ext_avail,
        "\U0001f3e0 Baseline"         = bl_avail,
        "\u2728 Optimis\u00e9"        = op_avail
      )
    }

    # Filter choices for serie 3: max 2 distinct units across all 3 series
    build_choices3 <- function(choices, v1, v2) {
      u1 <- get_unit(v1); u2 <- get_unit(v2)
      existing_units <- unique(stats::na.omit(c(u1, u2)))
      same_unit <- length(existing_units) <= 1
      filtered <- lapply(choices, function(group) {
        group[sapply(unname(group), function(v) {
          if (v == "" || v == v1 || v == v2) return(FALSE)
          u <- get_unit(v)
          if (is.na(u)) return(FALSE)
          if (same_unit) TRUE  # v1/v2 share a unit, v3 can bring a 2nd one
          else u %in% existing_units  # already 2 units, v3 must match one
        })]
      })
      filtered <- filtered[lengths(filtered) > 0]
      c(list("Aucune" = ""), filtered)
    }

    update_var3 <- function(choices, v1, v2) {
      c3 <- build_choices3(choices, v1, v2)
      cur3 <- shiny::isolate(input$compare_var3)
      sel <- if (!is.null(cur3) && cur3 %in% unlist(c3)) cur3 else ""
      shiny::updateSelectInput(session, "compare_var3", choices = c3, selected = sel)
    }

    # ---- Update selectInputs on external data load ----
    shiny::observeEvent(external_data(), {
      choices <- build_choices()
      shiny::updateSelectInput(session, "compare_var1", choices = choices,
        selected = if ("ext_pv" %in% unlist(choices)) "ext_pv" else unlist(choices)[1])
      shiny::updateSelectInput(session, "compare_var2", choices = choices,
        selected = if ("ext_prix" %in% unlist(choices)) "ext_prix" else unlist(choices)[min(2, length(unlist(choices)))])
      update_var3(choices,
        if ("ext_pv" %in% unlist(choices)) "ext_pv" else unlist(choices)[1],
        if ("ext_prix" %in% unlist(choices)) "ext_prix" else unlist(choices)[min(2, length(unlist(choices)))])
    })

    # ---- Update selectInputs when sim becomes available ----
    shiny::observeEvent(sim_result(), {
      choices <- build_choices()
      cur1 <- shiny::isolate(input$compare_var1)
      cur2 <- shiny::isolate(input$compare_var2)
      all_vals <- unlist(choices)
      sel1 <- if (!is.null(cur1) && cur1 %in% all_vals) cur1 else all_vals[1]
      sel2 <- if (!is.null(cur2) && cur2 %in% all_vals) cur2 else all_vals[min(2, length(all_vals))]
      shiny::updateSelectInput(session, "compare_var1", choices = choices, selected = sel1)
      shiny::updateSelectInput(session, "compare_var2", choices = choices, selected = sel2)
      update_var3(choices, sel1, sel2)
    })

    # ---- Update serie 3 choices when v1 or v2 changes ----
    shiny::observeEvent(list(input$compare_var1, input$compare_var2), {
      shiny::req(input$compare_var1, input$compare_var2)
      update_var3(build_choices(), input$compare_var1, input$compare_var2)
    })

    # ---- Sync compare_range with sidebar date range ----
    shiny::observeEvent(date_range(), {
      shiny::req(date_range())
      shiny::updateDateRangeInput(session, "compare_range",
        start = date_range()[1], end = date_range()[2],
        min = as.Date("2020-01-01"), max = Sys.Date())
    })

    # ---- Merge data for plotting ----
    compare_data <- shiny::reactive({
      shiny::req(input$compare_range)
      d1 <- as.POSIXct(input$compare_range[1], tz = "Europe/Brussels")
      d2 <- as.POSIXct(input$compare_range[2], tz = "Europe/Brussels") + lubridate::days(1)

      # Start from external data
      df <- external_data()
      df <- dplyr::filter(df, timestamp >= d1, timestamp < d2)

      # Merge sim data if available
      if (has_sim()) {
        sim <- sim_result()$sim
        sim_cols <- sim %>%
          dplyr::mutate(
            autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
            autoconso_opti = pmax(0, pv_kwh - sim_intake),
            facture_baseline = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
            facture_opti = sim_offtake * prix_offtake - sim_intake * prix_injection
          )
        # Join sim columns to external grid (robust: floor to 15 min both sides)
        sim_to_join <- sim_cols %>%
          dplyr::select(timestamp, dplyr::any_of(c(
            names(vars_baseline), names(vars_optimised),
            unname(vars_baseline), unname(vars_optimised)
          )))
        sim_val_cols <- intersect(names(sim_to_join), c(unname(vars_baseline), unname(vars_optimised)))
        sim_to_join <- sim_to_join[, c("timestamp", sim_val_cols)]
        sim_to_join$timestamp <- lubridate::floor_date(sim_to_join$timestamp, "15 min")
        df$timestamp <- lubridate::floor_date(df$timestamp, "15 min")
        df <- dplyr::left_join(df, sim_to_join, by = "timestamp")
      }

      df
    })

    # ---- Plot ----
    output$plot_compare <- plotly::renderPlotly({
      shiny::req(compare_data(), input$compare_var1, input$compare_var2)
      v1 <- input$compare_var1; v2 <- input$compare_var2
      v3 <- input$compare_var3
      if (v1 == "" || v2 == "") return(plotly::plot_ly())
      if (is.null(v3) || v3 == "") v3 <- NA_character_
      vars <- c(v1, v2, if (!is.na(v3)) v3 else NULL)

      df <- compare_data()
      if (!all(vars %in% names(df))) return(plotly::plot_ly())

      # Aggregate with proper sum/mean distinction
      df_sel <- df[, c("timestamp", vars)]
      sum_cols_sel <- intersect(vars, summable)
      agg <- auto_aggregate(df_sel, sum_cols = sum_cols_sel)
      df_agg <- agg$data
      agg_level <- agg$level

      # Resolve trace config for each variable
      unit1 <- get_unit(v1); unit2 <- get_unit(v2)
      configs <- resolve_trace_config(vars, agg_level, summable, get_unit,
                                       unit1, unit2)
      n_bars <- attr(configs, "n_bars_y1")

      all_sel <- c(v1, v2, if (!is.na(v3)) v3)
      colors <- pick_colors(all_sel)
      col1 <- colors[1]; col2 <- colors[2]

      rgba <- function(hex, alpha) {
        r <- strtoi(substr(hex, 2, 3), 16)
        g <- strtoi(substr(hex, 4, 5), 16)
        b <- strtoi(substr(hex, 6, 7), 16)
        sprintf("rgba(%d,%d,%d,%.2f)", r, g, b, alpha)
      }

      p <- plotly::plot_ly(df_agg, x = ~timestamp)

      # Add traces based on resolved config
      for (i in seq_along(vars)) {
        v <- vars[i]
        cfg <- configs[[v]]
        col <- colors[i]
        lbl <- names(all_vars)[all_vars == v]

        if (cfg$type == "bar") {
          opacity <- if (n_bars >= 2 && i > 1) cl$scenarios$optimise$bar_opacity
                     else if (n_bars >= 2) cl$scenarios$baseline$bar_opacity
                     else 0.7
          p <- p %>% plotly::add_bars(y = df_agg[[v]], name = lbl,
            marker = list(color = rgba(col, opacity)),
            yaxis = cfg$axis, textposition = "none")
        } else {
          fill_arg <- if (cfg$fill) "tozeroy" else "none"
          fill_col <- if (cfg$fill) rgba(col, 0.15) else "rgba(0,0,0,0)"
          p <- p %>% plotly::add_trace(y = df_agg[[v]], type = "scatter",
            mode = "lines", name = lbl,
            line = list(color = col, width = 2, dash = cfg$dash),
            fill = fill_arg, fillcolor = fill_col, yaxis = cfg$axis)
        }
      }

      # Axis titles: collect actual units placed on each axis
      y1_units <- unique(na.omit(sapply(vars[sapply(vars, function(v) configs[[v]]$axis == "y")], get_unit)))
      y2_units <- unique(na.omit(sapply(vars[sapply(vars, function(v) configs[[v]]$axis == "y2")], get_unit)))
      ytitle1 <- if (length(y1_units) > 0) paste(y1_units, collapse = " / ") else names(all_vars)[all_vars == v1]
      ytitle2 <- if (length(y2_units) > 0) paste(y2_units, collapse = " / ") else names(all_vars)[all_vars == v2]

      barmode <- if (n_bars >= 2) "group" else if (n_bars == 1) "overlay" else "group"

      p %>%
        pl_layout(agg_level = agg_level, n_points = nrow(df_agg)) %>%
        plotly::layout(
          yaxis = list(title = ytitle1, gridcolor = cl$grid,
            tickfont = list(size = 10, color = col1),
            titlefont = list(color = col1)),
          yaxis2 = list(title = ytitle2, overlaying = "y", side = "right",
            showgrid = FALSE,
            tickfont = list(size = 10, color = col2),
            titlefont = list(color = col2)),
          hovermode = "x unified",
          barmode = barmode
        )
    })
  })
}
