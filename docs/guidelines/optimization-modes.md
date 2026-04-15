# Modes d'optimisation — Description et objectifs

Ce document decrit chacun des modes d'optimisation disponibles dans l'application
PAC Optimizer : ce qu'ils cherchent a optimiser, comment ils fonctionnent, et
quand les utiliser.

## Vue d'ensemble

| Mode | Minimise | Voit le futur ? | PAC | Solveur |
|---|---|---|---|---|
| Baseline | Rien | Non | ON/OFF bete | Aucun (thermostat) |
| Smart | Facture (estimation locale) | ~2h devant | ON/OFF intelligent | Aucun (heuristique) |
| MILP | Facture (optimum garanti) | Bloc entier (4-24h) | ON/OFF optimal | HiGHS (ompr) |
| LP | Facture (optimum garanti) | Bloc entier | 0-100% optimal | HiGHS (ompr) |
| QP | Facture + confort + lissage | Bloc entier | 0-100% lisse | CLARABEL (CVXR) |

## Baseline (thermostat classique)

**Fichier** : `app.R` — fonction `run_baseline()`

N'optimise rien. C'est un thermostat bete :
- Allume la PAC quand le ballon descend sous T_min
- Eteint la PAC quand le ballon atteint la consigne
- Ne regarde ni le PV, ni les prix de l'electricite

C'est le scenario "je ne fais rien d'intelligent". Il sert uniquement de
**reference** pour calculer les economies des autres modes.

**Quand l'utiliser** : jamais directement — la baseline est toujours calculee
en arriere-plan pour servir de reference.

## Smart (heuristique)

**Fichier** : `app.R` — fonctions `decider()` + `run_simulation()`

Cherche a **reduire la facture** en decidant a chaque quart d'heure s'il vaut
mieux chauffer maintenant ou attendre. Il compare :
- Le cout de chauffer tout de suite (cher si pas de soleil et prix eleve)
- Le cout estime de chauffer plus tard (peut-etre moins cher s'il y a du PV
  prevu ou si les prix baissent)

C'est un systeme de regles de priorite :
1. Confort d'abord — si T est proche de T_min, chauffer quoi qu'il arrive
2. Prix negatifs — toujours autoconsommer si l'injection rapporte moins que zero
3. Optimisation cout — comparer le cout thermique maintenant vs plus tard
4. Attente — si du surplus PV arrive bientot et que le ballon tient, attendre

**Avantages** : instantane, pas de solveur, fonctionne en temps reel.
**Limites** : decision locale (ne voit que ~2h devant), pas d'optimum garanti.
Le Smart peut ponctuellement laisser T descendre sous T_min pendant 1 qt avant
de reagir (decision basee sur T du qt precedent, pas T resultante).

**Quand l'utiliser** : pour une estimation rapide, ou en mode temps reel
quand on n'a pas le temps de resoudre un probleme d'optimisation.

## MILP (Mixed Integer Linear Programming)

**Fichier** : `R/optimizer_milp.R` — fonctions `solve_block()` + `run_optimization_milp()`

Cherche la **facture la plus basse possible** en decidant pour chaque quart
d'heure si la PAC est ON ou OFF. C'est du tout-ou-rien : la PAC tourne a
pleine puissance ou pas du tout.

Le solveur voit toutes les donnees du bloc (prix, PV, ECS sur 4 a 24h) et
trouve la combinaison ON/OFF qui coute le moins cher tout en gardant le ballon
entre T_min et T_max a chaque instant.

**Objectif mathematique** :
```
Minimiser  sum_t( offtake[t] * prix_offtake[t] - injection[t] * prix_injection[t] )
```

**Variable de decision** : `pac_on[t]` ∈ {0, 1} (binaire)

**Avantages** : solution optimale garantie pour le modele on/off.
**Limites** : probleme NP-hard (temps de calcul exponentiel en theorie),
necessite un decoupage en blocs. Chaque bloc est resolu independamment,
ce qui peut manquer des opportunites inter-blocs.

**Quand l'utiliser** : pour des PAC classiques (non-inverter) qui ne peuvent
que tourner a pleine puissance ou etre eteintes.

## LP (Linear Programming)

**Fichier** : `R/optimizer_lp.R` — fonctions `solve_block_lp()` + `run_optimization_lp()`

