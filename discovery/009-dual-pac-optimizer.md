# Discovery: Dual PAC Optimizer (ASHP+GSHP couple)

**Feature**: `009-dual-pac-optimizer`
**Created**: 2026-05-21

## Verbatim

> On a actuellement un optimizer MILP qui pilote une seule PAC (on/off binaire ou continu) alimentant un ballon thermique unique. L'installation de Profondeville a en realite deux PAC : une de 20 kW et une de 40 kW, potentiellement de types differents (ASHP air/eau + GSHP eau/eau, ou deux compresseurs avec des caracteristiques distinctes : l'un on/off fixe, l'autre inverter a vitesse variable).
>
> On veut etendre l'optimizer pour gerer un systeme couple a deux PAC alimentant le meme ballon :
> - PAC 1 (ex: GSHP on/off) : variable binaire, puissance fixe P_nom quand allumee
> - PAC 2 (ex: ASHP inverter) : variable continue dans [P_min, P_max]
> - Chaque PAC a sa propre courbe COP : COP_gshp(T_sol, T_ballon) vs COP_ashp(T_ext, T_ballon)
> - Le dispatch optimal entre les deux est decide par le solveur en fonction des prix, de la meteo (T_ext, T_sol), et de l'etat du ballon
>
> Le MILP unique resout le probleme couple car les deux PAC partagent la meme contrainte thermique du ballon. On ne veut PAS deux solveurs separes.
>
> Contraintes :
> - Retrocompatible : le mode "PAC unique" doit continuer a fonctionner (PAC 2 desactivee par defaut)
> - Le raffinement COP iteratif de R6_optimizer.R doit gerer deux courbes COP distinctes
> - Le guard anti-regression doit couvrir le cas couple
> - Les KPIs financiers doivent ventiler la contribution de chaque PAC
>
> On veut partir de l'existant et voir comment l'adapter pour faire qqch de plus robuste et inspire de la litterature. Avec double PAC et possibilite de lissage.
>
> Voir docs/knowledge/coupled-ashp-gshp-optimization.md pour l'etat de l'art academique et la formulation MILP envisagee.

## Structured Understanding

### Contexte

L'application wise-poc-pac optimise le pilotage d'une PAC unique alimentant un ballon thermique collectif. Trois solveurs existent : MILP (on/off binaire), LP (continu), QP (continu + lissage). L'installation reelle de Profondeville dispose de deux PAC (20 kW + 40 kW) potentiellement de types differents.

La litterature academique (IEEE 2019 "MILP for Dual Source HP", D'Ettorre 2019 "MPC hybrid HP") valide l'approche d'un MILP unique couplant deux sources. Notre code a deja le pattern (PAC binaire + batterie continue dans le meme MILP).

### Probleme

L'optimizer ne peut pas exploiter le dispatch optimal entre deux PAC de types differents. Il manque aussi la possibilite de combiner on/off (pour un compresseur fixe) et lissage (pour un inverter) dans un seul probleme d'optimisation. Aujourd'hui, on choisit un solveur OU l'autre — on ne peut pas mixer les deux approches pour deux machines distinctes.

### User Stories

#### US-1: Configurer une installation a deux PAC
En tant qu'utilisateur, je veux pouvoir definir les caracteristiques de deux PAC distinctes (type ASHP/GSHP, puissance, mode on/off ou inverter, courbe COP) dans le sidebar, afin que l'application modele fidelement mon installation reelle.

#### US-2: Optimiser le dispatch entre deux PAC avec lissage
En tant qu'utilisateur, je veux que l'optimiseur decide automatiquement, a chaque quart d'heure, quelle PAC utiliser (PAC 1, PAC 2, les deux, ou aucune), avec un comportement lisse pour la PAC inverter (pas de changements brusques de puissance), afin de tirer parti des differences de COP tout en preservant la longevite du materiel.

#### US-3: Voir la contribution de chaque PAC
En tant qu'utilisateur, je veux voir dans les KPIs et graphiques la ventilation de la consommation et du cout entre les deux PAC, afin de comprendre la strategie de dispatch choisie par l'optimiseur.

#### US-4: Continuer a utiliser le mode PAC unique
En tant qu'utilisateur ayant une seule PAC, je veux que l'application fonctionne exactement comme avant (PAC 2 desactivee par defaut), afin de ne pas etre impacte par cette nouvelle fonctionnalite.

### Scope

**In scope** :
- Nouveau solveur hybride combinant binaire (PAC on/off) + continu avec lissage (PAC inverter) dans un seul MILP
- Deux courbes COP distinctes : COP_ashp(T_ext, T_ballon) et COP_gshp(T_sol, T_ballon)
- Contraintes de rampe pour le lissage de la PAC inverter (approche lineaire compatible MILP)
- Raffinement COP iteratif adapte a deux courbes COP
- Guard anti-regression couvrant le cas couple
- Ventilation des KPIs financiers par PAC
- Retrocompatibilite totale : les 3 solveurs existants (MILP, LP, QP) restent inchanges
- Temperature du sol en proxy saisonnier (pas de nouveau data provider)

**Out of scope** :
- Modification des solveurs existants (MILP, LP, QP) — on cree un 4eme solveur
- Ajout d'autres sources de chaleur (solaire thermique, chaudiere gaz)
- Optimisation du dimensionnement (sizing) des PAC
- Modelisation de l'epuisement thermique du sol long terme

### Hypotheses a Valider
- ompr/HiGHS gere sans probleme un MILP mixte combinant variables binaires (PAC 1 on/off) et continues (PAC 2 inverter) avec contraintes de rampe — le pattern PAC+batterie existant le confirme mais a verifier sur la taille de probleme reelle.

### Open Questions
- Pour Profondeville specifiquement : laquelle des deux PAC (20 kW, 40 kW) est on/off et laquelle est inverter ? Ou sont-elles toutes deux du meme type ?
