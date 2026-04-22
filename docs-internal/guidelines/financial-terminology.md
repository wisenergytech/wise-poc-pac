# Convention terminologique — Finances et indicateurs

Ce document definit la terminologie financiere, le protocole de comparaison
et l'alignement des contraintes entre les differents modes de l'application PAC Optimizer.
Toute contribution doit respecter ces conventions.

## Baseline et protocole de comparaison

### Principe

L'economie est TOUJOURS calculee en comparant deux simulations qui utilisent
le **meme modele thermique** (memes equations, memes parametres) :

1. **Baseline** (`run_baseline`) : thermostat classique (ON quand T < T_min, OFF quand T > T_consigne)
2. **Optimiseur** : strategie choisie (Smart, MILP, LP, QP)

La baseline ne regarde ni le PV, ni les prix — elle represente le "pire cas raisonnable"
d'un thermostat non-optimise.

### Pourquoi cette approche

- **Meme modele thermique** → les seules differences viennent de la strategie de decision
- **Economie toujours >= 0** (pour MILP/LP) → l'optimiseur minimise le cout sous les memes contraintes,
  il ne peut pas faire pire qu'une strategie faisable quelconque
- **Pas de biais** → on ne compare pas a des donnees historiques qui utilisent
  potentiellement un modele different ou des parametres differents

### Colonnes dans le dataframe

| Colonne | Source | Description |
|---|---|---|
| `t_ballon` | `run_baseline()` | Temperature ballon — baseline thermostat |
| `offtake_kwh` | `run_baseline()` | Soutirage reseau — baseline thermostat |
| `intake_kwh` | `run_baseline()` | Injection reseau — baseline thermostat |
| `sim_t_ballon` | Optimiseur | Temperature ballon — optimiseur |
| `sim_offtake` | Optimiseur | Soutirage reseau — optimiseur |
| `sim_intake` | Optimiseur | Injection reseau — optimiseur |

### Flux de donnees

```
generer_demo() / CSV import
    → donnees d'entree (PV, conso, T_ext, ECS, prix)
        → prepare_df()
            → ajoute prix_offtake, prix_injection, conso_hors_pac, soutirage_estime_kwh
                → run_baseline()
                    → ajoute t_ballon, offtake_kwh, intake_kwh
                        → run_optimization_*() ou run_simulation()
                            → ajoute sim_t_ballon, sim_offtake, sim_intake, ...
```

---

## Modele thermique partage

Tous les modes (baseline, Smart, MILP, LP, QP) utilisent la **meme equation** :

```
T(t) = [T(t-1) * (cap - k_perte) + chaleur(t) + k_perte * T_amb - ECS(t)] / cap
```

### Constantes et parametres

| Symbole | Valeur | Source |
|---|---|---|
| `cap` | `volume_ballon * 0.001163` | `params$capacite_kwh_par_degre` |
| `k_perte` | `0.004 * dt_h` | Identique dans les 5 modes |
| `T_amb` | `20` | Identique dans les 5 modes |
| `chaleur(t)` | `pac_on(t) * P_pac_qt * COP(T_ext(t))` | Identique dans les 5 modes |
| `COP(T_ext)` | `calc_cop(t_ext, cop_nominal, t_ref_cop)` | Identique dans les 5 modes |
| `pac_qt` | `p_pac_kw * dt_h` (kWh electrique) | Identique dans les 5 modes |
| `ECS(t)` | `soutirage_estime_kwh` (kWh thermique) | Identique dans les 5 modes |
| `T initiale` | `params$t_consigne` | Identique dans les 5 modes |

---

## Contraintes partagees — audit detaille

### Temperature : T >= T_min

| Mode | Implementation | Moment du check |
|---|---|---|
| **Baseline** | Proactif : si T_sans_pac < T_min → force PAC ON | Avant le calcul de T(t) |
| **MILP** | Contrainte dure : `t_bal[t] >= t_min_qt[t]` | Dans le solveur |
| **LP** | Contrainte dure : `t_bal[t] >= t_min_qt[t]` | Dans le solveur |
| **QP** | Contrainte dure : `t_bal[t] >= t_min_t` | Dans le solveur |
| **Smart** | Reactif : `if (t_actuelle < t_min_eff) → ON` | Check sur T(t-1), pas T(t) |

> **Note Smart** : le Smart verifie T au qt precedent, pas T resultante. Il peut donc
> ponctuellement avoir T(t) < T_min pendant 1 qt avant de reagir. C'est inherent a
> l'approche heuristique (decision locale sans solveur).

