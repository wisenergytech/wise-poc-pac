# Data Model: Wire R6 Classes into Shiny Modules

No new entities are introduced. This feature rewires existing code to use existing R6 classes.

## Existing Entities (unchanged)

### Simulation (R6 orchestrator)
- **State**: idle → loading → data_loaded → running_baseline → baseline_done → running_optimization → done
- **Holds**: raw_data, prepared_data, baseline_result, optim_result, params, thermal_model, kpi_calc
- **Methods**: load_data(), run_baseline(), run_optimization(), get_results(), get_baseline(), get_kpi(), export_csv()

### SimulationParams (R6 parameter container)
- **Fields**: All parameters from sidebar (p_pac_kw, volume_ballon_l, pv_kwc, type_contrat, baseline_mode, etc.)
- **Auto-computed**: t_min, t_max, capacite_kwh_par_degre (via active bindings)
- **Backward compatible**: as_list() returns plain named list

### Reactive Interface (Shiny-specific, unchanged)

| Reactive | Source | Consumers | Type |
|----------|--------|-----------|------|
| `sim_filtered()` | mod_sidebar | mod_energie, mod_finances, mod_details, mod_contraintes, mod_co2 | Dataframe (date-filtered simulation result) |
| `params_r()` | mod_sidebar | mod_energie, mod_finances, mod_details, mod_contraintes, mod_dimensionnement | Named list of parameters |
| `raw_data()` | mod_sidebar | mod_dimensionnement | Raw dataframe before prepare_df |
| `baseline_type()` | mod_sidebar | mod_dimensionnement | Character (baseline mode name) |

The reactive interface between modules does NOT change. Only the internal implementation of how `sim_filtered()` is computed changes.
