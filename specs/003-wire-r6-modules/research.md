# Research: Wire R6 Classes into Shiny Modules

## R1: Do R6 classes produce the same dataframe columns as legacy functions?

**Decision**: Yes — validated at 0.0% parity deviation during 002-golem-r6-refactor.

**Rationale**: The R6 classes (`DataGenerator$generate_demo()`, `DataGenerator$prepare_df()`, `Baseline$run()`, `*Optimizer$solve()`) wrap the same logic as fct_legacy.R functions. The output columns are identical:
- Baseline adds: `t_ballon`, `offtake_kwh`, `intake_kwh`
- Optimization adds: `sim_t_ballon`, `sim_pac_on`, `sim_offtake`, `sim_intake`, `sim_cop`, `decision_raison`, `batt_soc`, `batt_flux`

**Alternatives considered**: None — this was already proven.

## R2: Can params_r() (plain list) be passed directly to Simulation$new()?

**Decision**: Yes — `Simulation$new()` accepts both a `SimulationParams` R6 object or a plain list.

**Rationale**: See `R6_simulation.R` lines 17-23:
```r
if (inherits(params, "SimulationParams")) {
  private$params_obj <- params
  private$params <- params$as_list()
} else {
  private$params <- params
}
```

This means we can either:
- Option A: Keep `params_r()` as a plain list, pass directly to `Simulation$new(params_r())`
- Option B: Convert `params_r()` to `SimulationParams$new(...)` first

**Decision**: Use Option A for minimal change. The plain list works. SimulationParams conversion can be a future enhancement.

## R3: How to handle the optimizer mode mapping?

**Decision**: Map the sidebar `approche` input values to `Simulation$run_optimization(mode)`:

| Sidebar `approche` value | Legacy function | R6 equivalent |
|--------------------------|----------------|---------------|
| `"optimiseur"` | `run_optimization_milp()` | `sim$run_optimization("milp")` |
| `"optimiseur_lp"` | `run_optimization_lp()` | `sim$run_optimization("lp")` |
| `"optimiseur_qp"` | `run_optimization_qp()` | `sim$run_optimization("qp")` |
| `"smart"` | `run_simulation(mode="smart")` | `sim$run_optimization("smart")` |

**Rationale**: The R6 `Simulation$run_optimization()` already handles all 4 modes internally via switch/case.

## R4: What about the run_optimization_* functions in optimizer_*.R?

**Decision**: Keep `optimizer_lp.R`, `optimizer_milp.R`, `optimizer_qp.R` as-is. They are NOT part of fct_legacy.R.

**Rationale**: These files contain the actual solver implementations (`solve_block_lp()`, `solve_block()`, `solve_block_qp()`) AND the top-level `run_optimization_lp/milp/qp()` wrappers. The R6 optimizer classes (`LPOptimizer`, `MILPOptimizer`, `QPOptimizer`) call the `solve_block_*()` functions internally. The top-level `run_optimization_*()` wrappers will become dead code after this migration, but they can be cleaned up separately.

## R5: How to handle error fallbacks?

**Decision**: The current code wraps MILP/LP/QP in `tryCatch()` and falls back to `run_simulation(smart)`. The R6 path should do the same: `tryCatch(sim$run_optimization("milp"), error = function(e) sim$run_optimization("smart"))`.

**Rationale**: The `Simulation` class already has guard_baseline built in. The tryCatch pattern for solver failures is still needed at the module level.

## R6: Automagic scenario loops — how to handle?

**Decision**: Each scenario iteration creates a fresh `Simulation$new(params)` instance, calls `$load_data()` → `$run_baseline()` → `$run_optimization()`, and extracts KPIs via `$get_kpi()`.

**Rationale**: The R6 `Simulation` class is designed for exactly this pattern (see `scripts/validate_r6_standalone.R` which runs two independent instances). Each instance is fully isolated.

**Performance consideration**: Creating many `Simulation` instances in rapid succession is fine — R6 objects are lightweight. The heavy work is in the solvers, which are unchanged.
