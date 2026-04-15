# Feature Specification: MILP Optimizer Mode

**Feature Branch**: `001-milp-optimizer`
**Created**: 2026-04-14
**Status**: Draft
**Input**: Ajouter un mode optimiseur MILP (ompr) en complement des algorithmes rule-based existants pour le pilotage PAC

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Choisir entre approche rule-based et optimiseur (Priority: P1)

En tant qu'utilisateur de l'application PAC Optimizer, je veux pouvoir choisir entre deux approches fondamentalement differentes de pilotage — des algorithmes a base de regles (deja existants) et un optimiseur mathematique — afin de comparer leurs performances sur mes donnees.

**Why this priority**: C'est la raison d'etre de cette feature. Sans la possibilite de choisir et de comprendre la difference entre les deux approches, la feature n'a pas de valeur.

**Independent Test**: L'utilisateur peut basculer entre "Rule-based" et "Optimiseur" dans le sidebar, lancer une simulation avec chacun, et voir des resultats differents dans les KPIs et graphiques.

**Acceptance Scenarios**:

1. **Given** l'application est lancee avec les parametres par defaut, **When** l'utilisateur selectionne "Optimiseur" dans le choix d'approche, **Then** le selecteur de mode rule-based (Smart, Injection, Cost, Hybrid, Auto) est masque et remplace par les options specifiques a l'optimiseur.
2. **Given** l'utilisateur a selectionne "Rule-based", **When** il selectionne un mode (ex: Smart) et lance la simulation, **Then** le comportement est identique a l'existant actuel.
3. **Given** l'utilisateur a selectionne "Optimiseur" et lance la simulation, **When** la simulation est terminee, **Then** les KPIs, graphiques et tableaux affichent les resultats de l'optimiseur dans le meme format que les modes rule-based, permettant une comparaison directe.

---

### User Story 2 - Lancer une optimisation MILP et voir les resultats (Priority: P1)

En tant qu'utilisateur, je veux que l'optimiseur calcule automatiquement le plan de pilotage PAC (et batterie si activee) qui minimise ma facture energetique sur toute la periode simulee, en respectant les contraintes thermiques et physiques de mon installation.

**Why this priority**: C'est le coeur fonctionnel de la feature — sans l'optimisation effective, le selecteur d'approche est inutile.

**Independent Test**: L'utilisateur lance une simulation en mode Optimiseur sur 30 jours de donnees demo, et obtient un gain financier positif ou nul par rapport au scenario reel (thermostat classique), avec la temperature du ballon toujours dans les limites configurees.

**Acceptance Scenarios**:

1. **Given** l'utilisateur a configure une installation (PV 6 kWc, PAC 2 kW, ballon 200L, consigne 50C +/-5C) en contrat fixe, **When** il lance l'optimiseur sur 90 jours, **Then** le cout optimise est inferieur ou egal au cout reel, et la temperature du ballon simulee reste dans [T min, T max] a tout moment.
2. **Given** l'utilisateur a active la batterie (10 kWh), **When** il lance l'optimiseur, **Then** l'optimiseur gere simultanement la PAC et la batterie, et le SOC reste dans les limites configurees.
3. **Given** le contrat est dynamique avec des prix negatifs certaines heures, **When** l'optimiseur tourne, **Then** il evite l'injection pendant les heures a prix negatif (en autoconsommant ou en chargeant la batterie).

---

### User Story 3 - Comprendre la difference entre les deux approches (Priority: P2)

En tant qu'utilisateur non-expert, je veux que l'interface m'explique clairement la difference entre l'approche rule-based et l'approche optimiseur, afin de comprendre pourquoi les resultats different et quand privilegier l'une ou l'autre.

**Why this priority**: La pedagogie est essentielle pour que l'utilisateur fasse confiance aux resultats et prenne des decisions eclairees. Cependant, l'outil fonctionne meme sans cette explication.

**Independent Test**: L'utilisateur peut cliquer sur le bouton Documentation et trouver une section expliquant les deux approches avec des exemples concrets.

**Acceptance Scenarios**:

1. **Given** l'utilisateur ouvre la documentation, **When** il consulte la section sur les approches d'optimisation, **Then** il trouve une explication en langage non-technique de la difference entre rule-based (decisions locales) et optimiseur (vision globale).
2. **Given** l'utilisateur a lance une simulation en mode Optimiseur, **When** il consulte l'onglet Analyse, **Then** il peut voir les decisions prises par l'optimiseur (PAC ON/OFF par quart d'heure) avec les memes visualisations que les modes rule-based.

---

### User Story 4 - Inclure l'optimiseur dans le grid search Automagic (Priority: P3)

En tant qu'utilisateur, je veux que le grid search "Automagic" inclue l'optimiseur comme strategie candidate en plus des modes rule-based, afin de voir si l'optimiseur surpasse les heuristiques pour une configuration donnee.

**Why this priority**: C'est un bonus qui enrichit une fonctionnalite existante. Le grid search fonctionne deja sans l'optimiseur.

