# =============================================================================
# SCRIPT — Recuperation donnees PV 5-min FusionSolar (Historical Device API)
# =============================================================================
# Recupere les donnees 5-min de production PV pour l'installation NE=146048791
# via l'endpoint /rest/openapi/pvms/nbi/v1/device/history.
#
# REPRISE AUTOMATIQUE: le script sauvegarde au fur et a mesure dans le CSV.
# Si interrompu (coupure reseau, Ctrl+C...), relancer simplement le script:
# il detecte les jours deja recuperes et reprend la ou il s'est arrete.
#
# Rate limit: ~1 appel/200s par inverseur (type 38). 3 inverseurs = ~3.3 min.
# Duree estimee: ~21h pour 1 an (en continu).
#
# Usage: Rscript scripts/fetch_fusionsolar.R
# Ou en fond: nohup Rscript scripts/fetch_fusionsolar.R > fetch.log 2>&1 &
#
# Sortie: data/fusionsolar_5min_YYYY.csv
# =============================================================================

library(httr)
library(dplyr)
library(lubridate)
library(readr)

# --- Configuration ---
PLANT_CODE <- "NE=146048791"
INVERTER_DNS <- c("NE=146049818", "NE=146048777", "NE=193143992")
DEV_TYPE_ID <- 38  # residential inverter
YEARS <- c(2026)
DATA_DIR <- "data"
PAUSE_SECONDS <- 210  # 3.5 min entre appels (marge sur les 200s theoriques)
RETRY_PAUSE <- 300    # 5 min si rate limited
MAX_RETRIES <- 5