### Temperature : T <= T_max

| Mode | Implementation |
|---|---|
| **Baseline** | Force PAC OFF si T_avec_pac > T_max |
| **MILP** | Contrainte dure : `t_bal[t] <= params$t_max` |
| **LP** | Contrainte dure : `t_bal[t] <= params$t_max` |
| **QP** | Contrainte dure : `t_bal[t] <= params$t_max` |
| **Smart** | Via clamp post-calcul : `min(params$t_max + 5, ...)` |

### Relaxation ECS (tirages > 1 kWh)

| Mode | T_min effectif |
|---|---|
| **Baseline** | `if (ecs > 1.0) T_min - 10 else T_min` |
| **MILP** | `ifelse(ecs > 1.0, t_min - 10, t_min)` |
| **LP** | `ifelse(ecs > 1.0, t_min - 10, t_min)` |
| **QP** | `if (ecs > 1.0) t_min - 10 else t_min` |
| **Smart** | `if (ecs_now > 1.0) t_min - 10 else t_min` (dans decider + prediction future) |

### Bornes physiques des variables de temperature

| Mode | Borne basse | Borne haute |
|---|---|---|
| **Baseline** | `max(20, T_min - 10)` (clamp) | `T_max + 5` (clamp) |
| **MILP** | `max(20, T_min - 10)` (lb variable) | `T_max + 5` (ub variable) |
| **LP** | `max(20, T_min - 10)` (lb variable) | `T_max + 5` (ub variable) |
| **QP** | `max(20, T_min - 10)` (constraint) | `T_max + 5` (constraint) |
| **Smart** | `max(20, T_min - 10)` (clamp) | `T_max + 5` (clamp) |

### Bilan energetique

| Mode | Formule |
|---|---|
| **Baseline** | `surplus = pv - (conso + pac_on * pac_qt)` → offtake/injection |
| **MILP** | `pv + offt == conso + pac_on * pac_qt + inj` (+ batterie si active) |
| **LP** | `pv + offt == conso + pac_load * pac_qt + inj` (+ batterie si active) |
| **QP** | `pv + offt == conso + pac_load * pac_qt + inj` (+ batterie si active) |
| **Smart** | `surplus = pv - (conso + pac_on * pac_qt)` → batterie → offtake/injection |

### Batterie

| Mode | Support batterie |
|---|---|
| **Baseline** | **Non** |
| **MILP** | Oui (variables chrg/dischrg/soc + anti-simultaneite binaire) |
| **LP** | Oui (variables chrg/dischrg/soc, sans anti-simultaneite) |
| **QP** | Oui (variables chrg/dischrg/soc, sans anti-simultaneite) |
| **Smart** | Oui (heuristique charge/decharge sequentielle) |

> **Impact** : quand la batterie est active, l'economie affichee inclut le gain de la
> strategie de pilotage PAC **et** le gain de la batterie. La baseline n'a pas de batterie.
> C'est voulu — on compare "thermostat bete sans batterie" vs "optimiseur avec batterie".

---

## Differences intentionnelles entre les modes

### Smart : decision reactive (retard d'un qt)

Le Smart decide au qt `i` en fonction de `T(i-1)` (temperature du qt precedent).
Il ne peut pas verifier proactivement la T resultante car il ne connait pas encore
sa decision. Consequence : T peut ponctuellement descendre sous T_min pendant 1 qt
avant que le Smart reagisse au qt suivant.

La baseline et les optimiseurs n'ont pas ce probleme :
- La baseline verifie proactivement si T tomberait sous T_min AVANT de decider
- Les optimiseurs imposent T >= T_min comme contrainte dure sur T resultante

### Smart : qt=1 simplifie

Au premier quart d'heure, le Smart force PAC OFF et calcule le bilan electrique
sans passer par le decider. La baseline, elle, applique toute sa logique
(check proactif + dynamique thermique) des le qt=1. L'impact est negligeable
(1 qt sur ~17000 pour une simulation de 6 mois).

### QP : objectif multi-criteres

Le QP minimise `cout + w_comfort * confort + w_smooth * lissage`.
Les penalites confort et lissage augmentent la valeur de l'objectif, ce qui veut dire
que le QP peut accepter une facture **plus elevee** en echange d'un meilleur confort
(temperature plus stable autour de la consigne) et d'un lissage de la charge PAC.

