#' Detect timestep from a vector of POSIXct timestamps
#'
#' Uses the median of the first 10 consecutive diffs to determine
#' the resolution (5min, 15min, 60min). Returns "irregular" if no
#' standard step matches within 10% tolerance.
#'
#' @param timestamps POSIXct vector (sorted)
#' @return Character: "5min", "15min", "30min", "60min", or "irregular"
#' @noRd
detect_timestep <- function(timestamps) {
  if (length(timestamps) < 3) return("irregular")
  diffs_sec <- as.numeric(diff(timestamps[1:min(11, length(timestamps))]), units = "secs")
  diffs_sec <- diffs_sec[diffs_sec > 0]
  if (length(diffs_sec) == 0) return("irregular")

  med_sec <- stats::median(diffs_sec)
  standards <- c("5min" = 300, "15min" = 900, "30min" = 1800, "60min" = 3600)
  matches <- abs(standards - med_sec) / standards < 0.10
  if (any(matches)) names(which.min(abs(standards - med_sec))) else "irregular"
}

#' Parse installation CSV (monitoring PAC)
#'
#' Reads the CSV, detects timestep, aggregates to 15 min if needed.
#' Expected columns: time (or timestamp), Elec_consumption (required),
#' COP, T_tankUp, GSHP_power, ASHP_power (optional).
#'
#' @param file_path Path to CSV file
#' @return List with: df (dataframe at 15-min), timestep (detected), report (character vector)
#' @noRd
parse_installation_csv <- function(file_path) {
  df <- readr::read_csv(file_path, show_col_types = FALSE)
  report <- character(0)

  # Detect timestamp column
  ts_col <- if ("time" %in% names(df)) "time" else if ("timestamp" %in% names(df)) "timestamp" else NULL
  if (is.null(ts_col)) stop("Colonne 'time' ou 'timestamp' introuvable dans le CSV installation")
  df$timestamp <- as.POSIXct(df[[ts_col]], tz = "Europe/Brussels")
  df <- df[!is.na(df$timestamp), ]
  df <- df[order(df$timestamp), ]

  # Validate required column
  if (!"Elec_consumption" %in% names(df)) {
    stop("Colonne 'Elec_consumption' obligatoire absente du CSV installation")
  }

  # Detect timestep
  timestep <- detect_timestep(df$timestamp)
  report <- c(report, sprintf("Pas de temps d\u00e9tect\u00e9 (installation) : %s", timestep))

  # Aggregate to 15 min if needed
  if (timestep %in% c("5min", "irregular")) {
    df$qt <- lubridate::floor_date(df$timestamp, unit = "15 minutes")

    # Define aggregation per column
    sum_cols <- intersect(c("Elec_consumption", "GSHP_power", "ASHP_power"), names(df))
    mean_cols <- intersect(c("COP", "T_tankUp", "SP_tank", "SP_supply"), names(df))

    agg_list <- list()
    for (col in sum_cols) agg_list[[col]] <- sum(df[[col]], na.rm = TRUE)
    for (col in mean_cols) {
      vals <- df[[col]]
      agg_list[[col]] <- if (all(is.na(vals))) NA_real_ else mean(vals, na.rm = TRUE)
    }

    df_agg <- df %>%
      dplyr::group_by(qt) %>%
      dplyr::summarise(
        dplyr::across(dplyr::all_of(sum_cols), ~ sum(.x, na.rm = TRUE)),
        dplyr::across(dplyr::all_of(mean_cols), ~ if (all(is.na(.x))) NA_real_ else mean(.x, na.rm = TRUE)),
        .groups = "drop"
      ) %>%
      dplyr::rename(timestamp = qt)

    report <- c(report, sprintf("Agr\u00e9gation %s \u2192 15 min appliqu\u00e9e (%d \u2192 %d points)",
      timestep, nrow(df), nrow(df_agg)))
    df <- df_agg
  } else if (timestep == "15min") {
    # Already at 15 min, just keep relevant columns
    keep_cols <- intersect(
      c("timestamp", "Elec_consumption", "COP", "T_tankUp", "SP_tank", "SP_supply", "GSHP_power", "ASHP_power"),
      names(df)
    )
    df <- df[, keep_cols, drop = FALSE]
  } else if (timestep == "30min" || timestep == "60min") {
    report <- c(report, sprintf("Warning : pas de temps %s, pas d'agr\u00e9gation (r\u00e9solution > 15 min)", timestep))
    keep_cols <- intersect(
      c("timestamp", "Elec_consumption", "COP", "T_tankUp", "SP_tank", "SP_supply", "GSHP_power", "ASHP_power"),
      names(df)
    )
    df <- df[, keep_cols, drop = FALSE]
  }

  # Rename to standard internal names
  names(df)[names(df) == "Elec_consumption"] <- "elec_kwh"
  names(df)[names(df) == "T_tankUp"] <- "t_ballon"
  names(df)[names(df) == "COP"] <- "cop"
  names(df)[names(df) == "GSHP_power"] <- "gshp_kw"
  names(df)[names(df) == "ASHP_power"] <- "ashp_kw"

  report <- c(report, sprintf("%d quarts d'heure (%s \u2192 %s)",
    nrow(df), format(min(df$timestamp), "%Y-%m-%d"), format(max(df$timestamp), "%Y-%m-%d")))

  list(df = df, timestep = timestep, report = report)
}

