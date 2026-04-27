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
    palette_external  <- c(cl$accent3, cl$prix, cl$danger)

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

    # ---- Update selectInputs on external data load ----
    shiny::observeEvent(external_data(), {
      choices <- build_choices()
      shiny::updateSelectInput(session, "compare_var1", choices = choices,
        selected = if ("ext_pv" %in% unlist(choices)) "ext_pv" else unlist(choices)[1])
      shiny::updateSelectInput(session, "compare_var2", choices = choices,
        selected = if ("ext_prix" %in% unlist(choices)) "ext_prix" else unlist(choices)[min(2, length(unlist(choices)))])
      choices3 <- c(list("Aucune" = ""), choices)
      shiny::updateSelectInput(session, "compare_var3", choices = choices3, selected = "")
    })

    # ---- Update selectInputs when sim becomes available ----
    shiny::observeEvent(sim_result(), {
      choices <- build_choices()
      cur1 <- shiny::isolate(input$compare_var1)
      cur2 <- shiny::isolate(input$compare_var2)
      cur3 <- shiny::isolate(input$compare_var3)
      all_vals <- unlist(choices)
      shiny::updateSelectInput(session, "compare_var1", choices = choices,
        selected = if (!is.null(cur1) && cur1 %in% all_vals) cur1 else all_vals[1])
      shiny::updateSelectInput(session, "compare_var2", choices = choices,
        selected = if (!is.null(cur2) && cur2 %in% all_vals) cur2 else all_vals[min(2, length(all_vals))])
      choices3 <- c(list("Aucune" = ""), choices)
      shiny::updateSelectInput(session, "compare_var3", choices = choices3,
        selected = if (!is.null(cur3) && cur3 %in% all_vals) cur3 else "")
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
        # Join sim columns to external grid
        sim_to_join <- sim_cols %>%
          dplyr::select(timestamp, dplyr::any_of(c(
            names(vars_baseline), names(vars_optimised),
            unname(vars_baseline), unname(vars_optimised)
          )))
        # Keep only value columns (not labels)
        sim_val_cols <- intersect(names(sim_to_join), c(unname(vars_baseline), unname(vars_optimised)))
        sim_to_join <- sim_to_join[, c("timestamp", sim_val_cols)]
        df <- dplyr::left_join(df, sim_to_join, by = "timestamp")
      }

      df
    })

    # ---- Plot ----
    output$plot_compare <- plotly::renderPlotly({
      shiny::req(compare_data(), input$compare_var1, input$compare_var2)
      v1 <- input$compare_var1; v2 <- input$compare_var2
      v3 <- input$compare_var3
      # Ignore placeholder selections
      if (v1 == "" || v2 == "") return(plotly::plot_ly())
      if (is.null(v3) || v3 == "") v3 <- NA_character_
      vars <- c(v1, v2, if (!is.na(v3)) v3 else NULL)

      df <- compare_data()
      if (!all(vars %in% names(df))) return(plotly::plot_ly())

      nr <- nrow(df)
      level <- if (nr <= 14 * 96) "qt" else if (nr <= 60 * 96) "hour" else if (nr <= 180 * 96) "day" else "week"
      label <- c(qt = "15 min", hour = "Horaire", day = "Journalier", week = "Hebdomadaire")[level]

      df_work <- df %>% dplyr::mutate(.w = dplyr::case_when(
        level == "qt" ~ timestamp,
        level == "hour" ~ lubridate::floor_date(timestamp, "hour"),
        level == "day" ~ lubridate::floor_date(timestamp, "day"),
        level == "week" ~ lubridate::floor_date(timestamp, "week")
      ))
      agg_exprs <- lapply(vars, function(v) {
        if (v %in% summable) rlang::expr(sum(.data[[!!v]], na.rm = TRUE))
        else rlang::expr(mean(.data[[!!v]], na.rm = TRUE))
      })
      names(agg_exprs) <- vars
      df_agg <- df_work %>% dplyr::group_by(.w) %>%
        dplyr::summarise(!!!agg_exprs, .groups = "drop") %>%
        dplyr::rename(timestamp = .w)

      label1 <- names(all_vars)[all_vars == v1]
      label2 <- names(all_vars)[all_vars == v2]

      all_sel <- c(v1, v2, if (!is.na(v3)) v3)
      colors <- pick_colors(all_sel)
      col1 <- colors[1]; col2 <- colors[2]

      rgba <- function(hex, alpha) {
        r <- strtoi(substr(hex, 2, 3), 16)
        g <- strtoi(substr(hex, 4, 5), 16)
        b <- strtoi(substr(hex, 6, 7), 16)
        sprintf("rgba(%d,%d,%d,%.2f)", r, g, b, alpha)
      }

      add_line_trace <- function(p, y_vals, label, color, yaxis, dash = NULL) {
        p %>% plotly::add_trace(y = y_vals, type = "scatter", mode = "lines",
          fill = "tozeroy", fillcolor = rgba(color, 0.15),
          name = label, line = list(color = color, width = 2, dash = dash), yaxis = yaxis)
      }

      # Overlay bars: both start from 0, smaller drawn first, delta on top
      add_overlay_bars <- function(p, vals_a, vals_b, label_a, label_b, col_a, col_b, yaxis) {
        bottom <- pmin(vals_a, vals_b, na.rm = TRUE)
        top    <- pmax(vals_a, vals_b, na.rm = TRUE) - bottom
        a_bigger <- vals_a > vals_b
        bottom_col <- ifelse(a_bigger, col_b, col_a)
        top_col    <- ifelse(a_bigger, col_a, col_b)
        hover <- sprintf("%s: %.1f<br>%s: %.1f", label_a, vals_a, label_b, vals_b)
        p %>%
          plotly::add_bars(y = bottom, name = "Commun", showlegend = FALSE,
            marker = list(color = bottom_col), text = hover, hoverinfo = "text+x", yaxis = yaxis) %>%
          plotly::add_bars(y = top, name = "Delta", showlegend = FALSE,
            marker = list(color = top_col), text = hover, hoverinfo = "text+x", yaxis = yaxis) %>%
          plotly::add_bars(y = 0, name = label_a, marker = list(color = col_a),
            showlegend = TRUE, hoverinfo = "skip", yaxis = yaxis) %>%
          plotly::add_bars(y = 0, name = label_b, marker = list(color = col_b),
            showlegend = TRUE, hoverinfo = "skip", yaxis = yaxis)
      }

      # Identify bar variables per axis
      unit1 <- get_unit(v1); unit2 <- get_unit(v2)
      bar_y  <- vars[vars %in% summable & sapply(vars, function(v) {
        u <- get_unit(v); !is.na(u) && !is.na(unit1) && u == unit1
      })]
      bar_y2 <- vars[vars %in% summable & sapply(vars, function(v) {
        u <- get_unit(v); !is.na(u) && !is.na(unit2) && u == unit2
      }) & !(vars %in% bar_y)]

      p <- plotly::plot_ly(df_agg, x = ~timestamp)

      # Bars on y-axis: overlay if 2+, simple if 1
      if (length(bar_y) >= 2) {
        idx_a <- which(all_sel == bar_y[1]); idx_b <- which(all_sel == bar_y[2])
        p <- add_overlay_bars(p, df_agg[[bar_y[1]]], df_agg[[bar_y[2]]],
          names(all_vars)[all_vars == bar_y[1]], names(all_vars)[all_vars == bar_y[2]],
          colors[idx_a], colors[idx_b], "y")
      } else if (length(bar_y) == 1) {
        idx <- which(all_sel == bar_y[1])
        p <- p %>% plotly::add_bars(y = df_agg[[bar_y[1]]],
          name = names(all_vars)[all_vars == bar_y[1]],
          marker = list(color = rgba(colors[idx], 0.7)), yaxis = "y")
      }

      # Bars on y2-axis: overlay if 2+, simple if 1
      if (length(bar_y2) >= 2) {
        idx_a <- which(all_sel == bar_y2[1]); idx_b <- which(all_sel == bar_y2[2])
        p <- add_overlay_bars(p, df_agg[[bar_y2[1]]], df_agg[[bar_y2[2]]],
          names(all_vars)[all_vars == bar_y2[1]], names(all_vars)[all_vars == bar_y2[2]],
          colors[idx_a], colors[idx_b], "y2")
      } else if (length(bar_y2) == 1) {
        idx <- which(all_sel == bar_y2[1])
        p <- p %>% plotly::add_bars(y = df_agg[[bar_y2[1]]],
          name = names(all_vars)[all_vars == bar_y2[1]],
          marker = list(color = rgba(colors[idx], 0.7)), yaxis = "y2")
      }

      # Line traces for non-bar variables
      line_vars <- setdiff(vars, c(bar_y, bar_y2))
      for (lv in line_vars) {
        idx <- which(all_sel == lv)
        lbl <- names(all_vars)[all_vars == lv]
        u <- get_unit(lv)
        ax <- if (!is.na(u) && !is.na(unit1) && u == unit1) "y"
              else if (!is.na(u) && !is.na(unit2) && u == unit2) "y2"
              else "y"
        dash <- if (idx >= 3) "dot" else NULL
        p <- add_line_trace(p, df_agg[[lv]], lbl, colors[idx], ax, dash)
      }

      p %>% plotly::layout(
        title = paste0("Agr\u00e9gation: ", label),
        yaxis = list(title = label1, tickfont = list(color = col1),
          titlefont = list(color = col1)),
        yaxis2 = list(title = label2, overlaying = "y", side = "right",
          tickfont = list(color = col2), titlefont = list(color = col2),
          gridcolor = "rgba(0,0,0,0)"),
        hovermode = "x unified",
        barmode = "stack"
      ) %>%
        pl_layout()
    })
  })
}
