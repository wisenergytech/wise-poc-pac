# =============================================================================
# MODULE SOLAIRE ELIA — Production PV reelle du reseau belge
# =============================================================================
# Source : Elia Open Data Platform (API publique, sans cle)
#
# Datasets utilises :
#   - ODS032 : "Photovoltaic power production estimation and forecast on
#              Belgian grid (Historical)"
#              Historique depuis 2020-04-01, quart-horaire (PT15M), par region.
#   - ODS087 : "Photovoltaic power production estimation and forecast on
#              Belgian grid (Near real-time)"
#              Meme structure que ODS032 mais ne couvre que les ~7 derniers jours.
#              Utilise en fallback pour les donnees tres recentes.
#
# Champs recuperes :
#   - datetime          : horodatage UTC (ISO 8601)
#   - measured           : production PV reelle mesuree (MW) pour la region
#   - monitoredcapacity : capacite PV totale installee (MWc) dans la region
#   - loadfactor        : facteur de charge (measured / monitoredcapacity)
#
# Region par defaut : "Namur" (province de Profondeville).
#   La capacite monitoree pour Namur est ~449 MWc (avril 2026).
#
# Scaling vers une installation locale :
#   pv_kwh = measured_mw * 1000 * (target_kwc / monitoredcapacity_kwc)
#   Cela preserve le profil reel (nuages, meteo, saisons) tout en scalant
#   lineairement a la puissance crete de l'installation cible.
#
# Limites :
#   - Profil regional, pas site-specific : un jour couvert a Profondeville
#     mais ensoleille a Dinant sera moyenne sur la province de Namur.
#   - La Belgique etant petite (~300 km), les conditions intra-regionales
#     sont assez homogenes a l'echelle quart-horaire.
# =============================================================================

ELIA_SOLAR_BASE_URL <- "https://opendata.elia.be/api/explore/v2.1/catalog/datasets"
ELIA_SOLAR_PAGE_SIZE <- 100
ELIA_SOLAR_TIMEOUT <- 30

# Region par defaut : Namur (province de Profondeville)
ELIA_SOLAR_DEFAULT_REGION <- "Namur"

# ---------------------------------------------------------------------------
# Fonction principale : charger la production PV quart-horaire
# ---------------------------------------------------------------------------
#' Charge la production PV reelle quart-horaire depuis Elia Open Data
#'
#' Recupere les donnees mesurees de production photovoltaique pour une region
#' belge, au pas quart-horaire. Essaie d'abord ODS032 (historique complet),
#' puis ODS087 (near real-time, ~7 derniers jours) pour les donnees recentes.
#'
#' @param start_date Date de debut (Date, POSIXct, ou character YYYY-MM-DD)
#' @param end_date Date de fin
#' @param region Region Elia (default "Namur"). Valeurs possibles :
#'   "Belgium", "Brussels", "East-Flanders", "Flemish-Brabant", "Hainaut",
#'   "Liege", "Limburg", "Luxembourg", "Namur", "Walloon-Brabant",
#'   "West-Flanders", "Antwerp"
#' @return Liste avec :
#'   \describe{
#'     \item{df}{Tibble : datetime (POSIXct UTC), measured_mw (numeric),
#'       monitoredcapacity_mw (numeric), loadfactor (numeric)}
#'     \item{source}{Character : "ods032", "ods087", ou "none"}
#'     \item{region}{Region utilisee}
#'   }
#' @export
fetch_solar_elia <- function(start_date, end_date,
                             region = ELIA_SOLAR_DEFAULT_REGION) {

  start_date <- as.POSIXct(paste0(as.Date(start_date), " 00:00:00"), tz = "UTC")
  end_date   <- as.POSIXct(paste0(as.Date(end_date),   " 23:59:59"), tz = "UTC")

  # 1. ODS032 — historique complet
  df <- fetch_solar_dataset("ods032", start_date, end_date, region)
  if (!is.null(df) && nrow(df) > 0) {
    message(sprintf("[Solar Elia] ODS032 %s : %d enregistrements", region, nrow(df)))
    return(list(df = df, source = "ods032", region = region))
  }

  # 2. ODS087 — near real-time (fallback pour les 7 derniers jours)
  df <- fetch_solar_dataset("ods087", start_date, end_date, region)
  if (!is.null(df) && nrow(df) > 0) {
    message(sprintf("[Solar Elia] ODS087 %s : %d enregistrements", region, nrow(df)))
    return(list(df = df, source = "ods087", region = region))
  }

  message(sprintf("[Solar Elia] Aucune donnee pour %s (%s -> %s)",
    region, as.Date(start_date), as.Date(end_date)))
  list(df = NULL, source = "none", region = region)
}