Meme objectif que le MILP — **facture la plus basse possible** — mais la PAC
peut tourner a n'importe quelle puissance entre 0% et 100%. Au lieu de "ON ou OFF",
le solveur choisit "42% de puissance" ou "78% de puissance".

**Objectif mathematique** :
```
Minimiser  sum_t( offtake[t] * prix_offtake[t] - injection[t] * prix_injection[t] )
```

**Variable de decision** : `pac_load[t]` ∈ [0, 1] (continue)

**Avantages** :
- Plus realiste pour les PAC avec variateur (inverter)
- Probleme convexe (LP) → resolution en temps polynomial, beaucoup plus rapide
- Optimum global garanti
- Pas de variables binaires → blocs plus grands possibles (24h)

**Limites** : suppose que la PAC peut moduler sa puissance en continu, ce qui
n'est pas le cas pour les PAC on/off pures. Sur des pas de 15 minutes,
c'est une approximation raisonnable meme pour les PAC on/off (duty cycling).

**Quand l'utiliser** : choix par defaut recommande. Ideal pour les PAC inverter.
Bonne approximation pour les PAC on/off sur des pas de 15 minutes.

## QP (Quadratic Programming, via CVXR)

**Fichier** : `R/optimizer_qp.R` — fonctions `solve_block_qp()` + `run_optimization_qp()`

Cherche un **compromis entre trois objectifs** :

1. **Reduire la facture** (comme le LP)
2. **Garder le ballon proche de la consigne** — penalise les ecarts de temperature.
   Plus le poids confort est eleve, plus le QP maintient la temperature stable
   autour de la consigne au lieu de laisser le ballon osciller entre T_min et T_max.
3. **Lisser la charge PAC** — penalise les changements brusques de puissance d'un
   quart d'heure a l'autre. Moins de cycling, fonctionnement plus doux.

**Objectif mathematique** :
```
Minimiser  sum_t( offtake[t] * prix_offtake[t] - injection[t] * prix_injection[t] )
         + w_comfort * sum_t( (T[t] - T_consigne)^2 )
         + w_smooth  * sum_t( (pac_load[t] - pac_load[t-1])^2 )
```

**Variables de decision** : `pac_load[t]` ∈ [0, 1] (continue)

**Parametres utilisateur** :
- `w_comfort` (defaut 0.1) : poids de la penalite de confort
- `w_smooth` (defaut 0.05) : poids de la penalite de lissage
- Avec les deux poids a 0, le QP se comporte exactement comme le LP

**Avantages** :
- Temperature plus stable (moins d'oscillations)
- Fonctionnement PAC plus doux (moins de cycling)
- Compromis reglable par l'utilisateur

**Limites** :
- Le QP accepte de **payer un peu plus cher** pour un meilleur confort et un
  fonctionnement plus lisse. L'economie QP est donc <= economie LP.
- Avec des poids eleves, l'economie QP peut devenir negative par rapport a la
  baseline (le QP **choisit** de payer plus pour le confort).
- Necessite le package CVXR + solveur CLARABEL (ou SCS en fallback).

**Quand l'utiliser** : quand le confort thermique et la stabilite de
fonctionnement comptent autant que le cout. Par exemple pour des planchers
chauffants ou des systemes sensibles aux variations.

## Comparaison des modes

### Economie garantie ?

| Mode | Economie >= 0 vs baseline ? | Raison |
|---|---|---|
| Smart | Quasi-oui | Heuristique, retard d'1 qt possible, mais en pratique toujours meilleur |
| MILP | **Oui (garanti)** | Minimise exactement la meme facture sous les memes contraintes |
| LP | **Oui (garanti)** | Idem, avec en plus la flexibilite de la charge continue |
| QP | **Non** | Les penalites confort/lissage peuvent augmenter la facture au-dela de la baseline |

### Vitesse de resolution

| Mode | Temps typique (6 mois, blocs 4h) |
|---|---|
| Baseline | < 1s |
| Smart | < 1s |
| MILP | ~50s |
| LP | ~5s |
| QP | ~10s |

### Qualite de la solution

| Mode | Optimalite |
|---|---|
| Baseline | Aucune (reference) |
| Smart | Bonne heuristique, pas d'optimum garanti |
| MILP | Optimum global pour le modele on/off |
| LP | Optimum global pour le modele continu |
| QP | Optimum global pour le compromis cout/confort/lissage |
