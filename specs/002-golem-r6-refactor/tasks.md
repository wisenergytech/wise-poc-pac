# Tasks: Golem + R6 OOP Architecture

**Input**: Design documents from `/specs/002-golem-r6-refactor/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Inclus (testthat pour classes R6 metier, demande dans spec FR-017 et SC-007).

**Organization**: Tasks groupees par user story. Migration incrementale — l'app reste fonctionnelle a chaque etape.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Structure Golem)

**Purpose**: Creer la structure Golem a cote de l'app.R existant sans casser l'app actuelle.

- [X] T001 Initialiser le package Golem : creer DESCRIPTION, NAMESPACE, inst/app/www/, dev/ via golem::create_golem() ou manuellement
- [X] T002 Ajouter golem, R6, testthat comme dependances dans DESCRIPTION et renv.lock via renv::install() + renv::snapshot()
- [X] T003 [P] Creer R/app_config.R avec golem::get_golem_options() et configuration de base
- [X] T004 [P] Creer R/run_app.R avec la fonction run_app() standard Golem
- [X] T005 [P] Extraire les constantes de couleur et le theme bslib de app.R vers R/fct_ui_theme.R
- [X] T006 [P] Deplacer le CSS inline de app.R vers inst/app/www/custom.css
- [X] T007 Creer R/fct_helpers.R avec les fonctions utilitaires partagees (calc_cop, pl_layout, tip, kpi_card, explainer)

**Checkpoint**: Structure Golem cree. L'ancien app.R fonctionne toujours sans modification.

---

## Phase 2: Foundational (Classes R6 Metier)

**Purpose**: Extraire toute la logique metier de app.R dans des classes R6. L'app.R existant continue de fonctionner.

**CRITICAL**: Ces classes sont le fondement de toute la migration. Elles doivent etre testables sans Shiny.

- [X] T008 Creer R/R6_params.R : classe SimulationParams encapsulant tous les parametres (PAC, ballon, contrat, baseline, optimisation, curtailment, batterie) dans R/R6_params.R
- [X] T009 Creer R/R6_thermal_model.R : classe ThermalModel avec calc_cop(t_ext, t_ballon), thermal_step(), energy_balance() dans R/R6_thermal_model.R
- [X] T010 [P] Creer R/R6_data_provider.R : classe DataProvider encapsulant le chargement Belpex (R/belpex.R), Open-Meteo (R/openmeteo.R) et CO2 (R/co2_elia.R) dans R/R6_data_provider.R
- [X] T011 [P] Creer R/R6_data_generator.R : classe DataGenerator encapsulant generer_demo() et prepare_df() dans R/R6_data_generator.R
- [X] T012 Creer R/R6_baseline.R : classe Baseline avec les 5 modes (reactif, programmateur, surplus_pv, ingenieur, proactif) dans R/R6_baseline.R
- [X] T013 Creer R/R6_optimizer.R : classe BaseOptimizer avec solve(), get_results(), guard_baseline() et sous-classes SmartOptimizer, MILPOptimizer, LPOptimizer, QPOptimizer dans R/R6_optimizer.R
- [X] T014 Creer R/R6_kpi.R : classe KPICalculator avec compute(), get_facture(), get_autoconsommation(), get_conformite() dans R/R6_kpi.R
- [X] T015 Creer R/R6_simulation.R : classe Simulation orchestrant le workflow (load_data -> run_baseline -> run_optimization -> get_kpi -> export_csv) dans R/R6_simulation.R

**Checkpoint**: Toutes les classes R6 creees. Executables dans un script R sans Shiny (verifier avec quickstart.md).

---

## Phase 3: User Story 1 — Parite fonctionnelle (Priority: P1)

**Goal**: L'app produit des resultats identiques (+-0.1%) a la version actuelle avec les classes R6.

**Independent Test**: Lancer l'app, simuler PAC 60kW / LP / baseline ingenieur, verifier que les KPI sont identiques.

### Tests for User Story 1

- [X] T016 [P] [US1] Test unitaire R6_thermal_model : calc_cop avec et sans t_ballon, thermal_step dans tests/testthat/test-R6_thermal_model.R
- [X] T017 [P] [US1] Test unitaire R6_baseline : 5 modes, verifier facture identique a l'ancien run_baseline() dans tests/testthat/test-R6_baseline.R
- [X] T018 [P] [US1] Test unitaire R6_optimizer : LP sur un dataset de 1 jour, verifier resultat de reference dans tests/testthat/test-R6_optimizer.R
- [X] T019 [P] [US1] Test unitaire R6_kpi : facture, autoconsommation, conformite sur des donnees connues dans tests/testthat/test-R6_kpi.R
- [X] T020 [US1] Test unitaire R6_simulation : workflow complet (demo -> baseline -> LP -> KPI), verifier parite dans tests/testthat/test-R6_simulation.R

### Implementation for User Story 1

- [X] T021 [US1] Capturer les valeurs de reference de la version actuelle (facture, gain, AC pour chaque mode) dans tests/testthat/fixtures/reference_values.rds
- [ ] T022 [US1] Brancher les classes R6 dans app.R : remplacer les appels directs (run_baseline, run_optimization_lp, etc.) par les classes R6 equivalentes
- [X] T023 [US1] Verifier la parite des resultats : lancer l'app avec les classes R6 et comparer avec les valeurs de reference T021
- [X] T024 [US1] Corriger les ecarts eventuels jusqu'a parite +-0.1%

**Checkpoint**: L'app fonctionne avec les classes R6 en backend. Resultats identiques a la version actuelle.

---

## Phase 4: User Story 2 — Logique metier isolee et testable (Priority: P1)

**Goal**: Un developpeur peut executer la logique metier dans un script R pur, sans Shiny.

**Independent Test**: Executer le script quickstart.md et verifier les resultats.

### Implementation for User Story 2

- [ ] T025 [US2] Verifier que toutes les classes R6 n'importent PAS shiny : grep -r "library(shiny)\|require(shiny)\|shiny::" R/R6_*.R doit retourner 0 resultat
- [ ] T026 [US2] Creer un script de validation scripts/validate_r6_standalone.R qui instancie Simulation, lance un workflow complet et affiche les KPI — sans library(shiny)
- [ ] T027 [US2] Executer devtools::test() et verifier que tous les tests passent

**Checkpoint**: Les classes R6 sont entierement independantes de Shiny. Script standalone fonctionne.

---

## Phase 5: User Story 3 — Structure Golem standard (Priority: P2)

**Goal**: Le projet suit la structure Golem. golem::run_app() fonctionne.

**Independent Test**: Executer golem::run_app() et verifier que l'app se lance.

### Implementation for User Story 3

- [ ] T028 [US3] Creer R/app_ui.R : assembler l'UI principale (sidebar + navset_card_tab) a partir de app.R actuel, en utilisant les modules
- [ ] T029 [US3] Creer R/app_server.R : server principal avec reactiveVal(NULL) pour sim_state, appels aux modules
- [ ] T030 [US3] Verifier que golem::run_app() lance l'app correctement
- [ ] T031 [US3] Mettre a jour DESCRIPTION avec toutes les dependances (Imports, Suggests)

**Checkpoint**: golem::run_app() fonctionne. La structure est reconnue par un developpeur R.

---

## Phase 6: User Story 4 — Modules UI decouples (Priority: P2)

**Goal**: Chaque onglet est un module Shiny Golem independant. Les modules ne contiennent pas de logique metier.

**Independent Test**: Verifier qu'aucun module R/mod_*.R ne contient de calcul metier (pas de formule thermique, pas d'optimisation).

### Implementation for User Story 4

- [ ] T032 [P] [US4] Creer R/mod_sidebar.R : module sidebar avec tous les inputs (parametres, baseline, optimisation, curtailment, batterie) dans R/mod_sidebar.R
- [ ] T033 [P] [US4] Creer R/mod_status_bar.R : module barre de statut (params, spinner, gain) dans R/mod_status_bar.R
- [ ] T034 [P] [US4] Creer R/mod_energie.R : module onglet Energie (conso bars, sankey) dans R/mod_energie.R
- [ ] T035 [P] [US4] Creer R/mod_finances.R : module onglet Finances (facture cumulee, waterfall, bilan mensuel) dans R/mod_finances.R
- [ ] T036 [P] [US4] Creer R/mod_details.R : module onglet Details (PAC timeline, temperature, COP, heatmap) dans R/mod_details.R
- [ ] T037 [P] [US4] Creer R/mod_contraintes.R : module onglet Contraintes (scorecard + 12 verifications) dans R/mod_contraintes.R
- [ ] T038 [P] [US4] Creer R/mod_dimensionnement.R : module onglet Dimensionnement (automagic, scenarii PV, scenarii batterie) dans R/mod_dimensionnement.R
- [ ] T039 [US4] Integrer tous les modules dans app_ui.R et app_server.R, remplacer le code inline de app.R
- [ ] T040 [US4] Verifier qu'aucun fichier R/mod_*.R ne contient de logique metier : grep pour calc_cop, run_baseline, solve_block, etc.

**Checkpoint**: Tous les onglets sont des modules Golem. La logique metier est dans les classes R6.

---

## Phase 7: User Story 5 — Encapsulation R6 de l'etat (Priority: P2)

**Goal**: L'etat de simulation est entierement encapsule dans un objet R6. Pas de variables globales.

**Independent Test**: Creer deux simulations avec des parametres differents, verifier qu'elles ne partagent pas d'etat.

### Implementation for User Story 5

- [ ] T041 [US5] Verifier l'isolation : creer 2 instances Simulation dans le script validate_r6_standalone.R, confirmer resultats independants
- [ ] T042 [US5] Implementer Simulation$export_csv(path) qui ecrit les resultats avec la structure de colonnes actuelle dans R/R6_simulation.R
- [ ] T043 [US5] Connecter le downloadHandler du module sidebar a Simulation$export_csv()

**Checkpoint**: Etat encapsule. Deux simulations simultanees possibles. Export CSV fonctionne.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Nettoyage final, suppression de l'ancien code, documentation.

- [ ] T044 Supprimer app.R (l'ancien monolithe) une fois golem::run_app() entierement valide
- [ ] T045 [P] Nettoyer les imports inutiles dans NAMESPACE via roxygen2::roxygenize()
- [ ] T046 [P] Mettre a jour renv.lock avec renv::snapshot()
- [ ] T047 [P] Mettre a jour docs/guidelines/constraints-and-improvements.md section structure du projet
- [ ] T048 [P] Mettre a jour la constitution (VIII. Project Structure) pour refleter la structure Golem
- [ ] T049 Validation finale : executer devtools::test(), golem::run_app(), et le script standalone — tout doit passer
- [ ] T050 Executer quickstart.md : verifier que toutes les instructions fonctionnent

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Pas de dependance — peut commencer immediatement
- **Foundational (Phase 2)**: Depend de Phase 1 (T005, T007 pour les helpers)
- **US1 Parite (Phase 3)**: Depend de Phase 2 (classes R6 creees)
- **US2 Testabilite (Phase 4)**: Depend de Phase 3 (parite validee)
- **US3 Golem (Phase 5)**: Depend de Phase 2 (classes R6)
- **US4 Modules (Phase 6)**: Depend de Phase 5 (app_ui.R, app_server.R) + Phase 3 (parite)
- **US5 Encapsulation (Phase 7)**: Depend de Phase 4 (testabilite) + Phase 6 (modules)
- **Polish (Phase 8)**: Depend de Phase 7 (tout valide)

### User Story Dependencies

- **US1 (P1)**: Depend de Foundational uniquement → MVP
- **US2 (P1)**: Depend de US1 (parite d'abord, testabilite ensuite)
- **US3 (P2)**: Depend de Foundational, peut etre en parallele avec US1
- **US4 (P2)**: Depend de US3 (structure Golem) + US1 (parite)
- **US5 (P2)**: Depend de US2 + US4

### Within Each User Story

- Tests ecrits et qui echouent AVANT implementation
- Classes R6 fondamentales avant orchestration
- Parite verifiee avant d'avancer

### Parallel Opportunities

- T003/T004/T005/T006/T007 en parallele (Phase 1 — fichiers differents)
- T010/T011 en parallele (DataProvider / DataGenerator — independants)
- T016/T017/T018/T019 en parallele (tests — fichiers differents)
- T032-T038 en parallele (modules UI — un par onglet)
- US3 (structure Golem) peut avancer en parallele avec US1 (parite R6)

---

## Parallel Example: Phase 2 (Foundational)

```text
# Vague 1 : classes independantes (en parallele)
T008: R6_params.R
T009: R6_thermal_model.R
T010: R6_data_provider.R
T011: R6_data_generator.R

