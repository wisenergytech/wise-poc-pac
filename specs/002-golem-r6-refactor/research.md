# Research: Golem + R6 OOP Architecture

## R1: Golem framework — structure et conventions

**Decision**: Utiliser golem >= 0.4.0 avec la structure standard.

**Rationale**: Golem est le framework de reference pour les apps Shiny en production. Il fournit :
- Structure standardisee (`R/`, `inst/`, `dev/`, `tests/`)
- `golem::run_app()` comme point d'entree
- `golem::add_module()` pour creer des modules avec namespace
- `golem::add_fct()` pour les fonctions utilitaires
- Integration native avec testthat, roxygen2, pkgdown
- Deploiement simplifie (Docker, RStudio Connect, shinyapps.io)

**Alternatives considered**:
- `rhino` (Appsilon) : plus moderne mais moins mature et moins adopte
- Structure manuelle : fonctionne mais pas de standardisation ni d'outillage

## R2: R6 — heritage et encapsulation pour les optimiseurs

**Decision**: Heritage R6 classique avec `BaseOptimizer$new()` et sous-classes via `inherit`.

**Rationale**: R6 fournit :
- `inherit` pour l'heritage (BaseOptimizer -> MILPOptimizer)
- `private` pour l'etat interne (pas d'acces accidentel)
- `active` pour les getters/setters (validation automatique)
- Semantique de reference (pas de copie implicite comme les listes R)
- Testable sans Shiny (instanciation directe)

**Pattern retenu pour les optimiseurs** :
```r
BaseOptimizer <- R6::R6Class("BaseOptimizer",
  public = list(
    initialize = function(params, data) { ... },
    solve = function() { ... },          # appelle solve_block en boucle
    get_results = function() { ... },    # retourne le dataframe resultat
    guard_baseline = function(baseline_data) { ... }
  ),
  private = list(
    params = NULL,
    data = NULL,
    results = NULL,
    solve_block = function(block_data, t_init, soc_init, prix_terminal) {
      stop("Must be implemented by subclass")
    }
  )
)

LPOptimizer <- R6::R6Class("LPOptimizer",
  inherit = BaseOptimizer,
  private = list(
    solve_block = function(block_data, t_init, soc_init, prix_terminal) {
      # Logique ompr existante
    }
  )
)
```

**Alternatives considered**:
- S4 classes : plus formel mais verbeux et moins intuitif pour l'heritage
- Listes R avec dispatch manuel : pas d'encapsulation, pas d'heritage propre
- R7 (futur) : pas encore stable

## R3: Communication Shiny <-> R6 via reactiveVal

**Decision**: Un `reactiveVal` central dans le server principal contient l'objet Simulation R6.

**Rationale**:
- Les modules Shiny observent le reactiveVal et lisent l'etat via les getters R6
- La reactivite reste dans Shiny, la logique dans R6
- Pas de reactive() dans les classes R6 → testabilite preservee

**Pattern retenu** :
```r
# app_server.R
server <- function(input, output, session) {
  sim_state <- reactiveVal(NULL)  # contient un objet Simulation R6

  # Module sidebar declenche la simulation
  mod_sidebar_server("sidebar", sim_state)

  # Modules onglets lisent sim_state
  mod_energie_server("energie", sim_state)
  mod_finances_server("finances", sim_state)
  # ...
}
```

**Alternatives considered**:
- reactiveValues (multiple vals) : plus granulaire mais eparpille l'etat
- session$userData : fonctionne mais moins explicite
- R6 reactive wrapper : melange les preoccupations

## R4: Migration incrementale — ordre des etapes

**Decision**: Migrer dans cet ordre :
1. Creer la structure Golem (DESCRIPTION, inst/, dev/)
2. Extraire les classes R6 metier (sans toucher l'UI)
3. Ecrire les tests unitaires R6
4. Creer les modules Shiny Golem
5. Migrer l'UI de app.R vers les modules
6. Supprimer app.R

**Rationale**: Les classes R6 peuvent etre creees et testees sans modifier l'UI existante. L'app reste fonctionnelle via l'ancien app.R pendant toute la migration. Les modules Shiny sont crees en dernier car ils dependent des classes R6.

## R5: Gestion du CSS et du theme

**Decision**: Centraliser dans `R/fct_ui_theme.R` (constantes R) + `inst/app/www/custom.css` (CSS).

**Rationale**:
- Les constantes de couleur (`cl$bg_dark`, `cl$accent`, etc.) sont utilisees dans le code R → rester en R
- Le CSS inline de app.R est deplace dans un fichier CSS externe charge par Golem
- Le theme bslib est configure dans `app_ui.R`

## R6: testthat — strategie de test

**Decision**: Tests unitaires des classes R6 metier avec testthat.

**Rationale**:
- Tester chaque classe R6 independamment (sans Shiny)
- Tests de reference : capturer les resultats numeriques de la version actuelle comme valeurs attendues
- Couverture cible : 50% des methodes publiques
- Pas de tests UI (shinytest2 hors scope)

**Structure des tests** :
- `test-R6_thermal_model.R` : calc_cop, dynamique thermique
- `test-R6_baseline.R` : 5 modes, parite avec l'ancien code
- `test-R6_optimizer.R` : LP sur un petit dataset, resultats de reference
- `test-R6_kpi.R` : facture, autoconsommation, conformite
- `test-R6_simulation.R` : workflow complet, guard_baseline
