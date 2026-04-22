# Feature Specification: Refactoring Golem + R6 OOP Architecture

**Feature Branch**: `002-golem-r6-refactor`
**Created**: 2026-04-19
**Status**: Draft
**Input**: Refactoriser l'app Shiny en architecture Golem avec separation stricte des concerns, logique metier dans des modules R6 thematiques et modules Shiny Golem pour l'UI, pensee pour tourner avec R6 en mode object oriented programming.

## Clarifications

### Session 2026-04-19

- Q: Strategie de migration (big-bang vs incremental vs parallel) ? → A: Incremental — migrer un domaine metier a la fois (R6 d'abord, puis modules Golem), en gardant l'app fonctionnelle a chaque etape.
- Q: Pattern d'heritage des optimiseurs en R6 ? → A: Heritage R6 classique — classe BaseOptimizer avec methodes communes, sous-classes qui override `solve_block()`.
- Q: Gestion de l'etat reactif Shiny <-> R6 ? → A: Un `reactiveVal` central contient l'objet Simulation R6. Les modules observent ce reactiveVal et lisent l'etat via les getters R6.
- Q: Framework de test ? → A: testthat uniquement — tests unitaires des classes R6 metier.
- Q: Cohabitation avec l'ancien app.R pendant la migration ? → A: Garder `app.R` fonctionnel pendant toute la migration, le supprimer a la fin quand `golem::run_app()` est valide.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - L'app fonctionne a l'identique apres refactoring (Priority: P1)

Un utilisateur lance l'application refactorisee et obtient exactement les memes resultats qu'avant : memes KPI, memes graphiques, memes economies calculees, memes verifications de contraintes. Aucune regression fonctionnelle.

**Why this priority**: Sans parite fonctionnelle, le refactoring n'a aucune valeur. C'est le prerequis absolu.

**Independent Test**: Lancer l'app sur les donnees demo (PAC 60kW, juin-aout 2025, baseline ingenieur, LP 24h), verifier que la facture optimisee, le gain en EUR et l'autoconsommation sont identiques a la version actuelle (a l'arrondi pres).

**Acceptance Scenarios**:

1. **Given** l'app refactorisee est lancee, **When** l'utilisateur simule avec les parametres par defaut et LP, **Then** les KPI (facture, gain, autoconsommation) sont identiques a +-0.1% de la version actuelle.
2. **Given** l'app refactorisee est lancee, **When** l'utilisateur selectionne chaque onglet (Energie, Finances, Details, Contraintes, Dimensionnement), **Then** tous les graphiques s'affichent correctement sans erreur.
3. **Given** les 4 modes d'optimisation (Smart, MILP, LP, QP), **When** chacun est execute, **Then** les resultats sont identiques a la version actuelle.
4. **Given** les 5 modes de baseline (reactif, programmateur, surplus_pv, ingenieur, proactif), **When** chacun est selectionne, **Then** la facture baseline est identique a la version actuelle.

---

### User Story 2 - La logique metier est isolee et testable independamment (Priority: P1)

Un developpeur peut executer la logique metier (optimiseurs, baseline, generation de donnees, calcul de KPI) en dehors de Shiny, dans un script R pur ou des tests unitaires, sans demarrer l'application web.

**Why this priority**: C'est le coeur du refactoring — la separation des concerns. Sans elle, le refactoring est cosmetique.

**Independent Test**: Ecrire un script R de 10 lignes qui instancie les classes R6 metier, lance une simulation et verifie les resultats, sans aucune dependance Shiny.

**Acceptance Scenarios**:

1. **Given** un script R sans `library(shiny)`, **When** on instancie la classe d'optimisation et on lance un calcul LP, **Then** on obtient un resultat correct (facture, T_ballon, offtake).
2. **Given** la classe de donnees synthetiques, **When** on genere des donnees demo, **Then** le dataframe contient les colonnes attendues (timestamp, pv_kwh, t_ext, prix_eur_kwh, etc.) sans aucune interaction UI.
3. **Given** la classe KPI, **When** on lui passe un resultat de simulation, **Then** elle calcule correctement facture, gain, autoconsommation, et conformite temperature.

---

### User Story 3 - L'app suit la structure Golem standard (Priority: P2)

Un developpeur R ouvre le projet et reconnait immediatement la structure Golem : `R/` pour les modules et la logique, `inst/app/` pour les assets, `dev/` pour les scripts de developpement, `tests/` pour les tests. Il peut utiliser les commandes Golem standard (`golem::run_app()`, etc.).

**Why this priority**: La standardisation Golem facilite l'onboarding, la maintenance et le deploiement. C'est un investissement structurel.

**Independent Test**: Executer `golem::run_app()` depuis la racine du projet et verifier que l'app se lance correctement.

**Acceptance Scenarios**:

1. **Given** le projet refactorise, **When** on execute `golem::run_app()`, **Then** l'app se lance et fonctionne normalement.
2. **Given** la structure du projet, **When** un developpeur liste les fichiers dans `R/`, **Then** il voit des noms clairs : `mod_energie.R`, `mod_finances.R`, `R6_optimizer.R`, `R6_baseline.R`, etc.
3. **Given** le fichier DESCRIPTION, **When** on le lit, **Then** toutes les dependances sont declarees correctement.

---

### User Story 4 - Les modules UI sont decouples de la logique metier (Priority: P2)

Chaque onglet de l'application est un module Shiny Golem independant. La logique metier est dans des classes R6 que les modules consomment. Ajouter un nouvel onglet ne necessite pas de modifier la logique metier.

**Why this priority**: Le decouplage module/metier est ce qui permet la maintenabilite a long terme.

**Independent Test**: Ajouter un module Shiny "vide" comme nouvel onglet, verifier qu'il s'integre sans toucher aux fichiers de logique metier.

**Acceptance Scenarios**:

1. **Given** le module energie (`mod_energie.R`), **When** on regarde son code, **Then** il ne contient que de la logique UI/reactive (pas de calcul de facture, de modele thermique, etc.).
2. **Given** la classe R6 Optimizer, **When** on regarde son code, **Then** il ne contient aucune reference a Shiny.
3. **Given** un nouveau besoin d'onglet, **When** un developpeur cree `mod_nouveau.R`, **Then** il n'a qu'a importer les classes R6 et les utiliser, sans modifier les fichiers existants.

---

### User Story 5 - Les objets R6 encapsulent l'etat de la simulation (Priority: P2)

L'etat complet d'une simulation (parametres, donnees preparees, resultats baseline, resultats optimises, KPI) est encapsule dans un objet R6. Cela permet de comparer facilement plusieurs simulations et de serialiser/deserialiser l'etat.

**Why this priority**: L'encapsulation R6 elimine les variables globales et les effets de bord, rendant le code plus robuste et testable.

**Independent Test**: Creer deux instances de simulation avec des parametres differents, verifier qu'elles ne partagent aucun etat et produisent des resultats independants.

**Acceptance Scenarios**:

1. **Given** deux objets Simulation avec des parametres differents (PAC 2kW vs 60kW), **When** on lance les deux, **Then** les resultats sont independants et ne se contaminent pas.
2. **Given** un objet Simulation termine, **When** on accede a `sim$results$gain_eur`, **Then** on obtient le gain calcule sans passer par un `reactive()`.
3. **Given** un objet Simulation, **When** on appelle `sim$export_csv("output.csv")`, **Then** le fichier est ecrit avec toutes les colonnes attendues.

---

### Edge Cases

- Que se passe-t-il si un module est charge mais qu'aucune simulation n'a encore ete lancee ? Les classes R6 doivent retourner un etat "vide" coherent.
- Comment gerer les erreurs d'optimisation (solveur infaisable) dans l'architecture R6 ? Les classes doivent exposer un mecanisme d'erreur/fallback propre (guard_baseline).
- L'app monofichier actuelle (3130 lignes) contient du CSS inline et des constantes de couleur. Elles doivent etre centralisees dans `inst/app/www/`.
- Les donnees Belpex/Open-Meteo sont chargees une seule fois. Le cache doit etre gere au niveau de la classe R6 DataProvider.
- Le COP iteratif (2 passes) dans les optimiseurs doit etre preserve dans l'architecture R6.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: L'application DOIT etre structuree selon le framework Golem (DESCRIPTION, `R/`, `inst/`, `dev/`, `tests/`).
- **FR-002**: Toute la logique metier DOIT etre encapsulee dans des classes R6, sans dependance a Shiny.
- **FR-003**: Les classes R6 DOIVENT etre organisees par thematique :
  - Optimiseurs (MILP, LP, QP, Smart)
  - Baseline (reactif, programmateur, surplus_pv, ingenieur, proactif)
  - Donnees synthetiques (generation demo, Belpex, Open-Meteo)
  - KPI et metriques (facture, autoconsommation, conformite, etc.)
  - Modele thermique (COP, dynamique ballon, ECS)
  - Simulation (orchestration, parametres, resultats)
- **FR-004**: Chaque onglet de l'application DOIT etre un module Shiny Golem separe.
- **FR-005**: Les modules UI NE DOIVENT PAS contenir de logique metier (calculs, modeles, optimisation).
- **FR-006**: Les classes R6 NE DOIVENT PAS contenir de code Shiny (reactive, render, input, output).
- **FR-007**: Les constantes UI (couleurs, styles CSS) DOIVENT etre centralisees dans un fichier dedie.
- **FR-008**: Le fichier DESCRIPTION DOIT declarer toutes les dependances.
- **FR-009**: L'application DOIT pouvoir etre lancee via `golem::run_app()`.
- **FR-010**: Tous les resultats de simulation (KPI, graphiques, exports) DOIVENT etre identiques a la version actuelle.
- **FR-011**: Le mecanisme de guard_baseline DOIT etre preserve dans l'architecture R6.
- **FR-012**: L'export CSV DOIT continuer a fonctionner avec la meme structure de colonnes.
- **FR-013**: Les classes R6 DOIVENT etre utilisables dans un script R pur (sans Shiny) pour les tests et l'automatisation.
- **FR-014**: La migration DOIT etre incrementale : chaque domaine metier est migre un par un, l'app reste fonctionnelle a chaque etape.
- **FR-015**: Les optimiseurs DOIVENT utiliser l'heritage R6 : une classe BaseOptimizer avec methodes communes (solve, validate, extract_results), sous-classes SmartOptimizer, MILPOptimizer, LPOptimizer, QPOptimizer qui overrident `solve_block()`.
- **FR-016**: La communication Shiny <-> R6 DOIT passer par un `reactiveVal` central contenant l'objet Simulation R6. Les modules lisent l'etat via les getters R6, pas via des reactives internes.
- **FR-017**: Les tests DOIVENT utiliser testthat pour les classes R6 metier uniquement (pas de tests UI shinytest2 dans ce scope).
- **FR-018**: L'ancien `app.R` DOIT rester fonctionnel pendant toute la migration et etre supprime uniquement quand `golem::run_app()` est entierement valide.

### Key Entities

- **SimulationParams**: Encapsule tous les parametres d'une simulation (PAC, ballon, contrat, baseline, optimisation, curtailment, batterie).
- **ThermalModel**: Modele thermique du ballon (COP, pertes, dynamique, ECS). Partage entre baseline et optimiseurs.
- **Baseline**: Genere la simulation de reference selon le mode choisi (reactif, programmateur, surplus_pv, ingenieur, proactif).
- **BaseOptimizer**: Classe R6 de base avec methodes communes (solve, validate, extract_results, guard_baseline). Heritee par SmartOptimizer, MILPOptimizer, LPOptimizer, QPOptimizer qui overrident `solve_block()`.
- **DataGenerator**: Generation des donnees synthetiques (PV, ECS, T_ext, conso, prix).
- **BelpexProvider**: Chargement et interpolation des prix Belpex (CSV + API).
- **KPICalculator**: Calcul de tous les KPI (facture, gain, autoconsommation, conformite, etc.).
- **Simulation**: Orchestre le workflow complet (preparer donnees -> baseline -> optimiser -> KPI -> export).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: L'application produit des resultats identiques (+-0.1%) a la version actuelle pour les 4 modes d'optimisation et les 5 baselines.
- **SC-002**: Le fichier `app.R` monolithique (3130 lignes) est remplace par des fichiers de moins de 300 lignes chacun.
- **SC-003**: La logique metier (optimiseurs, baseline, KPI) peut etre executee dans un script R sans Shiny en moins de 5 lignes d'initialisation.
- **SC-004**: Le temps de demarrage de l'application reste inferieur a 10 secondes.
- **SC-005**: Aucune regression fonctionnelle : tous les onglets, graphiques, exports et interactions fonctionnent comme avant.
- **SC-006**: Un developpeur peut ajouter un nouveau module (onglet) en creant un seul fichier dans `R/` sans modifier les fichiers existants.
- **SC-007**: La couverture de tests unitaires des classes R6 metier atteint au moins 50% des fonctions publiques.

## Assumptions

- Le refactoring est une reecriture structurelle, pas fonctionnelle : aucune nouvelle feature n'est ajoutee.
- La migration est incrementale : l'ancien `app.R` coexiste avec le nouveau code Golem jusqu'a validation complete.
- Le pattern de communication Shiny/R6 est un reactiveVal central (pas de reactive() dans les classes R6).
- Le framework de test est testthat (pas shinytest2 pour les modules UI dans ce scope).
- Golem >= 0.4.0 et R6 >= 2.5.0 sont disponibles dans l'environnement R.
- Le systeme renv existant sera mis a jour pour inclure golem et R6 comme dependances.
- Les 3 fichiers d'optimiseurs existants (`R/optimizer_milp.R`, `R/optimizer_lp.R`, `R/optimizer_qp.R`) seront encapsules dans des classes R6 mais leur logique interne (modeles ompr/CVXR) reste inchangee.
- Les donnees historiques (CSV Belpex, Open-Meteo) restent dans `data/` et sont chargees par les classes R6.
- Les tests unitaires couvrent la logique metier R6 mais pas les modules Shiny UI (les tests UI requierent shinytest2, hors scope initial).
- Le CSS et les constantes de style seront dans `inst/app/www/` ou un fichier R dedie, pas en inline.
