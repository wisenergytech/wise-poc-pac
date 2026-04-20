# Data Model: Golem + R6 OOP Architecture

## Classes R6 — Diagramme de relations

```
SimulationParams (R6)
  |
  v
Simulation (R6) ──────> KPICalculator (R6)
  |                        |
  ├──> DataGenerator (R6)  └──> KPI results (list)
  |     └──> DataProvider (R6: Belpex, OpenMeteo, CO2)
  |
  ├──> Baseline (R6)
  |     └──> ThermalModel (R6)
  |
  └──> BaseOptimizer (R6)
        ├──> SmartOptimizer (R6)
        ├──> MILPOptimizer (R6)
        ├──> LPOptimizer (R6)
        └──> QPOptimizer (R6)
             └──> ThermalModel (R6)
```

## SimulationParams

Encapsule tous les parametres d'entree.

| Champ | Type | Description |
|---|---|---|
| t_consigne | numeric | Temperature consigne ballon (C) |
| t_tolerance | numeric | Tolerance +/- (C) |
| t_min, t_max | numeric | Bornes calculees (consigne +/- tolerance) |
| p_pac_kw | numeric | Puissance electrique PAC (kW) |
| cop_nominal | numeric | COP nominal de la PAC |
| t_ref_cop | numeric | Temperature de reference COP (C) |
| volume_ballon_l | numeric | Volume du ballon (L) |
| capacite_kwh_par_degre | numeric | Capacite thermique (kWh/C) |
| dt_h | numeric | Pas de temps (h), fixe a 0.25 |
| type_contrat | character | "fixe" ou "dynamique" |
| prix_fixe_offtake | numeric | Prix soutirage fixe (EUR/kWh) |
| prix_fixe_injection | numeric | Prix injection fixe (EUR/kWh) |
| taxe_transport_eur_kwh | numeric | Taxes reseau (EUR/kWh) |
| coeff_injection | numeric | Coefficient injection / spot |
| batterie_active | logical | Batterie activee |
| batt_kwh, batt_kw | numeric | Capacite et puissance batterie |
| batt_rendement | numeric | Rendement aller-retour |
| batt_soc_min, batt_soc_max | numeric | Bornes SOC |
| curtailment_active | logical | Curtailment active |
| curtail_kwh_per_qt | numeric | Limite injection par qt |
| slack_penalty | numeric | Penalite violation T_min (EUR/C) |
| optim_bloc_h | numeric | Taille bloc optimisation (h) |
| baseline_mode | character | Mode baseline choisi |
| pv_kwc, pv_kwc_ref | numeric | Puissance PV et reference |

## ThermalModel

Partage entre baseline et optimiseurs. Encapsule le modele physique.

| Methode | Entree | Sortie | Description |
|---|---|---|---|
| calc_cop(t_ext, t_ballon) | numerics | numeric | COP = f(T_ext, T_ballon) |
| thermal_step(t_prev, pac_on, cop, ecs) | numerics | numeric | T[t+1] calcule |
| energy_balance(pv, conso, pac_elec) | numerics | list(offtake, intake) | Bilan electrique |

| Constante | Valeur | Description |
|---|---|---|
| k_perte | 0.004 * dt_h | Coefficient de perte proportionnel |
| t_amb | 20 | Temperature ambiante fixe (C) |
| t_ballon_ref | 50 | Reference COP ballon (C) |

## Baseline

| Methode | Description |
|---|---|
| run(df, params) | Execute la simulation baseline selon le mode |
| set_mode(mode) | Definit le mode (reactif, programmateur, surplus_pv, ingenieur, proactif) |

| Etat interne | Type | Description |
|---|---|---|
| mode | character | Mode baseline actif |
| result | tibble | Resultat (t_ballon, offtake_kwh, intake_kwh) |

## BaseOptimizer (heritage)

| Methode publique | Description |
|---|---|
| initialize(params, data) | Initialise avec parametres et donnees preparees |
| solve() | Lance l'optimisation (boucle blocs + COP iteratif) |
| get_results() | Retourne le dataframe resultat |
| guard_baseline(baseline_data) | Compare avec baseline, fallback si pire |

| Methode privee (a override) | Description |
|---|---|
| solve_block(block_data, t_init, soc_init, prix_terminal) | Resout un bloc — DOIT etre implemente par chaque sous-classe |

| Sous-classe | Solveur | Variable PAC |
|---|---|---|
| SmartOptimizer | Heuristique (decider) | binaire (0/1) |
| MILPOptimizer | HiGHS via ompr | binaire (0/1) |
| LPOptimizer | HiGHS via ompr | continue [0,1] |
| QPOptimizer | CLARABEL via CVXR | continue [0,1] |

## DataGenerator

| Methode | Description |
|---|---|
| generate_demo(date_start, date_end, params) | Genere donnees synthetiques |
| prepare_df(df, params) | Prepare le dataframe (prix, ECS, COP) |

## DataProvider

| Methode | Description |
|---|---|
| get_belpex(date_start, date_end) | Charge prix Belpex (CSV + API fallback) |
| get_temperature(date_start, date_end) | Charge T_ext Open-Meteo |
| get_co2(date_start, date_end) | Charge intensite CO2 Elia |

## KPICalculator

| Methode | Description |
|---|---|
| compute(sim_data, baseline_data, params) | Calcule tous les KPI |
| get_facture(data) | Facture nette (EUR) |
| get_autoconsommation(data) | Taux autoconsommation (%) |
| get_conformite(data, params) | Conformite temperature (%) |
| get_bilan_electrique(data, params) | Residu bilan electrique |

## Simulation (orchestrateur)

| Methode | Description |
|---|---|
| initialize(params) | Cree avec SimulationParams |
| load_data(source, file) | Charge donnees (demo ou CSV) |
| run_baseline() | Lance la baseline selon le mode dans params |
| run_optimization(mode) | Lance l'optimisation (smart/milp/lp/qp) |
| get_kpi() | Retourne les KPI calcules |
| export_csv(path) | Exporte les resultats en CSV |
| get_status() | Retourne l'etat (idle, running, done, error) |

| Etat interne | Type | Description |
|---|---|---|
| params | SimulationParams | Parametres |
| raw_data | tibble | Donnees brutes |
| prepared_data | tibble | Donnees preparees (prix, ECS) |
| baseline_result | tibble | Resultat baseline |
| optim_result | tibble | Resultat optimise |
| kpi | list | KPI calcules |
| status | character | Etat (idle/running/done/error) |
