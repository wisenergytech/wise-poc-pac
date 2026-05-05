# =============================================================================
# Analyse Karno Profondeville — Metriques pour slide de presentation
# =============================================================================
# Calcule les KPIs baseline (mesure) a partir de bq_k0001_elia.csv
# et reconstitue les metriques financieres avec prix spot ENTSO-E.
#
# Parametres simulation (depuis status bar) :
#   LP, 159j, 12756 pts, GAIN 1054 EUR (33%)
#   PV=64 kWc, PAC=60 kW, COP=3.5, Ballon=32000L [45..55] consigne=50
#   Contrat=spot (taxe=0.150, coeff_inj=1.00), TOU=on, Baseline=Mesuree
#   Source: bq_k0001_elia.csv
# =============================================================================

library(dplyr)
library(lubridate)
library(readr)

# --- 1. Charger les donnees mesurees (= baseline) ---
df <- read_csv("inst/extdata/bq_k0001_elia.csv", show_col_types = FALSE)
df$timestamp <- ymd_hms(df$timestamp, tz = "Europe/Brussels")

cat("=== DONNEES KARNO PROFONDEVILLE ===\n")
cat(sprintf("Periode : %s -> %s\n",
  format(min(df$timestamp), "%Y-%m-%d"),
  format(max(df$timestamp), "%Y-%m-%d")))
n_days <- as.numeric(difftime(max(df$timestamp), min(df$timestamp), units = "days"))
cat(sprintf("Duree   : %.0f jours, %d points (pas de 15 min)\n", n_days, nrow(df)))

