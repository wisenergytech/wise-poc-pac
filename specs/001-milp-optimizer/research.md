# Research: MILP Optimizer Mode

**Feature**: 001-milp-optimizer
**Date**: 2026-04-14

## R1: MILP Solver for R — ompr + GLPK

**Decision**: Utiliser `ompr` + `ompr.roi` + `ROI.plugin.glpk` (tous sur CRAN, maintenus en 2025).

**Rationale**: ompr offre une syntaxe declarative lisible (pipe-friendly) pour formuler des problemes MILP en R, equivalente a PuLP en Python. GLPK est le solveur open-source de reference, suffisant pour les tailles de problemes visees.

**Alternatives considered**:
- `lpSolveAPI` : plus bas niveau, moins lisible, pas de support binaire natif elegant
- `Rglpk` direct : interface C brutale, pas de couche d'abstraction
- Commercial (Gurobi, CPLEX) : performances superieures mais cout de licence, hors scope POC

## R2: Performance GLPK sur grands problemes

**Decision**: Resoudre par blocs journaliers (96 qt = 1 jour) enchaines, pas en un seul probleme monolithique de 35 000 variables.

**Rationale**: Un benchmark montre que GLPK resout un MIP de 45 000 variables binaires en ~10 min. Pour respecter SC-003 (30s max pour 180 jours), la resolution journaliere est necessaire : 96 variables binaires par jour se resout en <0.5s. Le SOC initial de chaque jour = SOC final du jour precedent.

**Alternatives considered**:
- Probleme monolithique : risque de timeout sur GLPK pour >30 jours
- Rolling horizon (7j glissants) : plus complexe sans gain majeur vs journalier pour le backtest

## R3: Integration Shiny — blocage UI

**Decision**: Utiliser `withProgress()` Shiny standard pour le feedback utilisateur. La resolution journaliere (~0.5s/jour) permet de mettre a jour la barre de progression a chaque jour resolu sans bloquer excessivement.

**Rationale**: La resolution jour par jour transforme un gros solve de 30s en 180 petits solves de <0.5s chacun, avec mise a jour du progress bar entre chaque. Pas besoin de `ExtendedTask` / `future_promise` pour cette approche.

**Alternatives considered**:
- `ExtendedTask` + `future_promise` : necessaire si solve monolithique, surdimensionne pour l'approche journaliere
- Pas de feedback : mauvaise UX sur les simulations longues

## R4: Formulation MILP pour PAC + ballon + batterie

**Decision**: Formulation jour par jour avec les variables et contraintes suivantes.

### Variables par quart d'heure t (dans un jour de 96 qt)

| Variable | Type | Bornes | Description |
|----------|------|--------|-------------|
| `pac_on[t]` | Binaire | {0, 1} | PAC allumee ou non |
| `t_ballon[t]` | Continue | [T_min, T_max] | Temperature ballon |
| `offtake[t]` | Continue | [0, P_max_sout] | Soutirage reseau |
| `injection[t]` | Continue | [0, +Inf] | Injection reseau |
| `charge[t]` | Continue | [0, P_batt] | Charge batterie |
| `discharge[t]` | Continue | [0, P_batt] | Decharge batterie |
| `soc[t]` | Continue | [SOC_min, SOC_max] | Etat de charge |
| `batt_charging[t]` | Binaire | {0, 1} | Anti-simultaneite |

### Fonction objectif

```
min sum_t( offtake[t] * prix_offtake[t] - injection[t] * prix_injection[t] )
```

### Contraintes

1. **Bilan energetique nodal** : `pv[t] + offtake[t] + discharge[t]*eff = conso_base[t] + pac_on[t]*P_pac + charge[t] + injection[t]`
2. **Dynamique thermique** : `t_ballon[t] = t_ballon[t-1] + (pac_on[t]*P_pac*COP[t] - perte[t] - ecs[t]) / capacite`
3. **Bornes temperature** : implicites dans les bounds de `t_ballon[t]`
4. **SOC batterie** : `soc[t] = soc[t-1] + charge[t]*eff_ch - discharge[t]/eff_dis`
5. **Anti-simultaneite** : `charge[t] <= P_batt * batt_charging[t]` et `discharge[t] <= P_batt * (1 - batt_charging[t])`
6. **Condition initiale** : `t_ballon[1] = T_prev_day_end`, `soc[1] = SOC_prev_day_end`

## R5: Architecture UI — separation Rule-based vs Optimiseur

**Decision**: Un `radioButtons` de premier niveau "Approche" (Rule-based / Optimiseur) controle la visibilite des sous-options via `conditionalPanel`.

**Rationale**: Separation visuelle claire des deux philosophies. L'utilisateur comprend immediatement qu'il s'agit de deux approches fondamentalement differentes, pas juste un mode supplementaire.

**Alternatives considered**:
- Ajouter "Optimizer" comme 6e mode dans le selecteur existant : confusion, l'utilisateur ne comprend pas la difference conceptuelle
- Deux onglets separes : trop lourd, empeche la comparaison directe
