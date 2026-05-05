# Data Model: Import à deux CSV

**Feature**: 006-dual-csv-import
**Date**: 2026-05-05

## Input Entities

### CSV Installation (raw)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| time | datetime | YES | Horodatage (Europe/Brussels implicite) |
| Elec_consumption | numeric | YES | Conso électrique totale installation (kWh par pas) |
| COP | numeric | NO | Coefficient de performance PAC (0 = arrêtée) |
| T_tankUp | numeric | NO | Température haut du ballon (°C) |
| SP_tank | numeric | NO | Consigne température ballon (°C) |
| SP_supply | numeric | NO | Consigne température départ (°C) |
| GSHP_power | numeric | NO | Puissance PAC géothermique (kW) |
| ASHP_power | numeric | NO | Puissance PAC air-eau (kW) |

**Validation rules**:
- `time` doit être parseable en POSIXct
- `Elec_consumption` doit être >= 0 (warning si négatif)
- `COP` si présent : valeurs attendues [0, 7] (> 7 = anomalie)
- Pas de temps détecté automatiquement (5-min, 15-min, horaire)

### CSV ORES (raw)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| time | datetime | YES | Horodatage (Europe/Brussels implicite) |
| Consumption_index_kWh | numeric | YES | Index cumulatif soutirage réseau |
| Injection_index_kWh | numeric | YES | Index cumulatif injection réseau |

**Validation rules**:
- `time` doit être parseable en POSIXct
- Index doivent être croissants (delta négatif → plancher à 0 + warning)
- Pas de temps détecté automatiquement

## Intermediate Entity

### Données jointes (15 min)

Produit par `join_sources()` après agrégation et conversion.

| Field | Type | Source | Description |
|-------|------|--------|-------------|
| timestamp | POSIXct | floor_date(time, "15 min") | Horodatage arrondi |
| elec_kwh | numeric | sum(Elec_consumption) par qt | Conso totale installation |
| cop | numeric | mean(COP) par qt | COP moyen |
| t_ballon | numeric | mean(T_tankUp) par qt | Température ballon moyenne |
| gshp_kw | numeric | mean(GSHP_power) par qt | Puissance GSHP moyenne |
| ashp_kw | numeric | mean(ASHP_power) par qt | Puissance ASHP moyenne |
| offtake_kwh | numeric | delta(Consumption_index) | Soutirage réseau par qt |
| feedin_kwh | numeric | delta(Injection_index) | Injection réseau par qt |

## Output Entity

### Dataframe simulation-ready

Produit par le pipeline complet (parsing + détection PAC + PV). Format identique à l'ancien `prepare_df()` pour compatibilité avec le pipeline existant.

| Field | Type | Source | Description |
|-------|------|--------|-------------|
| timestamp | POSIXct | Jointure | Horodatage 15-min |
| pv_kwh | numeric | Bilan ou Elia | Production PV (reconstituée ou scalée) |
| pac_kwh | numeric | Cascade détection | Conso électrique PAC seule |
| offtake_kwh | numeric | ORES deltas | Soutirage réseau |
| intake_kwh | numeric | ORES deltas (feedin) | Injection réseau |
| t_ballon | numeric | Installation | Température ballon (NA si absent) |
| cop | numeric | Installation | COP mesuré (NA si absent) |
| conso_hors_pac | numeric | elec_kwh - pac_kwh | Consommation hors PAC (talon) |

## Metadata Entity

### Rapport d'import

Produit par le pipeline, affiché dans le sidebar.

| Field | Type | Description |
|-------|------|-------------|
| n_points | integer | Nombre de quarts d'heure joints |
| date_start | Date | Début de la période |
| date_end | Date | Fin de la période |
| dt_install | character | Pas de temps détecté (installation) |
| dt_ores | character | Pas de temps détecté (ORES) |
| pac_method | character | Méthode de détection PAC utilisée (a/b/c/d) |
| pac_p95_kw | numeric | Puissance PAC P95 (si heuristique COP) |
| talon_w | numeric | Talon installation en W (si heuristique COP) |
| pv_source | character | "reconstitué" ou "elia_scaled" |
| pv_stable | logical | TRUE si CV < 30% |
| diagnostics | list | Résultats des 4 tests de diagnostic |

## State Transitions

```
[Aucun fichier] → Upload Installation → [Installation seule, attente ORES]
[Installation seule] → Upload ORES → [Jointure + Détection + Diagnostic]
[Données prêtes] → Changement source PV → [Recalcul PV uniquement]
[Données prêtes] → Re-upload d'un fichier → [Reset + re-traitement complet]
```

## Relationships

```
CSV Installation (1) ──joins by timestamp──→ (1) CSV ORES
         ↓                                        ↓
    [agrégation 15 min]                    [delta d'index]
         ↓                                        ↓
         └──────────── Données jointes ───────────┘
                            ↓
                   [Détection PAC (cascade)]
                            ↓
                   [PV reconstitué (bilan)]
                            ↓
                   Dataframe simulation-ready
                            ↓
              Pipeline existant (Baseline → Optimizer → KPI)
```
