# Business Logic: Dual PAC Optimizer (ASHP+GSHP couple)

**Feature Branch**: `009-dual-pac-optimizer`
**Created**: 2026-05-21

## Core Business Rules

### BL-001: Activation optionnelle de la seconde PAC
La seconde PAC (PAC 2) est desactivee par defaut. Lorsqu'elle est desactivee, le comportement de l'application est strictement identique aux solveurs existants (MILP/LP/QP mono-PAC). Aucune regression n'est acceptable sur les scenarios mono-PAC.

*Derive de FR-001 et SC-005.*

### BL-002: Configuration independante de chaque PAC
Chaque PAC se configure independamment avec quatre parametres : type de source (ASHP — air/eau, ou GSHP — sol/eau), puissance nominale en kW, mode de fonctionnement (on/off binaire ou inverter continu), et COP nominal. Les parametres de PAC 1 restent modifiables meme quand PAC 2 est activee.

*Derive de FR-002.*

### BL-003: Dispatch conjoint via un unique solveur
Quand PAC 2 est activee, l'optimiseur formule un seul probleme d'optimisation combinant les variables de decision des deux PAC. Il n'est pas permis de resoudre les deux PAC separement, car elles sont couplees par la contrainte thermique du meme ballon.

*Derive de FR-003 et de la contrainte d'un ballon unique (Assumptions).*

### BL-004: Modelisation COP differenciee par type de source
- Une PAC de type ASHP utilise une fonction COP dependant de la temperature exterieure (T_ext) et de la temperature du ballon.
- Une PAC de type GSHP utilise une fonction COP dependant de la temperature du sol (T_sol) et de la temperature du ballon.
Ces deux fonctions sont evaluees independamment pour chaque pas de temps.

*Derive de FR-004.*

### BL-005: Lissage obligatoire pour une PAC en mode inverter
Une PAC configuree en mode inverter ne peut pas varier sa puissance de plus de `ramp_max` (exprime en fraction de la puissance nominale) entre deux pas de temps consecutifs. Cette contrainte s'applique dans les deux sens (montee et descente). Une PAC en mode on/off n'est pas soumise a cette contrainte.

*Derive de FR-003 (C5) et US3.*

### BL-006: Raffinement iteratif des COP — deux passes
L'optimisation se deroule en deux passes. Apres la premiere passe, les COP des deux PAC sont recalcules avec les temperatures de ballon resultantes, puis l'optimisation est relancee. Cette procedure s'applique aux deux COP independamment.

*Derive de FR-005.*

### BL-007: Guard anti-regression — le dual ne doit jamais degrader le cout
A l'issue de la simulation duale, le cout net obtenu est compare au meilleur cout mono-PAC (PAC 1 seule ou PAC 2 seule). Si le cout dual est superieur, la simulation revient automatiquement au resultat mono-PAC le moins cher. Ce guard est non-negociable et s'applique a chaque execution.

*Derive de FR-006 et SC-001.*

### BL-008: Format de sortie compatible avec les solveurs existants
Les resultats du solveur dual sont produits dans le meme format que les solveurs existants (sim_offtake, sim_intake, sim_t_ballon, sim_cop), augmente de quatre colonnes : sim_pac1_on (binaire), sim_pac2_load (fraction continue [0,1]), sim_pac1_kwh, sim_pac2_kwh.

*Derive de FR-007.*

### BL-009: Heritage de la classe de base — DualOptimizer
`DualOptimizer` herite de `BaseOptimizer` et surcharge uniquement `solve_block()`. Toute logique commune (gestion des blocs temporels, fallback baseline, interface de resultats) reste dans la classe de base et n'est pas dupliquee.

*Derive de FR-008.*

### BL-010: Extension du modele thermique pour deux sources
Le modele thermique est etendu pour accepter deux termes de production thermique (PAC 1 et PAC 2) sur un meme ballon. La dynamique du ballon applique les deux contributions a chaque pas de temps.

*Derive de FR-009.*

### BL-011: Estimation du proxy T_sol quand aucune mesure n'est disponible
En l'absence de donnee de temperature du sol mesuree, T_sol est estimee par la formule :
```
T_sol[t] = T_annuelle_moyenne + 0.3 * (T_mensuelle_moyenne[t] - T_annuelle_moyenne)
```
Ce proxy est calcule a partir de T_ext et represent une profondeur de sol de 2-3 m.

*Derive de FR-010 et de l'edge case "T_sol manquant".*

### BL-012: Inalterable — solveurs existants
Les solveurs MILP, LP et QP mono-PAC existants ne sont pas modifies. Ils restent les seuls solveurs actifs quand PAC 2 est desactivee.

*Derive de FR-011 et SC-005.*

## Business Invariants

- La temperature du ballon doit rester dans l'intervalle [T_min - slack, T_max] a chaque pas de temps (contrainte de confort soft + T_max hard).
- Les deux PAC alimentent toujours le meme ballon thermique ; les ballons separes ne sont pas geres dans cette version.
- Le cout optimise par le solveur dual est toujours inferieur ou egal au meilleur resultat mono-PAC (garanti par BL-007).
- La variation de puissance de la PAC inverter ne depasse jamais ramp_max entre deux pas de temps consecutifs (garanti par BL-005).
- Les solveurs existants passent tous leurs tests sans modification (retrocompatibilite totale).

## Formulas & Calculations

### COP ASHP (air/eau)
```
COP_ASHP(T_ext, T_ballon) = f(T_ext, T_ballon)
```
Sensible a T_ext : plus T_ext est basse, plus le COP diminue. Meme formule que l'existant `calc_cop`.

### COP GSHP (sol/eau)
```
COP_GSHP(T_sol, T_ballon) = f(T_sol, T_ballon)
```
Plus stable que ASHP car T_sol varie lentement. T_sol estimee par le proxy saisonnier (BL-011).

### Proxy saisonnier T_sol
```
T_sol[t] = T_annuelle_moyenne + 0.3 * (T_mensuelle_moyenne[t] - T_annuelle_moyenne)
```
Typiquement 8-12 degres Celsius en Belgique.

### Critere de succes du dispatch (SC-001)
```
cout_dual <= min(cout_mono_PAC1, cout_mono_PAC2)  sur >= 90% des scenarios testes
```

### Contrainte de rampe inverter
```
p_pac2[t] - p_pac2[t-1] <=  ramp_max
p_pac2[t-1] - p_pac2[t] <=  ramp_max
pour t = 2..N
```

## State Transitions

### Etat du solveur dual

```
[PAC2 desactivee]
      |
      | Utilisateur active PAC 2 et configure ses parametres
      v
[Configuration duale prete]
      |
      | Lancement simulation
      v
[Passe 1 : MILP dual resolu]
      |
      | Mise a jour COP1 et COP2 avec T_ballon resultant
      v
[Passe 2 : MILP dual raffine]
      |
      | Guard anti-regression
      +--[cout dual > cout mono]---> [Revert vers meilleur mono-PAC]
      |
      v
[Resultats duaux affiches]
```

### Etat de la PAC inverter (par pas de temps)

```
p_pac2[t-1]  -->  p_pac2[t]  avec |Delta p| <= ramp_max
p_pac2[t] in [0, 1]  (0 = arret, 1 = pleine puissance)
```
