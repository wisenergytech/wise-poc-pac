# Feature Specification: Dual PAC Optimizer (ASHP+GSHP couple)

**Feature Branch**: `009-dual-pac-optimizer`
**Created**: 2026-05-21
**Status**: Draft
**Input**: See `discovery/009-dual-pac-optimizer.md` and `docs/knowledge/coupled-ashp-gshp-optimization.md`

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Configurer une installation a deux PAC (Priority: P1)

En tant qu'utilisateur, je veux pouvoir definir les caracteristiques de deux PAC distinctes dans le sidebar, afin que l'application modele fidelement mon installation reelle a deux pompes a chaleur.

**Why this priority**: Sans la configuration des deux PAC, le solveur dual n'a pas de donnees d'entree. C'est le prerequis de toute la feature.

**Independent Test**: L'utilisateur active "PAC 2" dans le sidebar, configure sa puissance et son type, et voit les deux PAC apparaitre dans le recap des parametres.

**Acceptance Scenarios**:

1. **Given** l'application est lancee avec les parametres par defaut, **When** l'utilisateur n'active pas PAC 2, **Then** le comportement est strictement identique a l'existant (retrocompatibilite).
2. **Given** l'utilisateur active PAC 2, **When** il configure puissance = 40 kW, type = GSHP, mode = on/off, **Then** le sidebar affiche les deux PAC avec leurs parametres respectifs.
3. **Given** l'utilisateur active PAC 2, **When** il configure type = ASHP, mode = inverter, **Then** les parametres specifiques a un inverter sont accessibles (puissance min, contrainte de rampe).

---

### User Story 2 - Optimiser le dispatch entre deux PAC (Priority: P1)

En tant qu'utilisateur, je veux que l'optimiseur decide automatiquement a chaque quart d'heure quelle PAC utiliser (PAC 1 seule, PAC 2 seule, les deux, ou aucune) en minimisant le cout total, afin de tirer parti des differences de COP entre les deux machines selon les conditions meteo et les prix.

**Why this priority**: C'est le coeur fonctionnel de la feature.

**Independent Test**: L'utilisateur lance une simulation dual sur 30 jours avec une GSHP on/off (20 kW) et une ASHP inverter (40 kW), et obtient un cout inferieur ou egal au meilleur resultat mono-PAC.

**Acceptance Scenarios**:

1. **Given** PAC 1 = GSHP 20 kW on/off (COP_nom 4.5) et PAC 2 = ASHP 40 kW inverter (COP_nom 3.5), **When** l'optimiseur tourne sur une periode hivernale (T_ext < 0°C), **Then** la GSHP est preferee (COP stable) et l'ASHP n'est utilisee que quand le besoin thermique depasse la capacite de la GSHP.
2. **Given** la meme configuration, **When** l'optimiseur tourne sur une periode de mi-saison (T_ext 10-15°C), **Then** l'ASHP est davantage utilisee (COP eleve grace a T_ext favorable) et la GSHP est reduite.
3. **Given** les deux PAC sont actives et les prix sont dynamiques, **When** le prix est tres bas (< 0.05 EUR/kWh), **Then** l'optimiseur peut activer les deux PAC simultanement pour prechauffer le ballon.
4. **Given** les deux PAC sont actives, **When** la simulation termine, **Then** le cout optimise est inferieur ou egal au cout qu'aurait donne chaque PAC utilisee seule (le dispatch ne doit jamais degrader le resultat).

---

### User Story 3 - Lissage de la PAC inverter (Priority: P1)

En tant qu'utilisateur, je veux que la PAC inverter fonctionne avec des transitions de puissance progressives (pas de sauts brusques ON/OFF), afin de preserver la longevite du compresseur et de refleter le comportement reel d'un inverter.

**Why this priority**: Le lissage est ce qui distingue cette feature d'un simple doublement du MILP existant. C'est la raison pour laquelle on cree un 4eme solveur plutot que de reutiliser le MILP mono-PAC deux fois.

**Independent Test**: L'utilisateur lance une simulation avec PAC 2 = inverter, et la courbe de puissance de PAC 2 montre des transitions progressives (pas de 0 a P_max en un seul pas de temps).

**Acceptance Scenarios**:

1. **Given** PAC 2 est un inverter avec ramp_max = 0.3 (30% de P_max par quart d'heure), **When** la simulation tourne, **Then** la variation de puissance de PAC 2 entre deux pas de temps consecutifs ne depasse jamais 30% de P_max.
2. **Given** PAC 1 est on/off et PAC 2 est inverter, **When** le graphique de puissance PAC est affiche, **Then** PAC 1 montre des creneaux (0/P_nom) et PAC 2 montre une courbe lisse.

---

### User Story 4 - Voir la contribution de chaque PAC (Priority: P2)

En tant qu'utilisateur, je veux voir la ventilation de la consommation et du cout entre les deux PAC dans les KPIs et graphiques, afin de comprendre la strategie de dispatch.

**Why this priority**: La comprehension de la strategie est importante pour la confiance dans les resultats, mais l'optimisation fonctionne sans cette ventilation visuelle.

**Independent Test**: L'utilisateur lance une simulation dual et voit dans l'onglet Analyse la repartition PAC 1 vs PAC 2 en kWh et en EUR.

**Acceptance Scenarios**:

1. **Given** une simulation dual est terminee, **When** l'utilisateur consulte les KPIs, **Then** il voit : kWh PAC 1, kWh PAC 2, cout PAC 1, cout PAC 2, part relative (%).
2. **Given** une simulation dual est terminee, **When** l'utilisateur consulte le graphique de puissance PAC, **Then** les deux PACs sont representees avec des couleurs distinctes (empilees ou superposees).

---

### Edge Cases

- **PAC 2 desactivee** : comportement identique aux solveurs existants, aucune regression.
- **Deux PAC du meme type** (ex: deux ASHP on/off) : le solveur traite les deux avec la meme courbe COP, l'interet est le partage de charge.
- **T_sol manquant** : si pas de valeur configuree, utiliser le proxy saisonnier (moyenne annuelle T_ext lissee).
- **Bloc infaisable** : le fallback baseline s'applique comme pour les solveurs existants.
- **Guard anti-regression** : si le dual produit un cout superieur au meilleur mono-PAC, revert automatique.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Le systeme DOIT permettre d'activer/desactiver une seconde PAC dans le sidebar (desactivee par defaut).
- **FR-002**: Pour chaque PAC, le systeme DOIT permettre de configurer : type de source (ASHP/GSHP), puissance nominale (kW), mode de fonctionnement (on/off binaire ou inverter continu), et COP nominal.
- **FR-003**: Le systeme DOIT implementer un nouveau solveur (`optimizer_dual.R`) qui formule un seul MILP combinant :
  - Variables binaires pour les PAC on/off (y[t] in {0,1})
  - Variables continues pour les PAC inverter (p[t] in [0, 1])
  - Contraintes de rampe pour le lissage des PAC inverter (|Delta p| <= ramp_max)
  - Contrainte thermique couplee (un seul ballon, deux sources de chaleur)
- **FR-004**: Le systeme DOIT utiliser deux fonctions COP distinctes :
  - `calc_cop()` existant (R/fct_helpers.R:14) pour les PAC air/eau (ASHP)
  - `calc_cop_gshp(T_sol, T_ballon)` a creer dans R/fct_helpers.R pour les PAC eau/eau (GSHP), avec sensibilite +0.08/°C, COP nominal 4.5, bornes [2.0, 6.0]
- **FR-005**: Le raffinement COP iteratif (2 passes) DOIT mettre a jour les deux COP independamment apres la premiere passe.
- **FR-006**: Le guard anti-regression DOIT comparer le cout dual au cout mono-PAC baseline et revert si le dual est plus cher.
- **FR-007**: Le systeme DOIT produire des resultats dans le meme format que les solveurs existants (sim_offtake, sim_intake, sim_t_ballon, sim_cop) avec des colonnes supplementaires : sim_pac1_on, sim_pac2_load, sim_pac1_kwh, sim_pac2_kwh.
- **FR-008**: Une nouvelle classe R6 `DualOptimizer` DOIT heriter de `BaseOptimizer` et surcharger `solve_block()` pour deleguer a `optimizer_dual.R`.
- **FR-009**: La temperature du sol (`T_sol`) DOIT etre estimee par un proxy saisonnier derive de T_ext quand aucune mesure n'est disponible.
- **FR-010**: Les 3 solveurs existants (MILP, LP, QP) DOIVENT rester inchanges et fonctionnels.

### Key Entities

- **Dual Dispatch Plan** : ensemble des decisions PAC 1 (binaire) + PAC 2 (continu) + batterie pour chaque quart d'heure, calcule par le solveur MILP unifie.
- **Courbe COP duale** : deux fonctions COP(t) independantes, une par PAC, raffinee iterativement.
- **Contrainte de rampe** : limite lineaire sur la variation de puissance de la PAC inverter entre deux pas de temps consecutifs.
- **Proxy T_sol** : estimation saisonniere de la temperature du sol a partir de la moyenne annuelle de T_ext et d'un amortissement saisonnier.

## Business Logic

### Formulation MILP duale (references : IEEE 2019 MILP Dual Source HP, D'Ettorre 2019 MPC)

**Variables de decision** (par pas de temps t = 1..N) :
- `y_pac1[t]` : binaire {0,1} — PAC 1 on/off
- `p_pac2[t]` : continu [0, 1] — PAC 2 load fraction (inverter)
- `t_bal[t]` : continu — temperature ballon
- `offt[t]`, `inj[t]` : continu >= 0 — soutirage/injection reseau
- `slack[t]` : continu >= 0 — violation soft T_min
- `chrg[t]`, `dischrg[t]`, `soc[t]`, `batt_ch[t]` : batterie (si active)

**Objectif** :
```
min  Sum_t offt[t] * prix_offtake[t] - inj[t] * prix_injection[t]
   + Sum_t slack[t] * penalty
   - t_bal[N] * prix_terminal_per_deg
```

**Contraintes** :
```
C1 — Bilan energie :
  pv[t] + offt[t] == conso[t] + y_pac1[t]*P1_qt + p_pac2[t]*P2_qt + inj[t]
  (+ batterie si active)

C2 — Dynamique thermique couplee :
  t_bal[t] * cap == t_bal[t-1] * (cap - k_perte)
                  + y_pac1[t] * P1_qt * COP1[t]
                  + p_pac2[t] * P2_qt * COP2[t]
                  + k_perte * T_amb - ecs[t]

C3 — Confort soft : t_bal[t] + slack[t] >= T_min
C4 — T_max hard :   t_bal[t] <= T_max

C5 — Rampe inverter :
  p_pac2[t] - p_pac2[t-1] <= ramp_max    (t = 2..N)
  p_pac2[t-1] - p_pac2[t] <= ramp_max    (t = 2..N)

C6-C8 — Batterie (identique a optimizer_milp.R si active)
```

**COP dual** :
```
COP1[t] = calc_cop_gshp(T_sol[t], T_ballon=t_bal_prev[t])
COP2[t] = calc_cop_ashp(T_ext[t], T_ballon=t_bal_prev[t])
```
Raffinement iteratif : 2 passes, mise a jour des deux COP apres la 1ere passe.

**Proxy T_sol** :
```
T_sol = T_annuelle_moyenne + 0.3 * (T_mensuelle_moyenne - T_annuelle_moyenne)
```
Typiquement 8-12°C en Belgique, variation lente (profondeur 2-3m).

### Fichiers impactes

| Action | Fichier | Changement |
|--------|---------|------------|
| Creer | `R/optimizer_dual.R` | `solve_block_dual()` — MILP mixte binaire+continu+rampe |
| Creer | `R/R6_optimizer.R` +class | `DualOptimizer` — herite BaseOptimizer, COP iteratif dual |
| Modifier | `R/fct_helpers.R` | Ajouter `calc_cop_gshp()` |
| Modifier | `R/R6_thermal_model.R` | Ajouter `thermal_step_dual()` |
| Modifier | `R/R6_data_generator.R` | Ajouter `t_sol` (proxy saisonnier) |
| Modifier | `R/mod_sidebar.R` | Ajouter controles PAC 2 (toggle, puissance, type, mode) |
| Modifier | `R/mod_comparaison.R` | Ventilation PAC 1/PAC 2 dans les KPIs |
| Conserver | `R/optimizer_milp.R`, `_lp.R`, `_qp.R` | Inchanges |

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Le solveur dual produit un cout net inferieur ou egal au meilleur resultat mono-PAC sur au moins 90% des scenarios testes.
- **SC-002**: La temperature du ballon reste dans [T_min - slack, T_max] a chaque quart d'heure.
- **SC-003**: La variation de puissance de la PAC inverter ne depasse jamais ramp_max entre deux pas de temps consecutifs.
- **SC-004**: Le temps de calcul du solveur dual ne depasse pas 60 secondes pour 180 jours (marge x2 vs mono-PAC, car plus de variables).
- **SC-005**: Les solveurs existants (MILP, LP, QP) passent tous leurs tests existants sans modification (retrocompatibilite).
- **SC-006**: Le guard anti-regression detecte et corrige automatiquement les cas ou le dual serait plus cher que le mono.

## Assumptions

- Les deux PAC alimentent le meme ballon thermique (pas de ballons separes).
- ompr/HiGHS gere les MILP mixtes binaire+continu avec contraintes de rampe lineaires (confirme par le pattern PAC+batterie existant).
- La temperature du sol est suffisamment estimable par un proxy saisonnier pour un POC (pas besoin de capteur ou d'API dediee).
- Le lissage par contraintes de rampe lineaires (compatible MILP) est preferable au lissage quadratique (qui necessiterait MIQP/CVXR, plus lent).
- Le nombre de variables supplementaires (n binaires + n continues + 2n rampe) reste gerabke par HiGHS sur des blocs de 4-8h avec lookahead.

## References

- `discovery/009-dual-pac-optimizer.md` — Discovery validee
- `docs/knowledge/coupled-ashp-gshp-optimization.md` — Etat de l'art academique
- `docs/knowledge/optimizer-custom-novelty.md` — Positionnement de notre optimizer
- `R/optimizer_milp.R` — Solveur MILP existant (pattern de reference)
- `R/optimizer_qp.R` — Solveur QP existant (reference pour le lissage)
- `R/R6_optimizer.R` — BaseOptimizer + strategies existantes
- IEEE 2019 "MILP for Dual Source Heat Pump" : https://ieeexplore.ieee.org/document/8820495/
- D'Ettorre et al. 2019 "MPC of hybrid heat pump" : https://doi.org/10.1016/j.applthermaleng.2019.114422