#' Parse ORES CSV (meter data with cumulative indexes)
#'
#' Reads the CSV, detects timestep, aggregates to 15 min, converts
#' cumulative indexes to per-period deltas.
#'
#' @param file_path Path to CSV file
#' @return List with: df (dataframe at 15-min with offtake_kwh, feedin_kwh), timestep, report
#' @noRd
parse_ores_csv <- function(file_path) {
  df <- readr::read_csv(file_path, show_col_types = FALSE)
  report <- character(0)

  # Detect timestamp column
  ts_col <- if ("time" %in% names(df)) "time" else if ("timestamp" %in% names(df)) "timestamp" else NULL
  if (is.null(ts_col)) stop("Colonne 'time' ou 'timestamp' introuvable dans le CSV ORES")
  df$timestamp <- as.POSIXct(df[[ts_col]], tz = "Europe/Brussels")
  df <- df[!is.na(df$timestamp), ]
  df <- df[order(df$timestamp), ]

  # Validate required columns
  required <- c("Consumption_index_kWh", "Injection_index_kWh")
  missing <- setdiff(required, names(df))
  if (length(missing) > 0) {
    stop(sprintf("Colonnes obligatoires absentes du CSV ORES : %s", paste(missing, collapse = ", ")))
  }

  # Detect timestep
  timestep <- detect_timestep(df$timestamp)
  report <- c(report, sprintf("Pas de temps d\u00e9tect\u00e9 (ORES) : %s", timestep))

  # Aggregate to 15 min: take last index per quarter-hour
  df$qt <- lubridate::floor_date(df$timestamp, unit = "15 minutes")
  df_agg <- df %>%
    dplyr::filter(!is.na(Consumption_index_kWh)) %>%
    dplyr::group_by(qt) %>%
    dplyr::summarise(
      cons_idx = dplyr::last(Consumption_index_kWh),
      inj_idx = dplyr::last(Injection_index_kWh),
      .groups = "drop"
    ) %>%
    dplyr::arrange(qt) %>%
    dplyr::mutate(
      offtake_kwh = pmax(0, cons_idx - dplyr::lag(cons_idx), na.rm = TRUE),
      feedin_kwh = pmax(0, inj_idx - dplyr::lag(inj_idx), na.rm = TRUE)
    ) %>%
    dplyr::select(timestamp = qt, offtake_kwh, feedin_kwh)

  # Count negative deltas (before pmax clamping) for reporting
  raw_deltas <- diff(df$Consumption_index_kWh[!is.na(df$Consumption_index_kWh)])
  n_neg <- sum(raw_deltas < 0, na.rm = TRUE)
  if (n_neg > 0) {
    report <- c(report, sprintf("Warning : %d deltas n\u00e9gatifs (index d\u00e9croissant) mis \u00e0 0", n_neg))
  }

  if (timestep != "15min") {
    report <- c(report, sprintf("Agr\u00e9gation %s \u2192 15 min appliqu\u00e9e", timestep))
  }
  report <- c(report, sprintf("%d quarts d'heure (%s \u2192 %s)",
    nrow(df_agg), format(min(df_agg$timestamp), "%Y-%m-%d"), format(max(df_agg$timestamp), "%Y-%m-%d")))

  list(df = df_agg, timestep = timestep, report = report)
}

#' Join installation and ORES dataframes by timestamp
#'
#' Inner join on the common period. Reports excluded points.
#'
#' @param df_install Dataframe from parse_installation_csv()$df
#' @param df_ores Dataframe from parse_ores_csv()$df
#' @return List with: df (joined), n_points, date_start, date_end, n_excluded, report
#' @noRd
join_sources <- function(df_install, df_ores) {
  df <- dplyr::inner_join(df_install, df_ores, by = "timestamp")
  n_total <- max(nrow(df_install), nrow(df_ores))
  n_excluded <- n_total - nrow(df)

  report <- character(0)
  if (nrow(df) == 0) {
    stop("Aucun timestamp commun entre les deux fichiers. V\u00e9rifiez les p\u00e9riodes.")
  }
  if (n_excluded > 0) {
    report <- c(report, sprintf("Warning : %d pas de temps exclus (p\u00e9riode non commune)", n_excluded))
  }
  report <- c(report, sprintf("Jointure : %d quarts d'heure (%s \u2192 %s)",
    nrow(df), format(min(df$timestamp), "%Y-%m-%d"), format(max(df$timestamp), "%Y-%m-%d")))

  list(
    df = df,
    n_points = nrow(df),
    date_start = min(df$timestamp),
    date_end = max(df$timestamp),
    n_excluded = n_excluded,
    report = report
  )
}
