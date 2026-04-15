# Data Model: MILP Optimizer Mode

**Feature**: 001-milp-optimizer
**Date**: 2026-04-14

## Entities

### OptimizationResult

Resultat d'une optimisation MILP sur une periode donnee. Produit les memes colonnes que `run_simulation()` pour compatibilite avec les graphiques et KPIs existants.

| Champ | Type | Description |
|-------|------|-------------|
| timestamp | POSIXct | Horodatage quart-horaire |
| sim_pac_on | Integer (0/1) | Decision PAC ON/OFF optimale |
| sim_t_ballon | Numeric | Temperature ballon simulee (C) |
| sim_offtake | Numeric | Soutirage reseau optimal (kWh) |
| sim_intake | Numeric | Injection reseau optimale (kWh) |
| sim_cop | Numeric | COP au moment t |
| decision_raison | Character | "optimizer" (constant) |
| batt_soc | Numeric | SOC batterie (0-1) |
| batt_flux | Numeric | Flux batterie (+ charge, - decharge) |

### OptimizationDay

Unite de resolution : un jour = 96 quarts d'heure. Le solveur MILP est invoque une fois par jour.

| Champ | Type | Description |
|-------|------|-------------|
| date | Date | Jour concerne |
| t_init | Numeric | Temperature initiale du ballon (fin du jour precedent) |
| soc_init | Numeric | SOC initial batterie (fin du jour precedent) |
| solve_time_ms | Numeric | Temps de resolution du solveur |
| status | Character | "success", "infeasible", "timeout" |
| objective_value | Numeric | Cout net optimal du jour (EUR) |

## Relations

```
OptimizationDay 1 ──── N OptimizationResult
  (1 jour)              (96 quarts d'heure)
```

Chaque `OptimizationDay` produit 96 lignes `OptimizationResult`. Le `t_init` du jour J+1 est le `sim_t_ballon` du dernier quart d'heure du jour J.

## State Transitions

```
Jour J-1 fin ──[t_ballon, soc]──► Jour J init ──[MILP solve]──► Jour J resultats ──► Jour J+1 init
```
