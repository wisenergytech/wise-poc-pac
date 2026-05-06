# ADR-001 : Séparer l'app en deux — Diagnostic PV et Optimiseur PAC

**Date** : 2026-05-06
**Statut** : Proposé
**Contexte** : Feature 006-dual-csv-import

## Contexte

L'application actuelle mélange deux responsabilités distinctes dans un seul monolithe :

1. **Comprendre et reconstruire les données** — parser les CSV bruts, détecter la PAC, reconstituer le PV, diagnostiquer la qualité, estimer le kWc, filtrer les outliers
2. **Optimiser la consommation PAC** — simuler une baseline, appliquer un optimiseur (LP/MILP/QP), calculer les gains financiers et énergétiques

Ces deux fonctions ciblent des utilisateurs et des moments différents :
- Le diagnostic se fait **une fois** à la réception des données (ingénieur, data analyst)
- L'optimisation se fait **N fois** avec différents paramètres (client, commercial, gestionnaire)

## Décision

Séparer l'application en deux applications indépendantes communicant via un **CSV standardisé** comme interface.

### App 1 : Diagnostic & Reconstruction PV (`wise-poc-diagnostic`)

**Responsabilité** : prendre des données brutes hétérogènes et produire un jeu de données propre et validé.

**Entrées** :
- CSV Installation (monitoring PAC : Elec_consumption, COP, T_tankUp, GSHP/ASHP_power)
- CSV ORES (compteur réseau : index cumulatifs)

**Traitements** :
- Parsing multi-format, détection pas de temps, agrégation 15 min
- Conversion index → deltas (ORES)
- Détection PAC par cascade (GSHP/ASHP → COP/talon → fallback)
- Reconstitution PV par bilan énergétique
- Diagnostic : périmètre, autoconsommation, stabilité PV, puissance PAC
- Estimation kWc adaptative (médiane glissante sur jours clairs)
- Scaling Elia (adaptatif/fixe)
- Filtre outliers IQR
- Visualisation : kWc temporel, profils, qualité

**Sortie** : un CSV standardisé :
```
timestamp, pv_kwh, pac_kwh, offtake_kwh, feedin_kwh, t_ballon, cop, conso_hors_pac, t_ext
```

### App 2 : Optimiseur PAC (`wise-poc-pac`)

**Responsabilité** : simuler et optimiser le pilotage d'une PAC à partir de données propres.

**Entrées** :
- Le CSV standardisé (exporté par l'app 1 ou fourni par n'importe quelle source conforme)
- Paramètres utilisateur (puissance PAC, volume ballon, contrat, etc.)

**Traitements** :
- Enrichissement (prix Belpex, température si absente)
- Simulation baseline (mesurée ou paramétrique)
- Optimisation (LP, MILP, QP)
- Calcul KPI (énergie, finance, CO2, confort)
- Visualisation (Sankey, heatmaps, comparaison contrats)

**Présupposé** : la colonne `pv_kwh` est correcte et fiable. Aucun diagnostic n'est effectué.

### Interface entre les deux

| Colonne | Type | Description | Obligatoire |
|---------|------|-------------|-------------|
| `timestamp` | POSIXct | Horodatage 15 min, Europe/Brussels | Oui |
| `pv_kwh` | numeric | Production PV (kWh/qt) | Oui |
| `pac_kwh` | numeric | Consommation PAC seule (kWh/qt) | Oui |
| `offtake_kwh` | numeric | Soutirage réseau (kWh/qt) | Oui |
| `feedin_kwh` | numeric | Injection réseau (kWh/qt) | Oui |
| `t_ballon` | numeric | Température ballon (°C) | Non |
| `cop` | numeric | COP mesuré | Non |
| `conso_hors_pac` | numeric | Consommation hors PAC (kWh/qt) | Oui |
| `t_ext` | numeric | Température extérieure (°C) | Non |

## Justification

### Séparation des responsabilités
Comprendre ses données ≠ optimiser sa PAC. Mélanger les deux rend le code difficile à maintenir et à tester (le `mod_sidebar.R` actuel fait 1400+ lignes).

### Utilisateurs différents
- **App diagnostic** : ingénieur énergie, data analyst — inspecte, valide, corrige
- **App optimiseur** : client final, commercial — simule des scénarios, voit les gains

### Testabilité
Chaque app a des entrées/sorties claires. On peut tester le diagnostic indépendamment de l'optimiseur, et inversement.

### Réutilisabilité
- L'app diagnostic fonctionne pour **n'importe quelle installation PV** (pas forcément avec PAC)
- L'optimiseur fonctionne avec **n'importe quelle source PV** (FusionSolar, Elia, bilan, manuelle)

### Déploiement indépendant
L'app diagnostic peut évoluer (nouveaux formats, nouvelles sources) sans toucher à l'optimiseur, et vice versa.

## Alternatives considérées

### 1. Garder un monolithe avec des onglets
**Rejeté** : le couplage augmente avec chaque feature. Le sidebar mixe déjà paramètres d'import et paramètres de simulation. Les tests sont fragiles (un changement de parsing casse les tests d'optimisation).

### 2. Séparer en modules R6 mais garder une seule app
**Rejeté partiellement** : la séparation logique (R6 classes, fct_*.R) est déjà en place. Mais l'UX est confuse — l'utilisateur doit comprendre les deux domaines en même temps.

### 3. Trois apps (diagnostic, optimiseur, reporting)
**Prématuré** : le reporting (présentation, PDF) peut rester dans l'optimiseur pour l'instant. Si ça grossit, on séparera plus tard.

## Conséquences

### Positives
- Code plus clair, tests plus ciblés
- UX simplifiée (chaque app a un objectif clair)
- Le format CSV standard permet d'intégrer d'autres sources à l'avenir
- Déploiement et évolution indépendants

### Négatives
- Deux repos/packages à maintenir (ou deux apps dans un monorepo)
- L'utilisateur doit exporter/importer un CSV entre les deux (friction UX)
- Duplication possible de certains utilitaires (helpers, thème)

### Migration
1. Extraire `fct_csv_parser.R`, `fct_pac_detection.R`, `fct_pv_reconstruction.R`, `fct_data_diagnostic.R`, `mod_donnees.R` vers le nouveau repo diagnostic
2. L'optimiseur garde son upload CSV simple (format standardisé)
3. Le mode Démo reste dans l'optimiseur
4. Les vignettes sont réparties selon leur domaine

## Prochaines étapes

- [ ] Créer le repo `wise-poc-diagnostic`
- [ ] Migrer les fonctions de parsing/diagnostic
- [ ] Adapter l'optimiseur pour ne plus accepter que le format standardisé
- [ ] Documenter le format CSV interface (schéma, validation)
- [ ] Lier les deux apps (bouton "Exporter vers l'optimiseur" dans l'app diagnostic)