# Vague 2 : classes qui dependent des precedentes
T012: R6_baseline.R (depend de T009 ThermalModel)
T013: R6_optimizer.R (depend de T009 ThermalModel)
T014: R6_kpi.R (independant)

# Vague 3 : orchestrateur
T015: R6_simulation.R (depend de tous les precedents)
```

## Parallel Example: Phase 6 (Modules UI)

```text
# Tous les modules en parallele (fichiers independants)
T032: mod_sidebar.R
T033: mod_status_bar.R
T034: mod_energie.R
T035: mod_finances.R
T036: mod_details.R
T037: mod_contraintes.R
T038: mod_dimensionnement.R

# Integration sequentielle
T039: assembler dans app_ui.R + app_server.R
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup Golem
2. Complete Phase 2: Classes R6 fondamentales
3. Complete Phase 3: Parite fonctionnelle (US1)
4. **STOP and VALIDATE**: L'app fonctionne avec R6, resultats identiques
5. Si OK → continuer. Si regression → corriger avant d'avancer.

### Incremental Delivery

1. Setup + Foundational → Classes R6 creees et testees
2. US1 (parite) → L'app marche avec R6 → **Milestone 1**
3. US2 (testabilite) → Script standalone fonctionne → **Milestone 2**
4. US3 + US4 (Golem + modules) → Structure propre → **Milestone 3**
5. US5 (encapsulation) + Polish → Code final, app.R supprime → **Milestone 4**

---

## Notes

- L'ancien app.R RESTE fonctionnel pendant TOUTE la migration (supprime en T044 seulement)
- Chaque phase est un commit atomique — on peut revenir en arriere
- Les classes R6 encapsulent la logique existante, elles ne la reecrivent pas
- La logique interne des optimiseurs (ompr, CVXR) reste inchangee
- Tester la parite (US1) AVANT de migrer l'UI (US4)
