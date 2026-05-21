# Data Model: Dual PAC Optimizer

**Feature**: `009-dual-pac-optimizer`
**Date**: 2026-05-21

## New Entities

### DualPACParams (extension of SimulationParams)

New fields added to the existing `params` list:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pac2_active` | logical | `FALSE` | Enable second PAC |
| `pac2_type` | character | `"ashp"` | Source type: `"ashp"` or `"gshp"` |
| `pac2_mode` | character | `"inverter"` | Operating mode: `"onoff"` or `"inverter"` |
| `p_pac2_kw` | numeric | `40` | PAC 2 nominal power (kW) |
| `cop2_nominal` | numeric | `3.5` | PAC 2 COP at reference temperature |
| `t_ref_cop2` | numeric | `7` | Reference temperature for COP2 (°C) |
| `pac1_type` | character | `"gshp"` | PAC 1 source type (existing PAC, relabeled) |
| `pac1_mode` | character | `"onoff"` | PAC 1 operating mode |
| `ramp_max` | numeric | `0.3` | Max load change per qt for inverter PAC (fraction of P_max) |
| `t_sol_method` | character | `"annual_mean"` | T_sol estimation: `"annual_mean"` or `"constant"` |
| `t_sol_constant` | numeric | `10` | T_sol value when method = `"constant"` (°C) |

Existing fields used by PAC 1 (unchanged):
- `p_pac_kw` → PAC 1 power
- `cop_nominal` → PAC 1 COP nominal
- `t_ref_cop` → PAC 1 COP reference temperature

### Solver Output (extension of results tibble)

New columns added to the simulation results dataframe:

| Column | Type | Description |
|--------|------|-------------|
| `sim_pac1_on` | numeric | PAC 1 state: binary 0/1 (onoff) or fraction 0-1 (inverter) |
| `sim_pac2_load` | numeric | PAC 2 load fraction [0, 1] (inverter) or binary 0/1 (onoff) |
| `sim_pac1_kwh` | numeric | PAC 1 electrical consumption per qt (kWh) |
| `sim_pac2_kwh` | numeric | PAC 2 electrical consumption per qt (kWh) |
| `sim_cop1` | numeric | PAC 1 COP at this timestep |
| `sim_cop2` | numeric | PAC 2 COP at this timestep |

Existing columns preserved (backward-compatible):
- `sim_pac_on` = `sim_pac1_on + sim_pac2_load` (combined, for existing visualizations)
- `sim_t_ballon`, `sim_offtake`, `sim_intake`, `sim_cop` (= weighted average COP)
- `batt_soc`, `batt_flux`, `decision_raison`, `mode_actif`

### T_sol Vector (new column in simulation dataframe)

| Column | Type | Description |
|--------|------|-------------|
| `t_sol` | numeric | Estimated ground temperature per qt (°C), derived from T_ext |

## State Transitions

### PAC 2 Activation Flow

```
pac2_active = FALSE (default)
  → Solver = existing MILP/LP/QP (unchanged behavior)
  → Output has sim_pac2_load = 0, sim_pac2_kwh = 0

pac2_active = TRUE
  → Solver = DualOptimizer (new)
  → Output has sim_pac1_on, sim_pac2_load, ventilation KPIs
```

### Solver Selection Logic

```
if (!pac2_active) {
  # Existing behavior — unchanged
  use MILPOptimizer / LPOptimizer / QPOptimizer based on user choice
} else {
  # New dual mode
  use DualOptimizer (always MILP-based, ramp smoothing for inverter)
}
```

## Validation Rules

- `pac2_active` must be logical
- `pac2_type` must be in `c("ashp", "gshp")`
- `pac2_mode` must be in `c("onoff", "inverter")`
- `p_pac2_kw` must be > 0 and <= 100 (reasonable range for collective PAC)
- `cop2_nominal` must be in [1.5, 6.0]
- `ramp_max` must be in (0, 1] — 0 would mean PAC2 can never change state
- If `pac1_mode == "inverter"` and `pac2_mode == "onoff"`, the roles are simply swapped in the MILP (binary for PAC2, continuous for PAC1)
- At least one PAC must be active (pac1 is always active)