# --- 2. Charger les prix spot ENTSO-E ---
price_files <- list.files("data", pattern = "entsoe_prices_.*\\.csv$", full.names = TRUE)
df_prices <- bind_rows(lapply(price_files, function(f) {
  p <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
  names(p) <- c("datetime_raw", "price_eur_mwh")
  p %>% mutate(
    datetime = ymd_hms(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", datetime_raw)), tz = "UTC"),
    datetime_bxl = with_tz(datetime, "Europe/Brussels")
  ) %>% select(datetime_bxl, price_eur_mwh)
})) %>% distinct(datetime_bxl, .keep_all = TRUE) %>% arrange(datetime_bxl)

# Joindre prix aux donnees 15-min (prix horaire -> repete sur 4 quarts)
df$hour_ts <- floor_date(df$timestamp, "hour")
df_prices$hour_ts <- floor_date(df_prices$datetime_bxl, "hour")
df <- df %>% left_join(
  df_prices %>% select(hour_ts, price_eur_mwh) %>% distinct(hour_ts, .keep_all = TRUE),
  by = "hour_ts"
)

# Prix en EUR/kWh
TAXE_TRANSPORT <- 0.150  # EUR/kWh
COEFF_INJECTION <- 1.00
df$prix_eur_kwh <- df$price_eur_mwh / 1000
df$prix_offtake <- df$prix_eur_kwh + TAXE_TRANSPORT
df$prix_injection <- df$prix_eur_kwh * COEFF_INJECTION

# Verifier couverture prix
n_na_prix <- sum(is.na(df$price_eur_mwh))
cat(sprintf("Prix spot : %d/%d points sans prix (%.1f%%)\n",
  n_na_prix, nrow(df), 100 * n_na_prix / nrow(df)))

# --- 3. Charger CO2 Elia ---
co2_files <- list.files("data", pattern = "elia_co2_.*\\.csv$", full.names = TRUE)
df_co2 <- bind_rows(lapply(co2_files, function(f) {
  c2 <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
  names(c2) <- c("datetime_raw", "co2_g_per_kwh")
  c2 %>% mutate(
    datetime = ymd_hms(gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", datetime_raw)), tz = "UTC"),
    datetime_bxl = with_tz(datetime, "Europe/Brussels")
  ) %>% select(datetime_bxl, co2_g_per_kwh)
})) %>% distinct(datetime_bxl, .keep_all = TRUE) %>% arrange(datetime_bxl)

df_co2$hour_ts <- floor_date(df_co2$datetime_bxl, "hour")
df <- df %>% left_join(
  df_co2 %>% select(hour_ts, co2_g_per_kwh) %>% distinct(hour_ts, .keep_all = TRUE),
  by = "hour_ts"
)

# =============================================================================
# 4. METRIQUES BASELINE (= donnees mesurees)
# =============================================================================
cat("\n========================================\n")
cat("  BASELINE (fonctionnement actuel mesure)\n")
cat("========================================\n")

pv_total <- sum(df$pv_kwh, na.rm = TRUE)
offtake_baseline <- sum(df$offtake_kwh, na.rm = TRUE)
feedin_baseline <- sum(df$feedin_kwh, na.rm = TRUE)
pac_baseline <- sum(df$pac_kwh, na.rm = TRUE)

# Autoconsommation = (PV - injection) / PV
ac_baseline <- (1 - feedin_baseline / max(pv_total, 1)) * 100
# Autosuffisance = PV consomme / conso totale
pv_consumed_baseline <- pv_total - feedin_baseline
conso_totale_baseline <- offtake_baseline + pv_consumed_baseline
as_baseline <- pv_consumed_baseline / max(conso_totale_baseline, 1) * 100

# Financier
cout_soutirage_baseline <- sum(df$offtake_kwh * df$prix_offtake, na.rm = TRUE)
rev_injection_baseline <- sum(df$feedin_kwh * df$prix_injection, na.rm = TRUE)
facture_baseline <- cout_soutirage_baseline - rev_injection_baseline

cat(sprintf("Production PV        : %8.0f kWh (%.0f kWh/jour)\n", pv_total, pv_total / n_days))
cat(sprintf("Soutirage reseau     : %8.0f kWh (%.0f kWh/jour)\n", offtake_baseline, offtake_baseline / n_days))
cat(sprintf("Injection reseau     : %8.0f kWh (%.0f kWh/jour)\n", feedin_baseline, feedin_baseline / n_days))
cat(sprintf("Conso PAC mesuree    : %8.0f kWh (%.0f kWh/jour)\n", pac_baseline, pac_baseline / n_days))
cat(sprintf("Conso totale         : %8.0f kWh (%.0f kWh/jour)\n", conso_totale_baseline, conso_totale_baseline / n_days))
cat(sprintf("PV autoconsomme      : %8.0f kWh\n", pv_consumed_baseline))
cat(sprintf("Autoconsommation     : %8.1f %%\n", ac_baseline))
cat(sprintf("Autosuffisance       : %8.1f %%\n", as_baseline))
cat(sprintf("\nCout soutirage       : %8.0f EUR\n", cout_soutirage_baseline))
cat(sprintf("Revenu injection     : %8.0f EUR\n", rev_injection_baseline))
cat(sprintf("FACTURE NETTE        : %8.0f EUR (%.1f EUR/jour)\n", facture_baseline, facture_baseline / n_days))

# CO2
co2_baseline_kg <- sum(df$offtake_kwh * df$co2_g_per_kwh, na.rm = TRUE) / 1000
co2_intensity_baseline <- sum(df$offtake_kwh * df$co2_g_per_kwh, na.rm = TRUE) /
  max(sum(df$offtake_kwh[!is.na(df$co2_g_per_kwh)], na.rm = TRUE), 1)
cat(sprintf("\nCO2 (soutirage)      : %8.0f kg CO2eq\n", co2_baseline_kg))
cat(sprintf("Intensite carbone    : %8.0f gCO2/kWh\n", co2_intensity_baseline))

# =============================================================================
# 5. METRIQUES OPTIMISEES (deduites du gain connu)
# =============================================================================
cat("\n========================================\n")
cat("  OPTIMISE (simulateur EMS Wise)\n")
cat("========================================\n")

GAIN_EUR <- 1054
GAIN_PCT <- 33.0

facture_opti <- facture_baseline - GAIN_EUR
cat(sprintf("FACTURE OPTIMISEE    : %8.0f EUR (%.1f EUR/jour)\n", facture_opti, facture_opti / n_days))
cat(sprintf("GAIN                 : %8.0f EUR (%.0f%%)\n", GAIN_EUR, GAIN_PCT))
cat(sprintf("GAIN / jour          : %8.1f EUR/jour\n", GAIN_EUR / n_days))
cat(sprintf("GAIN / an (extrapole): %8.0f EUR/an\n", GAIN_EUR / n_days * 365))

# =============================================================================
# 6. ANALYSE DES PRIX — exemples frappants
# =============================================================================
cat("\n========================================\n")
cat("  ANALYSE DES PRIX SPOT\n")
cat("========================================\n")

df_valid <- df %>% filter(!is.na(price_eur_mwh))

cat(sprintf("Prix spot moyen      : %8.1f EUR/MWh\n", mean(df_valid$price_eur_mwh)))
cat(sprintf("Prix spot median     : %8.1f EUR/MWh\n", median(df_valid$price_eur_mwh)))
cat(sprintf("Prix spot min        : %8.1f EUR/MWh\n", min(df_valid$price_eur_mwh)))
cat(sprintf("Prix spot max        : %8.1f EUR/MWh\n", max(df_valid$price_eur_mwh)))

# Heures a prix negatif
n_neg <- sum(df_valid$price_eur_mwh < 0)
pct_neg <- 100 * n_neg / nrow(df_valid)
cat(sprintf("Quarts negatifs      : %d (%.1f%%)\n", n_neg, pct_neg))

# Amplitude intra-jour
daily_amp <- df_valid %>%
  mutate(date = as.Date(timestamp)) %>%
  group_by(date) %>%
  summarise(
    min_p = min(price_eur_mwh), max_p = max(price_eur_mwh),
    amp = max_p - min_p, .groups = "drop"
  )
cat(sprintf("Amplitude jour moy.  : %8.1f EUR/MWh\n", mean(daily_amp$amp)))
cat(sprintf("Amplitude jour max   : %8.1f EUR/MWh (le %s)\n",
  max(daily_amp$amp), daily_amp$date[which.max(daily_amp$amp)]))

# =============================================================================
# 7. EXEMPLES FRAPPANTS — journees types
# =============================================================================
cat("\n========================================\n")
cat("  JOURNEES REMARQUABLES\n")
cat("========================================\n")

daily <- df %>%
  mutate(date = as.Date(timestamp)) %>%
  group_by(date) %>%
  summarise(
    pv = sum(pv_kwh, na.rm = TRUE),
    offtake = sum(offtake_kwh, na.rm = TRUE),
    feedin = sum(feedin_kwh, na.rm = TRUE),
    pac = sum(pac_kwh, na.rm = TRUE),
    prix_moyen = mean(price_eur_mwh, na.rm = TRUE),
    prix_min = min(price_eur_mwh, na.rm = TRUE),
    prix_max = max(price_eur_mwh, na.rm = TRUE),
    facture = sum(offtake_kwh * prix_offtake - feedin_kwh * prix_injection, na.rm = TRUE),
    n_neg = sum(price_eur_mwh < 0, na.rm = TRUE),
    co2_kg = sum(offtake_kwh * co2_g_per_kwh, na.rm = TRUE) / 1000,
    .groups = "drop"
  ) %>%
  filter(pv > 0)  # jours avec PV

# Meilleure journee PV
best_pv <- daily %>% slice_max(pv, n = 1)
cat(sprintf("\nMeilleure journee PV : %s -> %.0f kWh PV, injection=%.0f kWh, soutirage=%.0f kWh\n",
  best_pv$date, best_pv$pv, best_pv$feedin, best_pv$offtake))

# Journee avec le plus de prix negatifs
worst_price <- daily %>% slice_max(n_neg, n = 1)
cat(sprintf("Plus de prix negatifs: %s -> %d quarts negatifs, PV=%.0f kWh, min=%.0f EUR/MWh\n",
  worst_price$date[1], worst_price$n_neg[1], worst_price$pv[1], worst_price$prix_min[1]))

# Journee la plus chere
most_expensive <- daily %>% slice_max(facture, n = 1)
cat(sprintf("Journee la plus chere: %s -> facture=%.1f EUR, soutirage=%.0f kWh, prix_moy=%.0f EUR/MWh\n",
  most_expensive$date, most_expensive$facture, most_expensive$offtake, most_expensive$prix_moyen))

# Journee la moins chere (ou negative = on gagne)
cheapest <- daily %>% slice_min(facture, n = 1)
cat(sprintf("Journee la - chere   : %s -> facture=%.1f EUR, PV=%.0f kWh, feedin=%.0f kWh\n",
  cheapest$date, cheapest$facture, cheapest$pv, cheapest$feedin))

# =============================================================================
# 8. PROFIL HORAIRE — ou se situe le potentiel
# =============================================================================
cat("\n========================================\n")
cat("  PROFIL HORAIRE MOYEN\n")
cat("========================================\n")

hourly_profile <- df %>%
  mutate(hour = hour(timestamp)) %>%
  group_by(hour) %>%
  summarise(
    pv_moy = mean(pv_kwh, na.rm = TRUE) * 4,  # kW moyen (kWh/15min * 4)
    offtake_moy = mean(offtake_kwh, na.rm = TRUE) * 4,
    feedin_moy = mean(feedin_kwh, na.rm = TRUE) * 4,
    pac_moy = mean(pac_kwh, na.rm = TRUE) * 4,
    prix_moy = mean(price_eur_mwh, na.rm = TRUE),
    .groups = "drop"
  )

cat("Heure | PV(kW) | Soutirage(kW) | Injection(kW) | PAC(kW) | Prix(EUR/MWh)\n")
cat("------|--------|---------------|---------------|---------|-------------\n")
for (i in seq_len(nrow(hourly_profile))) {
  h <- hourly_profile[i, ]
  cat(sprintf("  %02d  | %5.1f  |     %5.1f     |     %5.1f     |  %5.1f  |   %6.1f\n",
    h$hour, h$pv_moy, h$offtake_moy, h$feedin_moy, h$pac_moy, h$prix_moy))
}

# Heures PV vs PAC overlap
pv_hours <- hourly_profile %>% filter(pv_moy > 1)
cat(sprintf("\nHeures solaires (PV > 1kW) : %02d:00 - %02d:00\n",
  min(pv_hours$hour), max(pv_hours$hour)))

pac_peak <- hourly_profile %>% slice_max(pac_moy, n = 3)
cat(sprintf("Heures PAC les + actives   : %s\n",
  paste(sprintf("%02d:00 (%.1f kW)", pac_peak$hour, pac_peak$pac_moy), collapse = ", ")))

# =============================================================================
# 9. TEMPERATURE BALLON — analyse confort
# =============================================================================
cat("\n========================================\n")
cat("  TEMPERATURE BALLON (CONFORT)\n")
cat("========================================\n")

t_valid <- df %>% filter(!is.na(t_ballon))
cat(sprintf("T ballon moyenne     : %5.1f C\n", mean(t_valid$t_ballon)))
cat(sprintf("T ballon min         : %5.1f C\n", min(t_valid$t_ballon)))
cat(sprintf("T ballon max         : %5.1f C\n", max(t_valid$t_ballon)))

# Conformite [45, 55]
n_in <- sum(t_valid$t_ballon >= 45 & t_valid$t_ballon <= 55)
n_low <- sum(t_valid$t_ballon < 45)
n_high <- sum(t_valid$t_ballon > 55)
cat(sprintf("Dans [45-55]         : %d / %d (%.1f%%)\n", n_in, nrow(t_valid), 100 * n_in / nrow(t_valid)))
cat(sprintf("Sous 45C             : %d (%.1f%%)\n", n_low, 100 * n_low / nrow(t_valid)))
cat(sprintf("Au-dessus 55C        : %d (%.1f%%)\n", n_high, 100 * n_high / nrow(t_valid)))

# =============================================================================
# 10. RESUME POUR LA SLIDE
# =============================================================================
cat("\n")
cat("================================================================\n")
cat("  RESUME SLIDE — KARNO PROFONDEVILLE\n")
cat("================================================================\n")
cat(sprintf("Installation : PAC 60 kW, PV 64 kWc, Ballon 32 000 L\n"))
cat(sprintf("Donnees      : %s -> %s (%.0f jours, donnees reelles)\n",
  format(min(df$timestamp), "%d/%m/%Y"),
  format(max(df$timestamp), "%d/%m/%Y"), n_days))
cat(sprintf("\n"))
cat(sprintf("                    BASELINE        OPTIMISE        GAIN\n"))
cat(sprintf("Facture nette  :  %7.0f EUR     %7.0f EUR     %+.0f EUR (-%s%%)\n",
  facture_baseline, facture_opti, -GAIN_EUR, GAIN_PCT))
cat(sprintf("Facture / jour :  %7.1f EUR     %7.1f EUR     %+.1f EUR/j\n",
  facture_baseline / n_days, facture_opti / n_days, -GAIN_EUR / n_days))
cat(sprintf("Extrapole /an  :  %7.0f EUR     %7.0f EUR     %+.0f EUR/an\n",
  facture_baseline / n_days * 365, facture_opti / n_days * 365, -GAIN_EUR / n_days * 365))
cat(sprintf("\n"))
cat(sprintf("PV total       :  %7.0f kWh\n", pv_total))
cat(sprintf("Autoconsommation: %6.1f %%        (potentiel d'amelioration par l'EMS)\n", ac_baseline))
cat(sprintf("Autosuffisance :  %6.1f %%\n", as_baseline))
cat(sprintf("Soutirage      :  %7.0f kWh     (reduction attendue par optimisation)\n", offtake_baseline))
cat(sprintf("Injection      :  %7.0f kWh\n", feedin_baseline))
cat(sprintf("Conso PAC      :  %7.0f kWh (%.0f%% de la conso totale)\n",
  pac_baseline, 100 * pac_baseline / conso_totale_baseline))
cat(sprintf("\n"))
cat(sprintf("CO2 baseline   :  %7.0f kg CO2eq (intensite: %.0f gCO2/kWh)\n",
  co2_baseline_kg, co2_intensity_baseline))
cat(sprintf("CO2 saved (est): %7.0f kg (meme ratio que EUR -> ~%.0f%%)\n",
  co2_baseline_kg * GAIN_PCT / 100, GAIN_PCT))
eq_car_km <- (co2_baseline_kg * GAIN_PCT / 100) * 1000 / 120
eq_trees <- (co2_baseline_kg * GAIN_PCT / 100) / 25
cat(sprintf("Equiv voiture  :  %7.0f km evites\n", eq_car_km))
cat(sprintf("Equiv arbres   :  %7.0f arbres/an\n", eq_trees))
cat(sprintf("\n"))
cat(sprintf("Prix spot moyen:  %6.1f EUR/MWh (min=%.0f, max=%.0f)\n",
  mean(df_valid$price_eur_mwh), min(df_valid$price_eur_mwh), max(df_valid$price_eur_mwh)))
cat(sprintf("Prix negatifs  :  %d quarts d'heure (%.1f%% du temps)\n", n_neg, pct_neg))
cat(sprintf("Amplitude moy  :  %.0f EUR/MWh entre min et max journalier\n", mean(daily_amp$amp)))

cat("\n=== Done ===\n")
