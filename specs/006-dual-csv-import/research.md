# Research: Import à deux CSV

**Feature**: 006-dual-csv-import
**Date**: 2026-05-05

## R1: Détection du pas de temps

**Decision**: Calculer la médiane des différences entre les 10 premiers timestamps consécutifs.

**Rationale**: La médiane est robuste aux gaps isolés (NA, données manquantes). On arrondit au pas standard le plus proche (5 min, 15 min, 30 min, 60 min). Si la médiane ne correspond à aucun pas standard (écart > 10%), warning à l'utilisateur.

**Alternatives considered**:
- Mode (valeur la plus fréquente) : sensible aux duplicats
- Premier écart seulement : sensible à un gap au début du fichier

## R2: Agrégation au pas de 15 min

**Decision**: Utiliser `lubridate::floor_date(timestamp, "15 minutes")` pour grouper, puis :
- Somme pour les énergies et puissances (Elec_consumption, GSHP_power, ASHP_power)
- Moyenne pour les températures (T_tankUp) et le COP
- Last pour les index ORES (delta calculé après agrégation)

**Rationale**: Cohérent avec le script `fetch_bigquery_pac.R` existant qui fait déjà cette agrégation. Le choix somme vs moyenne dépend de la nature physique de la grandeur.

**Alternatives considered**:
- Garder au pas de 5 min : le reste de l'app (optimiseur, KPI) attend du 15 min
- Agrégation horaire : perte de résolution, le contrat spot belge est au quart d'heure

## R3: Conversion index ORES en deltas

**Decision**: `delta = index[t] - index[t-1]`, avec `pmax(0, delta)` pour plafonner les valeurs négatives (remplacement compteur, rollback). Le premier pas de chaque session est NA (pas de référence précédente).

**Rationale**: Identique à la logique actuelle dans `fetch_bigquery_pac.R:137-143`. Les deltas négatifs sont rares (< 0.1% sur Profondeville) et correspondent à des anomalies de compteur.

**Alternatives considered**:
- Interpolation sur les gaps : complexité inutile pour < 0.1% des cas
- Warning sur chaque delta négatif : trop verbeux, un compteur global suffit

## R4: Cascade de détection PAC

**Decision**: Cascade en 4 niveaux dans une fonction unique `detect_pac_consumption(df)` :

1. **GSHP_power + ASHP_power** : si colonnes présentes ET `sum(GSHP_power + ASHP_power) > 0` → `pac_kwh = (GSHP_power + ASHP_power) * dt_h` (conversion puissance → énergie)
2. **Sous-compteur dédié** : si colonne nommée `pac_elec_kw` ou `pac_kwh` ou `hp_power` présente ET non nulle → utiliser directement
3. **Heuristique COP/talon** : si colonne COP présente avec > 20 pas à 0 et > 20 pas > 0 → talon = médiane(Elec quand COP=0), pac_pure = max(0, Elec - talon) quand COP ∈ (0, 7)
4. **Fallback** : warning, utiliser Elec_consumption en totalité

**Rationale**: Ordre du plus fiable (mesure directe) au moins fiable (proxy total). La cascade est déterministe et documentée dans le rapport.

**Alternatives considered**:
- Machine learning pour séparer les charges : overkill pour un POC, pas de données d'entraînement
- Seuillage sur la puissance (sans COP) : moins fiable, pas de signal physique clair

## R5: Heuristique talon — médiane vs percentile

**Decision**: Médiane de Elec_consumption quand COP = 0, calculée globalement (pas par heure).

**Rationale**: L'analyse de Profondeville montre que le talon par heure varie peu (0.3-0.6 kWh/qt). La médiane globale est suffisante pour un premier pass. Un talon par tranche horaire ajouterait de la complexité sans gain significatif pour le POC.

**Alternatives considered**:
- Talon par tranche horaire (jour/nuit) : plus précis mais complexité non justifiée au stade POC
- Percentile 25 : sous-estimerait le talon si des charges intermittentes (chauffage d'appoint) tournent parfois quand COP=0

## R6: PV reconstitué — gestion des valeurs négatives

**Decision**: `pv_reel = pmax(0, Elec_consumption - offtake_kwh + feedin_kwh)`. Les valeurs négatives (incohérences de timing, spikes ORES) sont mises à 0.

**Rationale**: L'analyse montre 6% de valeurs négatives sur Profondeville, principalement dues à quelques outliers ORES. Le `pmax(0, ...)` est la correction la plus simple et conservatrice.

**Alternatives considered**:
- Filtrer les outliers ORES avant le calcul : ajouterait un pré-traitement complexe
- Mettre à NA et interpoler : perte d'information inutile

## R7: Diagnostic de stabilité PV — seuil CV

**Decision**: Seuil CV > 30% pour déclarer le PV instable. Calculé sur les ratios mensuels pv_reel / pv_elia (en excluant les mois avec pv_elia < 10 kWh).

**Rationale**: Sur Profondeville, le CV est ~80% (mise en service progressive évidente). Un seuil à 30% est suffisamment conservateur pour ne pas déclencher de faux positifs sur une installation stable avec de la variabilité saisonnière normale (le profil Elia compense déjà la saisonnalité).

**Alternatives considered**:
- Test de tendance (Mann-Kendall) : plus rigoureux mais overkill pour un diagnostic visuel
- Seuil à 50% : trop permissif, raterait des mises en service partielles

## R8: Interaction avec le pipeline existant

**Decision**: La sortie du nouveau parser produit un dataframe au même format que l'ancien `prepare_df()` attendait : `timestamp, pv_kwh, pac_kwh, offtake_kwh, intake_kwh, t_ballon, cop, conso_hors_pac`. Le reste du pipeline (R6_baseline, R6_optimizer, R6_kpi) ne change pas.

**Rationale**: Minimiser le blast radius. Le changement est confiné au parsing/import. Le dataframe intermédiaire sert d'interface stable entre l'import et la simulation.

**Alternatives considered**:
- Renommer les colonnes internes (pac_kwh → pac_pure_kwh) : souhaitable à terme mais scope trop large pour cette feature
- Modifier R6_kpi pour comprendre le nouveau format : augmenterait le couplage
