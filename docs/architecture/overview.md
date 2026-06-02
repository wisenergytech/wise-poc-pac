# Architecture Overview

**Project**: wise-poc-pac (PAC Optimizer — Proof of Concept)
**Created**: 2026-06-02
**Stack**: R 4.5+ / Shiny / golem / R6

Ce document décrit l'architecture systeme de haut niveau. Il est mis a jour incrementalement a chaque feature. Pour les details d'implementation, se reporter aux `plan.md` de chaque spec.

---

## Vue d'ensemble

L'application est une Shiny app structuree avec golem. Elle simule et optimise la consommation d'une PAC (ou deux PAC en mode dual) en regard de la production PV et du profil de soutirage/injection. Les donnees entrent via CSV importe ou via un mode Demo (donnees generees en memoire).

```
[CSV utilisateur]  -->  [Mapping dynamique (spec:010)]
[Mode Demo]        -->  [DataGenerator (R6)]
                           |
                           v
                   [Simulation (R6_simulation)]
                           |
                   [Optimizer (R6 class hierarchy)]
                   ├── BaseOptimizer
                   ├── MILPOptimizer    (spec:001)
                   ├── LPOptimizer
                   ├── QPOptimizer
                   ├── SmartOptimizer
                   └── DualOptimizer   (spec:009)
                           |
                           v
                   [KPICalculator (R6)]
                           |
                           v
                   [Shiny UI — modules]
                   ├── mod_sidebar      (config + import CSV)
                   ├── mod_comparaison  (explorateur donnees)
                   └── mod_kpis
```

---

## Composants principaux

### DataGenerator (R6)
- Source : `R/R6_data_generator.R`
- Role : charge les donnees (CSV ou Demo), applique le mapping de colonnes (spec:010), prepare le dataframe interne au format standard.
- Introduit par : spec:002 (golem/R6 refactor)
- Modifie par : spec:004 (solar scaling), spec:005 (baseline mesure), spec:010 (mapping CSV dynamique)

### Optimizer — classe de base et specialisations (R6)
- Source : `R/R6_base_optimizer.R`, `R/R6_milp_optimizer.R`, etc.
- Role : resout le probleme d'optimisation PAC sur un horizon de simulation par blocs temporels.
- Introduit par : spec:001 (MILP), spec:002 (R6 refactor)
- Etendu par : spec:009 (DualOptimizer — ASHP+GSHP couple)

### DualOptimizer (R6, herite de BaseOptimizer)
- Source : `R/R6_dual_optimizer.R`
- Role : dispatch conjoint de deux PAC (ASHP+GSHP) avec raffinement iteratif des COP et guard anti-regression.
- Introduit par : spec:009
- Active automatiquement quand une colonne PAC 2 est mappee (spec:010, BL-010-008)

### fct_csv_mapping.R (pure function, pas de Shiny)
- Source : `R/fct_csv_mapping.R`
- Role : matching par mots-cles entre noms de colonnes CSV et champs internes. Aucune dependance Shiny — testable unitairement.
- Introduit par : spec:010

### ThermalModel (R6)
- Source : `R/R6_thermal_model.R`
- Role : dynamique du ballon thermique (un ou deux termes de production). Etendu pour le dual par spec:009.

### mod_sidebar (Shiny module)
- Source : `R/mod_sidebar.R`
- Role : configuration utilisateur (params simulation, import CSV, mapping colonnes, config PAC).
- Modifie par : spec:010 (panneau de mapping dynamique)

### mod_comparaison (Shiny module)
- Source : `R/mod_comparaison.R`
- Role : explorateur de series temporelles. Depuis spec:010, les dropdowns proposent les colonnes reelles du CSV importe.

---

## Interfaces entre composants

| Source | Destination | Donnees transmises |
|--------|-------------|-------------------|
| DataGenerator | Simulation | dataframe au format interne standard (timestamp, pv_kwh, offtake_kwh, ...) |
| Simulation | Optimizer | bloc temporel + parametres PAC |
| Optimizer | KPICalculator | sim_offtake, sim_intake, sim_t_ballon, sim_cop, (dual: sim_pac1_kwh, sim_pac2_kwh) |
| mod_sidebar | DataGenerator | chemin CSV + mapping colonnes (spec:010) |
| mod_sidebar | Optimizer | type solveur, params PAC 1, params PAC 2 (spec:009) |

---

## Format CSV standard (interface DataGenerator)

```
timestamp, pv_kwh, offtake_kwh, feedin_kwh, pac_kwh, t_ballon, cop, t_ext
```

Depuis spec:010, ce format est le format *interne* uniquement. Les CSV utilisateur peuvent avoir des noms de colonnes quelconques, remappes dynamiquement avant traitement.

---

## Historique des decisions

| Decision | Spec | Resume |
|----------|------|--------|
| Architecture golem + R6 | spec:002 | Separation modules Shiny / logique metier R6 |
| BaseOptimizer + specialisations | spec:002/003 | Heritage R6, solve_block() surchargeable |
| DualOptimizer (ASHP+GSHP) | spec:009 | Surcharge solve_block(), guard anti-regression |
| fct_csv_mapping isole (pure function) | spec:010 | Testabilite sans Shiny (Constitution XI) |
| Mapping dynamique colonnes CSV | spec:010 | Remplacement de l import CSV rigide par selecteurs dynamiques |