**Independent Test**: L'utilisateur lance Automagic et voit apparaitre des lignes "optimizer" dans le tableau des resultats, comparables aux lignes rule-based.

**Acceptance Scenarios**:

1. **Given** l'utilisateur clique sur "Trouver la meilleure config", **When** le grid search se termine, **Then** le tableau inclut des resultats pour le mode "optimizer" a cote des modes rule-based, et la meilleure configuration globale peut etre un optimiseur.

---

### Edge Cases

- Que se passe-t-il si le solveur ne trouve pas de solution (infeasible) ? L'application doit afficher un message clair et ne pas crasher.
- Que se passe-t-il si la simulation est tres longue (365 jours) ? L'optimiseur doit rester performant ou l'utilisateur doit etre informe du temps de calcul.
- Que se passe-t-il si les prix sont tous identiques (contrat fixe strict) ? L'optimiseur doit quand meme trouver une solution (optimiser le volume, pas le timing).
- Que se passe-t-il si la batterie n'est pas activee ? L'optimiseur doit fonctionner avec la PAC seule.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Le systeme DOIT proposer deux approches d'optimisation clairement separees dans l'interface : "Rule-based" (algorithmes existants) et "Optimiseur" (MILP).
- **FR-002**: En mode Optimiseur, le systeme DOIT formuler et resoudre un probleme d'optimisation lineaire mixte (MILP) qui minimise le cout net de l'electricite sur la periode simulee.
- **FR-003**: L'optimiseur DOIT respecter les contraintes thermiques du ballon : la temperature simulee doit rester dans [T min, T max] a chaque quart d'heure.
- **FR-004**: L'optimiseur DOIT respecter les contraintes physiques de la PAC : puissance fixe (ON/OFF), COP variable selon la temperature exterieure.
- **FR-005**: L'optimiseur DOIT gerer la batterie (si activee) avec les contraintes de SOC min/max, puissance max charge/decharge, rendement, et anti-simultaneite charge/decharge.
- **FR-006**: L'optimiseur DOIT produire des resultats dans le meme format que les modes rule-based (sim_offtake, sim_intake, sim_t_ballon, sim_pac_on, sim_cop, batt_soc) pour permettre une comparaison directe dans les graphiques et KPIs existants.
- **FR-007**: Le systeme DOIT afficher un indicateur de progression pendant la resolution de l'optimisation.
- **FR-008**: Le systeme DOIT gerer le cas ou le solveur ne trouve pas de solution en affichant un message explicatif sans crasher.
- **FR-009**: La documentation (modal) DOIT inclure une section expliquant la difference entre les deux approches.
- **FR-010**: L'optimiseur DOIT etre inclus comme candidat dans le mode Auto-adaptatif et dans le grid search Automagic.

### Key Entities

- **Plan d'optimisation** : ensemble des decisions PAC ON/OFF et flux batterie pour chaque quart d'heure, calcule par le solveur MILP. Comprend les variables de decision (pac_on, charge, decharge) et les variables derivees (temperature ballon, SOC, offtake, intake).
- **Fonction objectif** : cout net = somme des (soutirage x prix_offtake) - somme des (injection x prix_injection) sur tout l'horizon.
- **Contraintes** : ensemble des limites physiques et de confort (temperature, SOC, puissance, bilan energetique nodal) que le solveur doit respecter.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: L'optimiseur produit un cout net inferieur ou egal a celui du meilleur mode rule-based sur au moins 90% des scenarios testes (combinaisons de periodes, contrats, et configurations d'installation).
- **SC-002**: La temperature du ballon simulee par l'optimiseur ne depasse jamais les limites [T min, T max] configurees par l'utilisateur.
- **SC-003**: Le temps de calcul de l'optimiseur ne depasse pas 30 secondes pour une simulation de 180 jours (17 280 quarts d'heure).
- **SC-004**: L'utilisateur comprend la difference entre les deux approches sans aide exterieure, valide par la presence d'une section pedagogique dans la documentation et par la separation visuelle dans l'interface.
- **SC-005**: Le SOC de la batterie (si activee) reste dans les limites configurees a chaque quart d'heure de la simulation.

## Assumptions

- L'optimiseur fonctionne en backtest (donnees historiques connues), comme les modes rule-based existants. Le cas temps reel est hors scope.
- Le solveur GLPK (open-source) est suffisamment performant pour les tailles de problemes envisagees (jusqu'a 365 jours x 96 qt/jour = 35 040 pas de temps).
- La PAC fonctionne en mode ON/OFF (pas de modulation de puissance). C'est une variable binaire dans le MILP.
- Le modele thermique du ballon utilise dans l'optimiseur est le meme modele lineaire simplifie que dans les modes rule-based (coherence des comparaisons).
- Les packages R ompr, ompr.roi, et ROI.plugin.glpk sont disponibles et installables via renv.
- L'optimiseur ne gere pas le curtailment solaire (hors scope de cette feature).