# ---------------------------------------------------------------------------
# Fetch pagine depuis un dataset Elia (ODS032 ou ODS087)
# ---------------------------------------------------------------------------
fetch_solar_dataset <- function(dataset_id, start_date, end_date, region) {
  tryCatch({
    start_str <- format(start_date, "%Y-%m-%dT%H:%M:%S")
    end_str   <- format(end_date,   "%Y-%m-%dT%H:%M:%S")
    url <- sprintf("%s/%s/records", ELIA_SOLAR_BASE_URL, dataset_id)

    where_clause <- sprintf(
      'datetime >= "%s" AND datetime <= "%s" AND region = "%s"',
      start_str, end_str, region
    )

    all_records <- list()
    offset <- 0

    repeat {
      resp <- httr::GET(url,
        query = list(
          limit    = ELIA_SOLAR_PAGE_SIZE,
          offset   = offset,
          order_by = "datetime",
          where    = where_clause,
          select   = "datetime,measured,monitoredcapacity,loadfactor"
        ),
        httr::timeout(ELIA_SOLAR_TIMEOUT)
      )

      if (httr::status_code(resp) != 200) return(NULL)

      data <- httr::content(resp, as = "parsed", simplifyVector = TRUE)
      records <- data$results
      if (is.null(records) || length(records) == 0 || nrow(records) == 0) break

      all_records[[length(all_records) + 1]] <- records
      total <- data$total_count
      if (is.null(total)) total <- 0
      offset <- offset + nrow(records)
      if (offset >= total) break
    }

    if (length(all_records) == 0) return(NULL)

    df <- dplyr::bind_rows(all_records)

    # Parser datetime : supprimer le suffixe timezone avant conversion
    df$datetime <- as.POSIXct(
      sub("[+-]\\d{2}:\\d{2}$", "", df$datetime),
      format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"
    )

    df <- dplyr::rename(df,
      measured_mw         = measured,
      monitoredcapacity_mw = monitoredcapacity
    )
    df <- dplyr::select(df, datetime, measured_mw, monitoredcapacity_mw, loadfactor)
    df <- dplyr::filter(df, !is.na(datetime))
    df <- dplyr::distinct(df, datetime, .keep_all = TRUE)
    df <- dplyr::arrange(df, datetime)

    # Remplacer NA par 0 pour measured (nuit = pas de production)
    df$measured_mw[is.na(df$measured_mw)] <- 0

    if (nrow(df) == 0) return(NULL)
    df
  }, error = function(e) {
    message(sprintf("[Solar Elia] Erreur %s : %s", dataset_id, e$message))
    NULL
  })
}

# ---------------------------------------------------------------------------
# Scaling : production regionale -> installation locale
# ---------------------------------------------------------------------------
#' Scale la production PV regionale Elia vers une installation locale
#'
#' Applique un scaling lineaire base sur le ratio entre la puissance crete
#' cible et la capacite monitoree de la region. La production mesuree (MW)
#' est convertie en kWh par quart d'heure.
#'
#' @param df Tibble retourne par fetch_solar_elia()$df
#' @param target_kwc Puissance crete de l'installation cible (kWc)
#' @return Le dataframe d'entree avec une colonne supplementaire pv_kwh
#'   (production estimee pour l'installation cible, en kWh par quart d'heure)
#' @export
scale_solar_to_local <- function(df, target_kwc) {
  # monitoredcapacity est en MW, convertir en kWc pour le ratio
  ratio <- target_kwc / (df$monitoredcapacity_mw * 1000)

  # measured_mw est une puissance moyenne sur 15 min -> energie = P * 0.25h
  # Convertir MW en kW (* 1000) puis en kWh (* 0.25)
  df$pv_kwh <- df$measured_mw * 1000 * 0.25 * ratio

  df
}
