# =============================================================================
# MODULE OPEN-METEO — Temperatures historiques horaires
# =============================================================================
# Lit les temperatures horaires depuis les fichiers CSV locaux
# (data/openmeteo_temp_YYYY.csv), generes au prealable via l'API Open-Meteo.
# =============================================================================

#' Charge les temperatures historiques horaires depuis les CSV locaux
#'
#' @param start_date Date de debut (Date ou character YYYY-MM-DD)
#' @param end_date Date de fin (Date ou character YYYY-MM-DD)
#' @param data_dir Repertoire contenant les CSV
#' @return tibble avec colonnes: timestamp (POSIXct, Europe/Brussels), t_ext (°C)
load_openmeteo_temperature <- function(start_date, end_date, data_dir = "data") {

  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)

  years <- seq(year(start_date), year(end_date))
  all_data <- list()

  for (yr in years) {
    csv_file <- file.path(data_dir, sprintf("openmeteo_temp_%d.csv", yr))

    if (!file.exists(csv_file)) {
      warning(sprintf("[Open-Meteo] Fichier manquant: %s", csv_file))
      next
    }

    message(sprintf("[Open-Meteo] Lecture %s", csv_file))
    df_year <- readr::read_csv(csv_file, show_col_types = FALSE)
    df_year$timestamp <- as.POSIXct(df_year$timestamp, tz = "Europe/Brussels")
    all_data[[as.character(yr)]] <- df_year
  }

  if (length(all_data) == 0) {
    warning("[Open-Meteo] Aucun fichier CSV trouve")
    return(NULL)
  }

  df <- dplyr::bind_rows(all_data)
  df <- df %>%
    dplyr::filter(timestamp >= as.POSIXct(paste0(start_date, " 00:00:00"), tz = "Europe/Brussels"),
                  timestamp <= as.POSIXct(paste0(end_date, " 23:59:59"), tz = "Europe/Brussels")) %>%
    dplyr::arrange(timestamp)

  message(sprintf("[Open-Meteo] %d enregistrements horaires charges (%s a %s)",
                  nrow(df), start_date, end_date))
  df
}

#' Interpole les temperatures horaires au pas de 15 min
#'
#' @param df_hourly tibble avec colonnes timestamp et t_ext (horaire)
#' @param ts_15min Vecteur de timestamps au pas de 15 min
#' @return Vecteur de temperatures interpolees (meme longueur que ts_15min)
interpolate_temperature_15min <- function(df_hourly, ts_15min) {
  x_hourly <- as.numeric(df_hourly$timestamp)
  y_hourly <- df_hourly$t_ext
  x_target <- as.numeric(ts_15min)

  result <- approx(x_hourly, y_hourly, xout = x_target, rule = 2)$y

  if (any(is.na(result))) {
    result[is.na(result)] <- median(y_hourly, na.rm = TRUE)
    warning(sprintf("[Open-Meteo] %d valeurs interpolees remplacees par la mediane",
                    sum(is.na(result))))
  }

  round(result, 1)
}
