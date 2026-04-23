# Data Model: Real Solar Data Scaling

**Feature**: 004-real-solar-scaling
**Date**: 2026-04-23

## Entities

### Delaunoy Reference Dataset

Represents the raw measured PV production from the Delaunoy installation.

| Field | Type | Description |
|-------|------|-------------|
| Timestamp | datetime | 15-minute interval start time (2024-01-01 to 2024-12-31) |
| Value | numeric (kWh) | Aggregated production across all 5 inverters for the 15-min interval |

**Source**: `../delaunoy/data/inverters_data_delaunoy.xlsx`, Sheet 1
**Reference capacity**: 16 kWc
**Record count**: ~20,600

### PV Data Source Selection

New parameter controlling PV data origin.

| Value | Label | Behavior |
|-------|-------|----------|
| `"synthetic"` | Synthétique | Current sine-curve formula (default, unchanged) |
| `"real_delaunoy"` | Réel (Delaunoy 2024) | Scaled Delaunoy measured data, forces 2024 for all series |

### Scaled PV Series

Output of the scaling function, replaces the `pv_kwh` column in the simulation dataframe.

| Field | Type | Description |
|-------|------|-------------|
| timestamp | POSIXct | 15-minute interval (matches simulation time grid) |
| pv_kwh | numeric | `delaunoy_value * (target_kwc / 16)` |

### Extended SimulationParams

New fields added to the parameter set:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| pv_data_source | character | `"synthetic"` | Source selection for PV production data |
| pv_scaling_factor | numeric | 1.0 | Computed ratio `target_kwc / 16` (for display) |

## Relationships

```
PV Data Source Selection
  ├── "synthetic" → DataGenerator::generate_demo() (existing sine formula)
  └── "real_delaunoy" → load_delaunoy() → scale by (kwc / 16)
                         └── forces year = 2024 for:
                             ├── Belpex prices (belpex_historical_2024.csv)
                             ├── OpenMeteo temps (openmeteo_temp_2024.csv)
                             └── CO2 intensity (co2_historical_2024.csv + fallback)
```

## Validation Rules

- `pv_data_source` must be one of `"synthetic"`, `"real_delaunoy"`
- When `pv_data_source == "real_delaunoy"`, date range must fall within 2024-01-01 to 2024-12-31
- `pv_scaling_factor` is always `target_kwc / 16` (can be 0 if kwc is 0)
- Scaled `pv_kwh` values must be non-negative
