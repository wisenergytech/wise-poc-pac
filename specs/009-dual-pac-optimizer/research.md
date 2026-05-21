# Research: Dual PAC Optimizer

**Feature**: `009-dual-pac-optimizer`
**Date**: 2026-05-21

## R1: ompr/HiGHS support for mixed binary+continuous+ramp MILP

**Decision**: Use ompr + ROI.plugin.highs (existing stack), no new dependency needed.

**Rationale**: Our existing `optimizer_milp.R` already combines binary variables (`pac_on[t]`, `batt_ch[t]`) with continuous variables (`offt[t]`, `inj[t]`, `chrg[t]`, `dischrg[t]`) in a single MIPModel. The ramp constraints are standard linear inequalities (`p[t] - p[t-1] <= ramp_max`). HiGHS handles this natively — it's a general-purpose MIP solver.

**Alternatives considered**:
- CVXR MIQP (Mixed Integer Quadratic): would allow quadratic smoothing (`sum_squares`) but CLARABEL's MIQP support is experimental and slower. Rejected for performance.
- Two separate solvers (MILP for PAC1, LP for PAC2): rejected because the two PACs are coupled through the same thermal constraint — separation loses the global optimum.

## R2: Smoothing approach — ramp constraints vs quadratic penalty

**Decision**: Linear ramp constraints (`|Delta p| <= ramp_max`) within ompr MILP.

**Rationale**: D'Ettorre et al. 2019 use ramp constraints in their MILP+MPC formulation for hybrid heat pumps. This approach:
- Stays within the MILP framework (no need for QP/MIQP solver)
- Is compatible with HiGHS (fast, reliable)
- Provides deterministic smoothing (guaranteed max change per step)
- Adds only 2×(N-1) linear constraints per block — negligible solver overhead

**Alternatives considered**:
- Quadratic smoothing (`sum_squares(Dp)` as in our `optimizer_qp.R`): requires CVXR + MIQP solver (CLARABEL). Would prevent using binary variables for PAC1, defeating the purpose. Rejected.
- No smoothing: would make the inverter behave like a second on/off PAC. Rejected — loses the physical advantage of an inverter.

**Implementation**:
```r
# In optimizer_dual.R, after defining p_pac2[t]:
add_constraint(p_pac2[t] - p_pac2[t - 1] <= ramp_max, t = 2:n)
add_constraint(p_pac2[t - 1] - p_pac2[t] <= ramp_max, t = 2:n)
```
Default `ramp_max = 0.3` (30% of P_max per quarter-hour, configurable via params).

## R3: COP function for GSHP (ground source)

**Decision**: New function `calc_cop_gshp(t_sol, cop_nominal, t_ref, t_ballon)` with different parameters than the existing `calc_cop()` (which is ASHP).

**Rationale**: GSHP has a more stable COP because T_sol varies slowly (8-12°C annually in Belgium at 2-3m depth). The sensitivity to source temperature is lower than ASHP (+0.08/°C vs +0.1/°C for ASHP). COP nominal is typically higher (4.5 vs 3.5) because the ground is warmer than winter air.

**Parameters**:
```r
calc_cop_gshp <- function(t_sol, cop_nominal = 4.5, t_ref = 10,
                          t_ballon = NULL, t_ballon_ref = 50) {
  cop <- cop_nominal + 0.08 * (t_sol - t_ref)
  if (!is.null(t_ballon)) {
    cop <- cop * (1 - 0.01 * (t_ballon - t_ballon_ref))
  }
  pmax(2.0, pmin(6.0, cop))
}
```

**Alternatives considered**:
- Using HPLIB (Python library with manufacturer-specific COP curves): would add a Python dependency and cross-language call. Overkill for POC. Can be added later.
- Single `calc_cop()` with a `source_type` parameter: rejected for clarity — the two functions have different defaults, ranges, and sensitivities.

## R4: T_sol estimation (proxy saisonnier)

**Decision**: Derive T_sol from T_ext using a seasonal dampening model.

**Rationale**: At 2-3m depth in Belgium, ground temperature is approximately the annual mean air temperature, with dampened seasonal oscillation. Wang et al. 2022 use a similar approach. For a POC, this is sufficient — adding a soil temperature API or sensor would be out of scope.

**Formula**:
```r
# Pre-compute once per simulation period
t_ext_annual_mean <- mean(df$t_ext, na.rm = TRUE)  # ~10°C in Belgium
# Monthly smoothing with 0.3 dampening factor (2-3m depth)
t_sol <- t_ext_annual_mean + 0.3 * (rollmean_monthly(df$t_ext) - t_ext_annual_mean)
```

For simplicity in the first implementation, a constant `T_sol` per simulation (= annual mean T_ext) is acceptable. The seasonal variation can be added as a refinement.

**Alternatives considered**:
- Open-Meteo soil temperature API: exists (`soil_temperature_6cm`, `soil_temperature_18cm`) but not deep enough (need 2-3m). Rejected.
- Constant value (10°C): too simplistic for sites with large seasonal variation. Rejected in favor of at least annual-mean calculation.

## R5: Iterative COP refinement with two COP curves

**Decision**: Extend the existing 2-pass COP loop in `BaseOptimizer$solve()` to update both COP1 and COP2 after the first solve pass.

**Rationale**: The current code (`R6_optimizer.R:74-82`) does:
1. Solve with COP(T_ext, T_consigne)
2. Get T_ballon trajectory from solution
3. Re-solve with COP(T_ext, T_ballon_solved)

For dual, this becomes:
1. Solve with COP1(T_sol, T_consigne) + COP2(T_ext, T_consigne)
2. Get T_ballon trajectory
3. Re-solve with COP1(T_sol, T_ballon_solved) + COP2(T_ext, T_ballon_solved)

Both COP curves depend on the same T_ballon, so one re-solve pass updates both. No change to the iteration structure — just two `cop_override` vectors instead of one.

## R6: Performance impact assessment

**Decision**: Block size stays at 4h (default). Solver should remain fast enough.

**Rationale**: The dual formulation adds per block of N quarter-hours:
- N binary variables (y_pac1) — same count as existing pac_on
- N continuous variables (p_pac2) — same complexity as existing pac_load in LP
- 2×(N-1) ramp constraints — linear, cheap for HiGHS

For N=32 (4h block + 4h lookahead), this doubles the variable count from ~7N to ~8N but stays well within HiGHS capabilities (thousands of variables are routine). Expected solve time: <2s per block (vs ~1s for mono-PAC).

If performance is an issue, `ramp_max` can be relaxed (fewer binding constraints = faster solve).
