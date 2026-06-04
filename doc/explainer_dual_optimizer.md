# L'optimiseur dual PAC — Comment ça marche

## Le problème

Tu as une chaufferie avec :
- **2 pompes à chaleur** (GSHP géothermique + ASHP aérothermique) qui consomment de l'électricité pour produire de la chaleur
- **1 ballon d'eau chaude** (2500 L) qui stocke la chaleur
- **Des panneaux solaires** qui produisent de l'électricité gratuitement en journée
- **Le réseau électrique** où le prix change toutes les heures (parfois cher, parfois gratuit, parfois négatif)

Aujourd'hui, un **thermostat** allume les PAC quand le ballon refroidit, sans se soucier du prix. L'optimiseur fait mieux : il décide **quand** allumer chaque PAC pour payer le moins possible, tout en gardant le ballon suffisamment chaud.

## Comment il raisonne

L'optimiseur regarde une journée de prix à l'avance (publiés à 12h42 par la bourse EPEX SPOT) et se dit :

> "Je connais le prix de chaque quart d'heure pour les prochaines 24h. Je connais la météo (= rendement des PAC). Je connais la demande de chaleur des occupants. Comment je répartis le fonctionnement des PAC pour minimiser ma facture ?"

## Les variables de décision

À chaque quart d'heure, l'optimiseur choisit :
- **PAC 1 (géothermique)** : ON ou OFF ? (variable binaire : 0 ou 1)
- **PAC 2 (aérothermique)** : ON ou OFF ? (variable binaire : 0 ou 1)

C'est tout. À partir de ces décisions, tout le reste se calcule : la température du ballon, le soutirage réseau, l'injection PV, la facture.

## L'objectif

**Minimiser le coût net** sur la journée :

```
coût = Σ (électricité achetée au réseau × prix) - Σ (électricité vendue au réseau × prix)
```

En gros : acheter quand c'est pas cher, vendre quand c'est cher.

## Les règles du jeu (contraintes)

L'optimiseur n'a pas le droit de tout faire. Il doit respecter :

### 1. Le bilan électrique

À chaque quart d'heure, l'électricité se conserve :

```
PV + achat réseau = PAC1 + PAC2 + reste du bâtiment + vente réseau
```

Tout kWh qui entre doit sortir quelque part.

### 2. La physique du ballon

La température évolue selon une loi simple :

```
T_ballon(maintenant) = T_ballon(avant)
                     + chaleur produite par PAC1
                     + chaleur produite par PAC2
                     - chaleur perdue vers l'extérieur
                     - chaleur consommée par les occupants (douches, chauffage)
```

La chaleur produite par chaque PAC = électricité consommée × COP (rendement). Le COP de la géothermique dépend de la température du sol, celui de l'aérothermique dépend de la température de l'air.

### 3. Le confort

La température du ballon doit rester dans une plage :

```
T_min ≤ T_ballon ≤ T_max
```

Si le ballon descend trop → eau tiède → occupants mécontents. Si trop chaud → gaspillage + risque.

La borne basse (T_min) est **souple** : l'optimiseur peut la violer un peu, mais ça lui coûte une pénalité fictive. Ça évite que le problème soit "impossible à résoudre" quand la demande est très forte.

### 4. Pas de cycles courts

Quand une PAC s'allume, elle doit rester allumée au moins 45 minutes (3 quarts d'heure). Pareil pour l'arrêt. C'est pour protéger le compresseur.

## Comment il résout

Le problème est formulé comme un **MILP** (Mixed Integer Linear Programming) :
- "Mixed Integer" parce que les décisions ON/OFF sont des **entiers** (0 ou 1)
- "Linear" parce que toutes les équations sont des lignes droites (pas de x²)
- "Programming" = optimisation (pas de code informatique au sens habituel)

Le solveur **HiGHS** (un logiciel open source) explore intelligemment les combinaisons possibles. Pour une journée de 96 quarts d'heure avec 2 PAC, il y a théoriquement 2^192 combinaisons possibles. Le solveur utilise des techniques mathématiques (branch-and-bound, cutting planes) pour trouver la meilleure solution sans toutes les essayer.

## Le découpage en blocs

