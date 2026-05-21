# Flows: Dual PAC Optimizer (ASHP+GSHP couple)

**Feature Branch**: `009-dual-pac-optimizer`
**Created**: 2026-05-21

## Flow 1: Configuration et activation de PAC 2 (US1 — P1)

L'utilisateur active une seconde PAC dans le sidebar et configure ses parametres. Ce flux couvre le chemin nominal et le chemin de desactivation (retrocompatibilite).

```mermaid
flowchart TD
    A([Utilisateur ouvre l'application]) --> B{PAC 2 activee ?}
    B -- Non --> C[Comportement identique aux solveurs existants]
    B -- Oui --> D[Sidebar affiche les controles PAC 2]
    D --> E[Utilisateur configure :\ntype ASHP/GSHP\npuissance kW\nmode on/off ou inverter\nCOP nominal]
    E --> F{Mode inverter ?}
    F -- Oui --> G[Controles supplementaires :\npuissance min\nramp_max]
    F -- Non --> H[Parametres PAC 2 valides]
    G --> H
    H --> I[Recap sidebar affiche PAC 1 + PAC 2]
    I --> J([Pret a lancer la simulation duale])
    C --> K([Simulation mono-PAC inchangee])
```

## Flow 2: Simulation et dispatch dual (US2 — P1)

L'optimiseur decide a chaque quart d'heure quelle PAC utiliser, en minimisant le cout total sur l'horizon de simulation. Deux passes de raffinement COP sont effectuees.

```mermaid
sequenceDiagram
    actor User
    participant UI as Shiny UI
    participant DualOpt as DualOptimizer (R6)
    participant MILP as optimizer_dual.R
    participant ThermalModel as ThermalModel
    participant Guard as Guard anti-regression
    participant MonoOpt as MILPOptimizer (existant)

    User->>UI: Lance simulation (PAC 2 active)
    UI->>DualOpt: solve(data, params_pac1, params_pac2)

    Note over DualOpt: Passe 1
    DualOpt->>DualOpt: Calcul COP1[t] (GSHP ou ASHP) avec T_ballon_prev
    DualOpt->>DualOpt: Calcul COP2[t] (ASHP ou GSHP) avec T_ballon_prev
    DualOpt->>MILP: solve_block_dual(bloc, COP1, COP2, params)
    MILP-->>DualOpt: y_pac1[t], p_pac2[t], t_bal[t], offt[t], inj[t]

    Note over DualOpt: Passe 2 (raffinement COP)
    DualOpt->>ThermalModel: thermal_step_dual(y_pac1, p_pac2, COP1, COP2)
    ThermalModel-->>DualOpt: T_ballon raffine
    DualOpt->>DualOpt: Recalcul COP1[t] et COP2[t] avec T_ballon raffine
    DualOpt->>MILP: solve_block_dual(bloc, COP1_v2, COP2_v2, params)
    MILP-->>DualOpt: Resultats finaux dual

    Note over Guard: Guard anti-regression
    DualOpt->>MonoOpt: solve(data, params_pac1 seule)
    MonoOpt-->>Guard: cout_mono_PAC1
    DualOpt->>Guard: cout_dual
    alt cout_dual > min(cout_mono)
        Guard-->>DualOpt: Revert — retourne meilleur mono-PAC
    else cout_dual <= min(cout_mono)
        Guard-->>DualOpt: Resultats duaux valides
    end
    DualOpt-->>UI: sim_offtake, sim_intake, sim_t_ballon, sim_cop,\nsim_pac1_on, sim_pac2_load, sim_pac1_kwh, sim_pac2_kwh
    UI-->>User: KPIs + graphiques ventiles PAC 1 / PAC 2
```

## Flow 3: Lissage inverter — validation de la contrainte de rampe (US3 — P1)

Ce flux illustre comment la contrainte de rampe garantit des transitions progressives pour une PAC en mode inverter.

```mermaid
sequenceDiagram
    participant MILP as optimizer_dual.R
    participant Solver as HiGHS (via ompr/ROI)

    Note over MILP: Pour chaque bloc temporel (4-8h)
    MILP->>Solver: Formule MILP avec contraintes de rampe :\np_pac2[t] - p_pac2[t-1] <= ramp_max\np_pac2[t-1] - p_pac2[t] <= ramp_max\npour t = 2..N

    Solver-->>MILP: Solution optimale respectant les rampes

    Note over MILP: Verification post-solve
    MILP->>MILP: Assert max(|Delta p_pac2|) <= ramp_max
    alt Violation detectee (infaisabilite numerique)
        MILP-->>MILP: Fallback baseline (meme pattern que mono-PAC)
    else Contrainte respectee
        MILP-->>MILP: Resultats valides
    end
```

## Flow 4: Affichage de la ventilation PAC 1 / PAC 2 (US4 — P2)

Apres une simulation duale, l'utilisateur consulte la repartition des contributions energetiques et financieres.

```mermaid
flowchart TD
    A([Simulation duale terminee]) --> B[DualOptimizer retourne\nsim_pac1_kwh, sim_pac2_kwh\nsim_pac1_cost, sim_pac2_cost]
    B --> C[mod_comparaison calcule :\npart PAC1 en % kWh\npart PAC2 en % kWh\ncout PAC1 EUR\ncout PAC2 EUR]
    C --> D[Affichage KPIs ventiles]
    C --> E[Graphique puissance PAC :\nPAC 1 en bleu — creneaux on/off\nPAC 2 en orange — courbe lisse inverter]
    D --> F([Utilisateur comprend la strategie de dispatch])
    E --> F
```

## Flow 5: Chemin d'erreur — bloc infaisable (Edge case)

Quand le solveur dual ne trouve pas de solution feasible pour un bloc temporel, le fallback baseline s'applique.

```mermaid
flowchart TD
    A([solve_block_dual appele]) --> B{HiGHS retourne\nune solution ?}
    B -- Oui --> C[Resultats duaux du bloc]
    B -- Non : infaisable ou timeout --> D[Fallback : baseline du bloc\nmeme que solveurs existants]
    D --> E[Log message de warning]
    E --> F[Simulation continue sur le bloc suivant]
    C --> G([Bloc integre dans les resultats globaux])
    F --> G
```