# --- Charger .env ---
if (file.exists(".env")) {
  env_lines <- readLines(".env", warn = FALSE)
  for (line in env_lines) {
    line <- trimws(line)
    if (nchar(line) == 0 || startsWith(line, "#")) next
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      val <- trimws(paste(parts[-1], collapse = "="))
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

BASE_URL <- Sys.getenv("NUXT_FUSIONSOLAR_URL", Sys.getenv("FUSIONSOLAR_URL", "https://eu5.fusionsolar.huawei.com"))
USERNAME <- Sys.getenv("NUXT_FUSIONSOLAR_USERNAME", Sys.getenv("FUSIONSOLAR_USERNAME", ""))
PASSWORD <- Sys.getenv("NUXT_FUSIONSOLAR_PASSWORD", Sys.getenv("FUSIONSOLAR_PASSWORD", ""))

if (USERNAME == "" || PASSWORD == "") {
  stop("Credentials FusionSolar manquants dans .env")
}

`%||%` <- function(a, b) if (is.null(a) || is.na(a)) b else a

# =============================================================================
# 1. Login (avec re-login automatique si token expire)
# =============================================================================
TOKEN <- NULL
TOKEN_TIME <- NULL

ensure_token <- function() {
  # Re-login si pas de token ou si > 25 min (token valide 30 min)
  if (is.null(TOKEN) || is.null(TOKEN_TIME) ||
      difftime(Sys.time(), TOKEN_TIME, units = "mins") > 25) {
    cat(sprintf("[%s] Login...\n", format(Sys.time(), "%H:%M:%S")))
    resp <- POST(
      paste0(BASE_URL, "/thirdData/login"),
      body = list(userName = USERNAME, systemCode = PASSWORD),
      encode = "json", content_type_json()
    )
    if (status_code(resp) != 200) stop(sprintf("Login echoue: HTTP %d", status_code(resp)))

    body <- content(resp, as = "parsed")
    if (!is.null(body$failCode) && body$failCode != 0) {
      stop(sprintf("Login echoue: failCode=%s", body$failCode))
    }

    cks <- cookies(resp)
    xsrf <- cks$value[cks$name == "XSRF-TOKEN"]
    if (length(xsrf) == 0 || is.na(xsrf)) stop("XSRF-TOKEN non trouve")

    TOKEN <<- xsrf
    TOKEN_TIME <<- Sys.time()
    cat(sprintf("[%s] Login OK\n", format(Sys.time(), "%H:%M:%S")))
  }
  TOKEN
}

# =============================================================================
# 2. Appel Historical Device Data avec retry + backoff
# =============================================================================
fetch_device_day <- function(dev_dn, date) {
  start_ts <- as.numeric(as.POSIXct(paste0(date, " 00:00:00"), tz = "Europe/Brussels")) * 1000
  end_ts   <- as.numeric(as.POSIXct(paste0(as.Date(date) + 1, " 00:00:00"), tz = "Europe/Brussels")) * 1000

  for (attempt in seq_len(MAX_RETRIES)) {
    token <- ensure_token()

    resp <- tryCatch(
      POST(
        paste0(BASE_URL, "/rest/openapi/pvms/nbi/v1/device/history"),
        body = list(devDn = dev_dn, devTypeId = DEV_TYPE_ID,
                    startTime = start_ts, endTime = end_ts),
        encode = "json", content_type_json(),
        add_headers("XSRF-TOKEN" = token),
        set_cookies("XSRF-TOKEN" = token),
        timeout(30)
      ),
      error = function(e) {
        cat(sprintf("  [Erreur reseau] %s — retry dans %ds\n", e$message, RETRY_PAUSE))
        NULL
      }
    )

    if (is.null(resp)) {
      Sys.sleep(RETRY_PAUSE)
      next
    }

    if (status_code(resp) != 200) {
      cat(sprintf("  HTTP %d — retry dans %ds\n", status_code(resp), RETRY_PAUSE))
      Sys.sleep(RETRY_PAUSE)
      next
    }

    result <- content(resp, as = "parsed")

    # Token expire → force re-login
    if (!is.null(result$failCode) && result$failCode == 305) {
      cat("  [Token expire] Re-login...\n")
      TOKEN <<- NULL
      next
    }

    # Rate limit → attendre
    if (!is.null(result$failCode) && result$failCode == 407) {
      wait <- RETRY_PAUSE * attempt
      cat(sprintf("  [Rate limit 407] Pause %ds (attempt %d/%d)\n", wait, attempt, MAX_RETRIES))
      Sys.sleep(wait)
      next
    }

    if (!is.null(result$failCode) && result$failCode != 0) {
      cat(sprintf("  failCode=%s — skip\n", result$failCode))
      return(NULL)
    }

    # Succes
    return(result$data)
  }

  cat(sprintf("  Echec apres %d tentatives pour %s %s\n", MAX_RETRIES, dev_dn, date))
  NULL
}

# =============================================================================
# 3. Parser les records 5-min d'un inverseur
# =============================================================================
parse_inverter_records <- function(data, dev_dn) {
  if (is.null(data) || length(data) == 0) return(NULL)

  rows <- lapply(data, function(item) {
    d <- item$dataItems
    tibble(
      timestamp = as.POSIXct(item$collectTime / 1000, origin = "1970-01-01", tz = "Europe/Brussels"),
      dev_dn = dev_dn,
      active_power_kw = as.numeric(d$active_power %||% NA),
      day_cap_kwh = as.numeric(d$day_cap %||% NA),
      temperature_c = as.numeric(d$temperature %||% NA),
      efficiency_pct = as.numeric(d$efficiency %||% NA),
      mppt_power_kw = as.numeric(d$mppt_power %||% NA)
    )
  })

  bind_rows(rows)
}

# =============================================================================
# 4. Charger les dates deja recuperees depuis le CSV existant
# =============================================================================
load_existing_dates <- function(output_file) {
  if (!file.exists(output_file)) return(character(0))

  df <- read_csv(output_file, show_col_types = FALSE)
  if (nrow(df) == 0) return(character(0))

  df$timestamp <- as.POSIXct(df$timestamp, tz = "Europe/Brussels")
  unique(as.character(as.Date(df$timestamp, tz = "Europe/Brussels")))
}

# =============================================================================
# 5. Sauvegarder en mode append (ajouter au CSV existant)
# =============================================================================
append_to_csv <- function(df_new, output_file) {
  if (file.exists(output_file)) {
    df_existing <- read_csv(output_file, show_col_types = FALSE)
    df_existing$timestamp <- as.POSIXct(df_existing$timestamp, tz = "Europe/Brussels")
    df_all <- bind_rows(df_existing, df_new) %>%
      arrange(timestamp, dev_dn) %>%
      distinct(timestamp, dev_dn, .keep_all = TRUE)
  } else {
    df_all <- df_new %>% arrange(timestamp, dev_dn)
  }

  write_csv(df_all, output_file)
  df_all
}

# =============================================================================
# 6. Execution principale
# =============================================================================
if (!dir.exists(DATA_DIR)) dir.create(DATA_DIR, recursive = TRUE)

cat(sprintf("[FusionSolar] Plant: %s\n", PLANT_CODE))
cat(sprintf("[FusionSolar] Inverseurs: %s\n", paste(INVERTER_DNS, collapse = ", ")))
cat(sprintf("[FusionSolar] Pause entre appels: %ds\n", PAUSE_SECONDS))
cat(sprintf("[FusionSolar] Annees: %s\n\n", paste(YEARS, collapse = ", ")))

for (yr in YEARS) {
  output_file <- file.path(DATA_DIR, sprintf("fusionsolar_5min_%d.csv", yr))

  # Dates deja recuperees
  existing_dates <- load_existing_dates(output_file)
  cat(sprintf("[%d] %d jours deja recuperes\n", yr, length(existing_dates)))

  # Toutes les dates de l'annee
  year_start <- as.Date(sprintf("%d-01-01", yr))
  year_end <- min(as.Date(sprintf("%d-12-31", yr)), Sys.Date() - 1)
  all_dates <- as.character(seq(year_start, year_end, by = "day"))

  # Filtrer celles deja faites
  dates_todo <- setdiff(all_dates, existing_dates)

  if (length(dates_todo) == 0) {
    cat(sprintf("[%d] Complet!\n\n", yr))
    next
  }

  cat(sprintf("[%d] %d jours restants a recuperer\n", yr, length(dates_todo)))

  for (date in dates_todo) {
    cat(sprintf("\n[%s] %s\n", format(Sys.time(), "%H:%M:%S"), date))

    day_data <- list()

    for (dev_dn in INVERTER_DNS) {
      data <- fetch_device_day(dev_dn, date)
      df <- parse_inverter_records(data, dev_dn)

      if (!is.null(df) && nrow(df) > 0) {
        day_data[[length(day_data) + 1]] <- df
        total_kw <- sum(df$active_power_kw, na.rm = TRUE)
        cat(sprintf("  %s: %d records, sum(active_power)=%.1f kW\n",
                    dev_dn, nrow(df), total_kw))
      } else {
        cat(sprintf("  %s: aucune donnee\n", dev_dn))
      }

      # Pause entre chaque appel inverseur
      Sys.sleep(PAUSE_SECONDS)
    }

    # Sauvegarder les donnees du jour immediatement
    if (length(day_data) > 0) {
      df_day <- bind_rows(day_data)
      df_all <- append_to_csv(df_day, output_file)
      n_days <- length(unique(as.Date(df_all$timestamp, tz = "Europe/Brussels")))
      cat(sprintf("  -> Sauvegarde: %d lignes total, %d jours\n", nrow(df_all), n_days))
    }
  }

  cat(sprintf("\n[%d] Termine!\n\n", yr))
}

cat(sprintf("\n[FusionSolar] Script termine a %s\n", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
cat("[FusionSolar] Si des jours manquent, relancer le script — il reprendra automatiquement.\n")
