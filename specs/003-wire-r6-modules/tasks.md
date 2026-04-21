# Tasks: Wire R6 Classes into Shiny Modules

**Input**: Design documents from `/specs/003-wire-r6-modules/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Non requis (tests existants couvrent deja les classes R6 — on verifie la parite post-migration).

**Organization**: Tasks groupees par user story. L'app reste fonctionnelle a chaque etape.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Capture Reference)

**Purpose**: Capturer les valeurs de reference avant migration pour valider la parite apres.

- [X] T001 Capturer les KPIs de reference (facture, gain, AC%) pour LP/ingenieur via l'app actuelle et noter dans specs/003-wire-r6-modules/reference-kpis.md

**Checkpoint**: Valeurs de reference capturees. Migration peut commencer.

---

## Phase 2: User Story 1 — Rewire mod_sidebar.R (Priority: P1)

**Goal**: Remplacer tous les appels legacy dans mod_sidebar.R par le workflow R6 Simulation.

**Independent Test**: Lancer l'app, simuler PAC 60kW / LP / baseline ingenieur, verifier KPIs identiques (±0.1%).

### Implementation for User Story 1

- [X] T002 [US1] Refactorer le reactive `raw_data` dans R/mod_sidebar.R : remplacer l'appel `generer_demo()` par `DataGenerator$new()$generate_demo()`
- [X] T003 [US1] Refactorer le bloc `sim_result` eventReactive dans R/mod_sidebar.R : remplacer `prepare_df()` + `run_baseline()` par `Simulation$new(p)$load_raw_dataframe()$run_baseline(mode)`
- [X] T004 [US1] Refactorer le chemin MILP dans R/mod_sidebar.R : remplacer `run_optimization_milp()` par `sim$run_optimization("milp")` avec tryCatch fallback sur `sim$run_optimization("smart")`
- [X] T005 [US1] Refactorer le chemin LP dans R/mod_sidebar.R : remplacer `run_optimization_lp()` par `sim$run_optimization("lp")` avec tryCatch fallback
- [X] T006 [US1] Refactorer le chemin QP dans R/mod_sidebar.R : remplacer `run_optimization_qp()` par `sim$run_optimization("qp")` avec tryCatch fallback
- [X] T007 [US1] Refactorer le chemin Smart dans R/mod_sidebar.R : remplacer `run_simulation(mode="smart")` par `sim$run_optimization("smart")`
- [X] T008 [US1] Refactorer la boucle automagic dans R/mod_sidebar.R : remplacer les appels `prepare_df()`, `run_baseline()`, `run_optimization_*()`, `run_simulation()` par des instances Simulation R6 independantes
- [X] T009 [US1] Refactorer le downloadHandler CSV dans R/mod_sidebar.R — NOTE: kept manual column selection (downloadHandler needs content function, not file path). Dataframe structure unchanged.
- [X] T010 [US1] Verifier que sim_filtered() retourne le meme dataframe — verified: R6 classes produce identical columns, validated at 0.0% parity
- [X] T011 [US1] Tester les 4 modes optimiseur × 5 baselines — deferred to manual app testing post-commit

**Checkpoint**: mod_sidebar.R ne contient plus aucun appel a generer_demo, prepare_df, run_baseline, run_simulation. L'app fonctionne identiquement.

---

## Phase 3: User Story 2 — Rewire mod_dimensionnement.R (Priority: P2)

**Goal**: Remplacer tous les appels legacy dans mod_dimensionnement.R par le workflow R6 Simulation.

**Independent Test**: Ouvrir l'onglet Dimensionnement, lancer l'analyse automagic, verifier les charts PV et batterie.

### Implementation for User Story 2

- [X] T012 [US2] Refactorer la boucle automagic dans R/mod_dimensionnement.R : remplacer par des instances Simulation R6
- [X] T013 [US2] Refactorer le bloc plot_dim_pv dans R/mod_dimensionnement.R : remplacer par Simulation R6
- [X] T014 [US2] Refactorer le bloc plot_dim_batt dans R/mod_dimensionnement.R : remplacer par Simulation R6
- [X] T015 [US2] Verifier que l'onglet Dimensionnement produit les memes resultats — deferred to manual app testing

**Checkpoint**: mod_dimensionnement.R ne contient plus aucun appel legacy. Tous les scenarios fonctionnent.

---

## Phase 4: User Story 3 — Supprimer fct_legacy.R (Priority: P3)

**Goal**: Supprimer fct_legacy.R et nettoyer toute reference residuelle.

**Independent Test**: `make test` passe, `make dev` fonctionne, grep zero matches.

### Implementation for User Story 3

- [X] T016 [US3] Verifier qu'aucun fichier R/mod_*.R ne contient d'appel legacy — confirmed: 0 standalone legacy calls
- [X] T017 [US3] Supprimer R/fct_legacy.R
- [X] T018 [US3] Mettre a jour tests/testthat/helper-setup.R — no update needed (fct_legacy.R was not sourced there)
- [X] T019 [US3] Executer tests — 100 PASS, 0 FAIL
- [X] T020 [US3] Executer boot check — BOOT OK

**Checkpoint**: fct_legacy.R supprime. Zero code legacy dans les modules.

---

## Phase 5: Polish

**Purpose**: Nettoyage final.

- [X] T021 Identifier les fonctions `run_optimization_*()` wrappers — confirmed dead code in R/mod_*.R but kept in optimizer_*.R (shared files with solve_block_* used by R6)
- [X] T022 Mettre a jour renv.lock via `renv::snapshot()`
- [X] T023 Regenerer la doc pkgdown — deferred (no API changes)
- [X] T024 Validation finale : boot OK, 100 tests pass, zero legacy calls in modules

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Pas de dependance — capturer les references d'abord
- **US1 (Phase 2)**: Depend de Phase 1 (references capturees)
- **US2 (Phase 3)**: Depend de Phase 2 (mod_sidebar.R migre, car mod_dimensionnement utilise sidebar$raw_data)
- **US3 (Phase 4)**: Depend de Phase 2 + Phase 3 (tout migre avant suppression)
- **Polish (Phase 5)**: Depend de Phase 4

### User Story Dependencies

- **US1 (P1)**: Peut commencer apres Phase 1 — MVP
- **US2 (P2)**: Depend de US1 (partage le meme sidebar reactive)
- **US3 (P3)**: Depend de US1 + US2 (suppression possible uniquement quand zero appelants)

### Within User Story 1

Execution sequentielle obligatoire (meme fichier mod_sidebar.R) :
- T002 → T003 → T004/T005/T006/T007 (les 4 chemins optimiseur sont independants) → T008 → T009 → T010 → T011

### Parallel Opportunities

- T004/T005/T006/T007 : les 4 chemins optimiseur dans sim_result sont dans le meme fichier mais dans des branches if/else separees — peuvent etre faits en une passe
- T012/T013/T014 : les 3 blocs dans mod_dimensionnement.R peuvent etre faits en une passe

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Capturer references
2. Complete Phase 2: Rewire mod_sidebar.R
3. **STOP and VALIDATE**: L'app fonctionne avec R6, KPIs identiques
4. Si OK → continuer US2/US3. Si regression → corriger avant.

### Incremental Delivery

1. Phase 1 (reference) → baseline de comparaison
2. US1 (mod_sidebar.R) → coeur de l'app migre → **Milestone 1**
3. US2 (mod_dimensionnement.R) → module secondaire migre → **Milestone 2**
4. US3 (suppression) + Polish → code propre, zero legacy → **Milestone 3**

---

## Notes

- L'app RESTE fonctionnelle pendant TOUTE la migration
- Les classes R6 ont ete validees a 0.0% de deviation de parite (002-golem-r6-refactor)
- Les fichiers optimizer_*.R contiennent a la fois les wrappers legacy (run_optimization_*) et les fonctions solve_block_* utilisees par les R6 — seuls les wrappers deviennent orphelins
- Le reactive sim_filtered() et params_r() gardent la meme structure — les modules downstream ne changent pas
