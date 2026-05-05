# =============================================================================
# Analyse BELIX : la PAC de Profondeville est-elle pilotee sur le tarif ?
# =============================================================================
# Test : comparer le % de conso PAC en heures pleines du contrat BELIX
# avec le % de temps que representent ces heures pleines.
# Si les deux sont quasi identiques -> thermostat aveugle, aucun pilotage.
#
# Contrat BELIX Profondeville :
#   Heures pleines : 7h-11h et 17h-22h (9h/jour = 37.5%)
#   Heures creuses : 22h-7h et 11h-17h (15h/jour = 62.5%)
#   BELIX peak index : moyenne spot 8h-20h
#   BELIX off-peak index : moyenne spot 20h-8h
#   Spread M+R+T = 193.53 EUR/MWh
# =============================================================================

library(dplyr)
library(lubridate)
library(readr)

# --- Charger les donnees mesurees ---
df <- read_csv("inst/extdata/bq_k0001_fusion.csv", show_col_types = FALSE)
df$timestamp <- with_tz(df$timestamp, tzone = "Europe/Brussels")

cat("=== ANALYSE BELIX — PILOTAGE OU THERMOSTAT ? ===\n\n")
cat(sprintf("Donnees : %s -> %s\n",
  format(min(df$timestamp), "%d/%m/%Y"),
  format(max(df$timestamp), "%d/%m/%Y")))
n_days <- as.numeric(difftime(max(df$timestamp), min(df$timestamp), units = "days"))
cat(sprintf("Duree   : %.0f jours, %d points\n\n", n_days, nrow(df)))

# --- Plages horaires du contrat BELIX ---
h <- hour(df$timestamp)
is_peak <- (h >= 7 & h < 11) | (h >= 17 & h < 22)

# --- % du temps en heures pleines ---
pct_temps_peak <- 100 * sum(is_peak) / nrow(df)

# --- % de la conso PAC en heures pleines ---
pac_peak <- sum(df$pac_kwh[is_peak], na.rm = TRUE)
pac_total <- sum(df$pac_kwh, na.rm = TRUE)
pct_pac_peak <- 100 * pac_peak / pac_total

cat("=== RESULTAT ===\n")
cat(sprintf("Heures pleines (7-11h, 17-22h) = %.1f%% du temps\n", pct_temps_peak))
cat(sprintf("Conso PAC en heures pleines    = %.1f%% de la conso PAC totale\n", pct_pac_peak))
cat(sprintf("Ecart                          = %+.1f points de pourcentage\n\n",
  pct_pac_peak - pct_temps_peak))

if (abs(pct_pac_peak - pct_temps_peak) < 3) {
  cat("VERDICT : THERMOSTAT AVEUGLE\n")
  cat("La PAC consomme de maniere indifferenciee entre heures pleines et creuses.\n")
  cat("Aucun pilotage tarifaire detecte — la PAC suit uniquement la consigne de temperature.\n")
} else if (pct_pac_peak < pct_temps_peak - 3) {
  cat("VERDICT : PILOTAGE DETECTE (evitement des heures pleines)\n")
  cat("La PAC consomme moins en heures pleines que ce que le hasard donnerait.\n")
} else {
  cat("VERDICT : ANTI-PILOTAGE (surcharge en heures pleines)\n")
  cat("La PAC consomme PLUS en heures pleines — probablement lie aux soutirages ECS.\n")
}

# --- Detail par tranche horaire ---
cat("\n=== DETAIL PAR TRANCHE ===\n")

tranche <- case_when(
  h >= 22 | h < 7   ~ "Nuit (22h-7h)",
  h >= 7  & h < 11  ~ "Pleine matin (7h-11h)",
  h >= 11 & h < 17  ~ "Creuse midi (11h-17h)",
  h >= 17 & h < 22  ~ "Pleine soir (17h-22h)"
)

detail <- df %>%
  mutate(tranche = tranche) %>%
  group_by(tranche) %>%
  summarise(
    pac_kwh = sum(pac_kwh, na.rm = TRUE),
    n_qt = n(),
    pac_moy_kw = mean(pac_kwh, na.rm = TRUE) * 4,
    .groups = "drop"
  ) %>%
  mutate(
    pct_pac = round(100 * pac_kwh / sum(pac_kwh), 1),
    pct_temps = round(100 * n_qt / sum(n_qt), 1)
  )

cat(sprintf("%-25s | %7s | %6s | %6s | %7s\n",
  "Tranche", "PAC kWh", "% PAC", "% Temps", "PAC moy kW"))
cat(paste(rep("-", 70), collapse = ""), "\n")
for (i in seq_len(nrow(detail))) {
  r <- detail[i, ]
  cat(sprintf("%-25s | %7.0f | %5.1f%% | %5.1f%% | %7.1f\n",
    r$tranche, r$pac_kwh, r$pct_pac, r$pct_temps, r$pac_moy_kw))
}

# --- Detail horaire (profil 0-23h) ---
cat("\n=== PROFIL HORAIRE PAC ===\n")
hourly <- df %>%
  mutate(hour = hour(timestamp)) %>%
  group_by(hour) %>%
  summarise(
    pac_kwh = sum(pac_kwh, na.rm = TRUE),
    pac_moy_kw = mean(pac_kwh, na.rm = TRUE) * 4,
    .groups = "drop"
  ) %>%
  mutate(
    pct = round(100 * pac_kwh / sum(pac_kwh), 1),
    plage = ifelse((hour >= 7 & hour < 11) | (hour >= 17 & hour < 22), "PLEINE", "creuse")
  )

cat(sprintf("%5s | %7s | %5s | %7s | %s\n", "Heure", "PAC kWh", "% PAC", "Moy kW", "Plage"))
cat(paste(rep("-", 50), collapse = ""), "\n")
for (i in seq_len(nrow(hourly))) {
  r <- hourly[i, ]
  cat(sprintf("  %02d  | %7.0f | %4.1f%% | %6.1f  | %s\n",
    r$hour, r$pac_kwh, r$pct, r$pac_moy_kw, r$plage))
}

cat("\n=== Done ===\n")
