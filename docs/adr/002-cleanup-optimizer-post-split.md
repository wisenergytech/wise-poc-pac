# ADR-002 : Nettoyage de l'optimiseur après le split diagnostic

**Date** : 2026-05-06
**Statut** : Fait
**Branche** : `007-cleanup-optimizer` (depuis `006-dual-csv-import`)
**Contexte** : Suite à ADR-001, le diagnostic PV est maintenant dans `wise-poc-diagnostic`

## Objectif

Supprimer de `wise-poc-pac` tout le code lié au diagnostic/parsing/reconstruction PV qui a été migré vers `wise-poc-diagnostic`. L'optimiseur ne doit plus accepter que le CSV standardisé (ou le mode Démo).

## Fichiers à supprimer

### R/
- `R/fct_csv_parser.R` — parsing dual-CSV (migré)
- `R/fct_pv_reconstruction.R` — PV bilan + kWc adaptatif (migré)
- `R/fct_data_diagnostic.R` — diagnostic périmètre/autocons/puissance (migré)
- `R/mod_donnees.R` — onglet Données (migré)

**À GARDER** :
- `R/fct_pac_detection.R` — nécessaire pour l'optimiseur ! Si le CSV standardisé ne contient pas `pac_kwh` (ex: l'utilisateur uploade un CSV sans avoir fait le diagnostic), l'optimiseur doit pouvoir détecter la PAC lui-même via la cascade COP/talon.

### Tests/
- `tests/testthat/test-fct_csv_parser.R`
- `tests/testthat/test-fct_pv_reconstruction.R`

**À GARDER** :
- `tests/testthat/test-fct_pac_detection.R` — tests de la cascade PAC

### data-raw/
- `data-raw/fetch_bigquery_pac.R` — script de fetch BQ (migré)
- `data-raw/fetch_fusionsolar.R` — script de fetch FusionSolar (migré)

### inst/extdata/
- `inst/extdata/bq_k0001_raw.csv` — données brutes installation
- `inst/extdata/bq_k0001_ores_raw.csv` — données brutes ORES
- `inst/extdata/bq_k0001_dictionary.yaml` — dictionnaire BQ

### Vignettes à supprimer/déplacer
- `vignettes/diagnostic-solaire.Rmd` — migré vers diagnostic
- Sections PV de `vignettes/donnees-baseline-autoconsommation.Rmd` — à élaguer

### Scripts/
- `scripts/analyse_bq_energy_balance.R` — script d'analyse (migré)

## Fichiers à garder

- `R/fct_pac_detection.R` — détection PAC par cascade (GSHP/ASHP → COP/talon → fallback). Nécessaire si le CSV uploadé ne contient pas `pac_kwh` pré-calculé.
- `R/fct_fetch_elia_solar.R` — nécessaire pour le what-if PV dans l'optimiseur
- `tests/testthat/test-fct_pac_detection.R` — tests de la cascade PAC
- `inst/extdata/elia_solar_*.csv` — cache local pour le what-if
- `inst/extdata/test_csv_complet.csv`, `test_csv_complet_partial.csv` — tests existants (format legacy, à adapter)

## Modifications à faire

### R/mod_sidebar.R

Remplacer les deux `fileInput` (file_installation + file_ores) par un seul :
```r
fileInput(ns("csv_file"), "CSV standardisé", accept = ".csv")
```

Supprimer :
- Le pipeline de parsing (parse_installation_csv, parse_ores_csv, join_sources)
- L'appel à detect_pac_consumption
- L'appel à reconstruct_pv
- Le fetch Elia adaptatif dans compute_raw_data
- Le sélecteur PV source (reconstructed/elia_adaptive/elia_fixed)
- La checkbox outlier_filter
- import_report_content, import_meta_val, pv_elia_1kwc_val reactiveVals
- L'output import_report / pv_stability_ui

Garder :
- La validation des colonnes attendues (timestamp, pv_kwh, offtake_kwh, feedin_kwh)
- Si `pac_kwh` et `conso_hors_pac` présents → utiliser directement (CSV du diagnostic)
- Si `pac_kwh` absent mais `elec_kwh` + `cop` présents → appeler `detect_pac_consumption()` (fallback)
- L'enrichissement (prix Belpex, t_ext via Open-Meteo)
- Le mode Démo inchangé
- Le what-if PV (toggle + Elia scaling)

### R/app_ui.R

Supprimer :
```r
bslib::nav_panel(title = "Données", icon = shiny::icon("database"),
  mod_donnees_ui("donnees")),
```

### R/app_server.R

Supprimer :
```r
mod_donnees_server("donnees", sidebar)
```

### R/R6_data_generator.R

Simplifier `prepare_df()` :
- La branche `"conso_hors_pac" %in% names(df)` devient le cas principal pour CSV
- Supprimer les branches legacy (has_pac_kwh, has_t_ballon heuristique, fallback)

### Liste de retour du sidebar

Supprimer de la liste retournée :
- `import_meta`
- Les reactiveVals liés au diagnostic

## Format CSV standardisé attendu

| Colonne | Obligatoire | Description |
|---------|-------------|-------------|
| timestamp | Oui | POSIXct 15-min, Europe/Brussels |
| pv_kwh | Oui | Production PV par qt |
| pac_kwh | Oui | Consommation PAC par qt |
| offtake_kwh | Oui | Soutirage réseau par qt |
| feedin_kwh | Oui | Injection réseau par qt |
| conso_hors_pac | Oui | Consommation hors PAC par qt |
| t_ballon | Non | Température ballon (°C) |
| cop | Non | COP mesuré |
| t_ext | Non | Température extérieure (°C) |

## Étapes d'exécution

1. Créer branche `007-cleanup-optimizer` depuis `006-dual-csv-import`
2. Supprimer les fichiers listés ci-dessus
3. Simplifier `mod_sidebar.R` (single CSV input)
4. Supprimer l'onglet Données de `app_ui.R` / `app_server.R`
5. Simplifier `R6_data_generator.R`
6. Adapter les tests existants (certains peuvent référencer les fichiers supprimés)
7. Vérifier que le mode Démo fonctionne toujours
8. Vérifier que l'upload d'un CSV standardisé fonctionne
9. Run test suite
10. Commit

## Test de validation

1. Mode Démo → simulation tourne → KPIs affichés ✓
2. Upload `test_csv_complet.csv` (format standardisé) → simulation tourne ✓
3. What-if PV (changer le kWc) → PV rescalé depuis Elia ✓
4. Aucune référence à `parse_installation_csv`, `detect_pac_consumption`, `reconstruct_pv` dans le code restant