On ne résout pas toute la période d'un coup. On découpe en **blocs de 24h** alignés sur minuit (= un jeu de prix day-ahead). Pour chaque bloc :

1. **Résoudre** le bloc + 24h de lookahead (pour anticiper)
2. **Garder** seulement les décisions du bloc courant
3. **Chaîner** : la température finale du ballon devient la condition initiale du bloc suivant
4. **Passer** au bloc suivant

C'est le principe du **MPC** (Model Predictive Control) : on planifie loin, on exécute court, on recommence.

```
Données:  |----bloc 1----|----bloc 2----|----bloc 3----|

Solve 1:  |====EXECUTE===|····regarde···|
                ↑ on garde       ↑ on jette

Solve 2:              |====EXECUTE===|····regarde···|
                            ↑ on garde       ↑ on jette

Solve 3:                          |====EXECUTE===|  ← valeur terminale ici
                                        ↑ on garde
```

### Pourquoi jeter le lookahead ?

Les décisions lointaines sont basées sur des données qu'on connaît mieux au moment d'y arriver (chaînage des conditions initiales, COP recalculé). C'est le principe du **receding horizon** : la valeur terminale et le lookahead sont deux mécanismes complémentaires contre la myopie.

### La valeur terminale

Sans elle, le solveur triche : il **vide le ballon** à la fin du dernier bloc pour économiser de l'électricité. La valeur terminale attribue un prix fictif à chaque degré restant dans le ballon (= le coût qu'il faudrait payer pour regagner 1°C). Le solveur est donc incité à laisser le ballon chaud en fin de bloc.

## Le COP itératif

Un détail subtil : le rendement (COP) de chaque PAC dépend de la température du ballon. Mais la température du ballon est elle-même un résultat de l'optimisation. Cercle vicieux !

Solution : on résout **deux fois** :
1. Première passe : COP calculé avec une température de ballon estimée
2. On regarde la trajectoire de température obtenue → on recalcule les COP
3. Deuxième passe : on résout avec les COP corrigés → solution finale

En pratique, ça converge en 2 itérations car la relation COP/T_ballon est monotone et lisse.

## Le chaînage entre blocs

La fin d'un bloc devient le début du suivant. Trois états sont chaînés :

1. **Température ballon** : le solveur du bloc N+1 démarre avec la température finale du bloc N
2. **État de charge batterie** (si active) : le niveau de charge est conservé entre blocs
3. **Rampe inverter** (si PAC en mode inverter) : la contrainte de rampe s'applique aussi à la frontière entre blocs

```
Bloc 1                          Bloc 2
... ──── T=32°C  ─── chaîne ──→  T_init=32°C ──── ...
... ──── SOC=60% ─── chaîne ──→  SOC_init=60% ── ...
```

## Ce que ça produit

Pour chaque quart d'heure, l'optimiseur donne :

| Colonne | Description |
|---|---|
| `sim_pac1_kwh` | Électricité consommée par la GSHP |
| `sim_pac2_kwh` | Électricité consommée par l'ASHP |
| `sim_t_ballon` | Température du ballon |
| `sim_offtake` | Électricité achetée au réseau |
| `sim_intake` | Électricité vendue au réseau |
| `sim_cop1` / `sim_cop2` | COP effectif de chaque PAC |

On compare à la baseline (thermostat) pour calculer l'économie.

## Paramètres clés

| Paramètre | Effet | Valeur typique |
|---|---|---|
| **T_min / T_max** | Plage de température du ballon | 25–38 °C |
| **Durée min cycle** | Protection compresseur (on/off) | 45 min |
| **Horizon bloc** | Durée d'optimisation (6/12/24h) | 24h (= day-ahead) |
| **Slack penalty** | Coût fictif par °C sous T_min | 2.5 EUR/°C |
| **COP nominal** | Rendement de référence à T_ref | GSHP: 4.0, ASHP: 3.0 |

## Fichiers source

- `R/optimizer_dual.R` : formulation MILP + boucle de blocs
- `R/R6_optimizer.R` : classe R6 `DualOptimizer` (interface)
- `R/fct_helpers.R` : `calc_cop()`, `calc_cop_gshp()`, `compute_block_starts()`
- `R/fct_simulation.R` : `run_simulation()` (orchestration)
