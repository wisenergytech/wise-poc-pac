# Data Model: CSV Column Mapping

**Feature**: `010-csv-column-mapping`
**Date**: 2026-05-26

## Entities

### ColumnMapping

Represents the association between a CSV column name and an internal field.

| Field | Type | Description |
|-------|------|-------------|
| `target` | character | Internal field name (e.g. `"pv_kwh"`, `"pac1_kwh"`) |
| `source` | character or NA | CSV column name selected by user, or NA if unmapped |
| `auto_matched` | logical | TRUE if the suggestion came from keyword matching |
| `required` | logical | TRUE for mandatory fields (timestamp, at least one energy field) |

Target fields (exhaustive list):

| Target | Required | Description |
|--------|----------|-------------|
| `timestamp` | Yes | Horodatage |
| `pv_kwh` | Yes | Production PV |
| `offtake_kwh` | Yes | Soutirage reseau |
| `feedin_kwh` | Yes | Injection reseau |
| `pac1_kwh` | No | Conso electrique PAC 1 |
| `pac2_kwh` | No | Conso electrique PAC 2 |
| `t_ballon` | No | Temperature ballon |
| `t_sol` | No | Temperature sol (forage) |
| `t_ext` | No | Temperature exterieure |

### PACConfig (per mapped PAC)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | character | `"gshp"` / `"ashp"` | Type de source |
| `mode` | character | `"onoff"` / `"inverter"` | Mode de fonctionnement |
| `p_th_kw` | numeric | 60 | Puissance thermique nominale (kWth) |
| `cop_nominal` | numeric | 3.5 | COP nominal |

## State Transitions

### CSV Import Flow

```
No CSV → CSV uploaded → Columns detected → Auto-mapping applied
  → User reviews/adjusts mapping → Mapping validated → Simulation ready
```

### Mapping Panel Visibility

```
if (data_source == "demo") → mapping panel hidden
if (data_source == "csv" && no file) → mapping panel hidden
if (data_source == "csv" && file loaded && all exact matches) → mapping panel collapsed (auto-mapped)
if (data_source == "csv" && file loaded && partial/no matches) → mapping panel expanded
```

## Validation Rules

- `timestamp` must be mapped to a column parseable as POSIXct
- At least one of `offtake_kwh` or `feedin_kwh` must be mapped
- `pv_kwh` must be mapped (or defaults to 0 if missing — TOU sans PV scenario)
- A mapped column must contain numeric values (except timestamp)
- Same CSV column cannot be mapped to two different fields
- If `pac2_kwh` is mapped, `pac1_kwh` must also be mapped