Consequences :
- Economie QP <= Economie LP (a contraintes egales)
- Avec des poids eleves, l'economie QP peut etre negative (le QP **choisit** de payer plus pour le confort)
- Avec des poids a 0, le QP se comporte comme un LP

Ce n'est pas un bug — c'est le compromis cout/confort explicite du QP.

---

## Formule financiere

```
Facture nette = (Soutirage x Prix_soutirage) - (Injection x Prix_injection)
```

- **Positif** = l'utilisateur paie (il soutire plus qu'il n'injecte en valeur)
- **Negatif** = le reseau paie l'utilisateur (producteur net en valeur)

## Termes principaux

| Terme | Definition | Signe | Contexte |
|---|---|---|---|
| **Facture nette** | Cout du soutirage moins revenu de l'injection | + = on paie, - = on gagne | Partout ou on parle de cout |
| **Facture baseline** | Facture nette du thermostat classique | idem | Comparaison baseline vs optimise |
| **Facture optimisee** | Facture nette avec les decisions de l'optimiseur | idem | Comparaison baseline vs optimise |
| **Economie** | Facture baseline - Facture optimisee | + = on economise | KPI, tableau mensuel, waterfall |

### Garantie d'economie positive

| Mode | Economie >= 0 ? | Raison |
|---|---|---|
| **MILP** | Oui (garanti) | Minimise exactement le meme cout sous les memes contraintes que la baseline |
| **LP** | Oui (garanti) | Idem, avec charge continue au lieu de binaire |
| **QP** | Non (peut etre < 0) | L'objectif inclut des penalites confort/lissage — le QP peut payer plus pour plus de confort |
| **Smart** | Quasi-oui | Heuristique, retard d'1 qt possible, mais en pratique toujours meilleur que la baseline |

## Waterfall — Decomposition de l'economie

L'economie totale se decompose en trois contributions :

| Composante | Calcul | Signification |
|---|---|---|
| **Moins de soutirage** | (Soutirage_baseline - Soutirage_opti) x Prix_moyen_soutirage | L'optimiseur achete moins au reseau. Contribution positive. |
| **Moins d'injection** | -(Injection_baseline - Injection_opti) x Prix_moyen_injection | L'optimiseur injecte moins (autoconsomme plus). Revenu perdu, contribution negative. |
| **Arbitrage horaire** | Economie_totale - Moins_de_soutirage - Moins_d_injection | Decalage de la conso vers des heures moins cheres. Pertinent en contrat dynamique. |
| **Economie totale** | Facture baseline - Facture optimisee | Somme des trois composantes. |

## Termes a NE PAS utiliser

| Terme interdit | Remplacer par | Raison |
|---|---|---|
| "Cout cumule" | **Facture nette cumulee** | "Cout" est ambigu quand la valeur est negative |
| "Cout reel" / "Cout optimise" | **Facture baseline** / **Facture optimisee** | Coherence |
| "Reel" (pour la reference) | **Baseline** | Ce n'est pas du "reel", c'est une simulation de thermostat classique |
| "Gain" (seul) | **Economie** | "Gain" est ambigu (gain de quoi ?) |
| "Gain net" | **Economie totale** | Coherence |
| "Injection perdue" | **Moins d'injection** | "Perdue" sous-entend un probleme, alors que c'est voulu |
| "Injection evitee" | **Moins d'injection** | Meme raison |
| "Soutirage evite" | **Moins de soutirage** | Coherence |
| "Timing prix" | **Arbitrage horaire** | Plus explicite |

## Convention de couleurs

| Element | Couleur | Usage |
|---|---|---|
| Valeur positive (economie, barre verte) | `cl$success` | L'utilisateur economise |
| Valeur negative (surcout, barre rouge) | `cl$danger` | L'optimiseur fait pire |
| Facture baseline | `cl$reel` (orange) | Courbe/barre du thermostat classique |
| Facture optimisee | `cl$opti` (cyan) | Courbe/barre du scenario optimise |

## Exemples concrets

### Cas typique (contrat dynamique, 6 mois)
- Facture baseline : **+180 EUR** (thermostat classique paie 180 EUR)
- Facture optimisee : **+120 EUR** (optimiseur paie 120 EUR)
- Economie : **+60 EUR** (on economise 60 EUR)

### Cas producteur net (gros PV, ete)
- Facture baseline : **-20 EUR** (thermostat classique recoit 20 EUR)
- Facture optimisee : **-35 EUR** (optimiseur recoit 35 EUR)
- Economie : **+15 EUR** (on economise 15 EUR de plus)
