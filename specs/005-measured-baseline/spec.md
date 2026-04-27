# Feature Specification: Baseline mesuree pour CSV complet

**Feature Branch**: `005-measured-baseline`
**Created**: 2026-04-27
**Status**: Clarified
**Input**: Quand l'utilisateur uploade un CSV avec pac_kwh + compteur, utiliser les donnees mesurees comme baseline au lieu de re-simuler un comportement fictif.

## Clarifications

### Session 2026-04-27

- Q: Faut-il exiger t_ballon pour activer la baseline mesuree ? → A: Non (option B). Activer des que pac_kwh + compteur sont presents. Si t_ballon absent, notifier que l'ECS est synthetique.
- Q: Comment pre-remplir pv_kwc_ref en mode CSV ? → A: Heuristique max(pv_kwh)/0.25/0.90 + message "Verifiez cette valeur" (option A).
- Q: Le champ pv_kwc doit-il etre verrouillé en mode baseline mesuree ? → A: Oui (option B). Verrouille par defaut, debloque par un toggle "Tester un autre dimensionnement PV".
- Q: Quel niveau de notification pour ECS synthetique sans t_ballon ? → A: Texte dans le bandeau baseline (option A) : "ECS estime par profil synthetique (pas de t_ballon)".
- Q: Quelles vignettes mettre a jour ? → A: lire-les-resultats + cas-usage-faq uniquement (option A).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Baseline mesuree automatique (Priority: P1)

L'utilisateur uploade un CSV contenant `pv_kwh`, `pac_kwh`, `offtake_kwh` et `feedin_kwh`. L'app detecte que le CSV est eligible a la baseline mesuree et l'active automatiquement. Le slider d'autoconsommation, le bouton "Calibrer les bornes", le checkbox "Suivi PV existant" et le champ ECS sont masques. Le champ pv_kwc est verrouille (= pv_kwc_ref). Un bandeau informatif indique le mode actif. L'AC mesuree est affichee en lecture seule. Les gains compares sont optimise vs reel.

**Why this priority**: C'est le coeur de la feature. Sans ca, l'app re-simule une baseline fictive alors que les donnees reelles sont disponibles, ce qui reduit la fiabilite des resultats.

**Independent Test**: Uploader un CSV avec pac_kwh + compteur. Verifier que le slider AC disparait, que le bandeau s'affiche, et que les KPI baseline correspondent aux valeurs mesurees du CSV (soutirage, injection, conso PAC).

**Acceptance Scenarios**:

1. **Given** un CSV avec pv_kwh, pac_kwh, offtake_kwh, feedin_kwh et pv_kwc == pv_kwc_ref, **When** l'utilisateur lance une simulation, **Then** la baseline utilise les valeurs mesurees (offtake_kwh, intake_kwh du CSV) sans re-simulation thermique.
2. **Given** un CSV avec pac_kwh + compteur + t_ballon, **When** le sidebar s'affiche, **Then** le bandeau indique "Baseline = donnees mesurees (completes)" et le champ ECS est masque.
3. **Given** un CSV avec pac_kwh + compteur mais sans t_ballon, **When** le sidebar s'affiche, **Then** le bandeau indique "Baseline = donnees mesurees. ECS estime par profil synthetique (pas de t_ballon)." et le champ ECS reste visible (pour ajuster ecs_kwh_jour).
4. **Given** un CSV eligible, **When** les KPI sont calcules, **Then** conso_pac_baseline == sum(pac_kwh du CSV), soutirage_baseline == sum(offtake_kwh du CSV), injection_baseline == sum(feedin_kwh du CSV).

---

### User Story 2 - Bascule what-if PV (Priority: P2)

L'utilisateur a uploade un CSV eligible et souhaite tester un PV de taille differente. Il active le toggle "Tester un autre dimensionnement PV", ce qui deverrouille le champ pv_kwc. L'app bascule en baseline simulee et re-affiche le slider AC avec un message explicatif.

**Why this priority**: Cas d'usage frequent (dimensionnement). La baseline mesuree n'est plus valide car le surplus PV change — il faut gerer la transition proprement.

**Independent Test**: Uploader un CSV eligible, verifier la baseline mesuree, puis activer le toggle what-if et modifier pv_kwc. Verifier que le slider AC reapparait et que le bandeau change.

**Acceptance Scenarios**:

1. **Given** un CSV eligible avec baseline mesuree active, **When** l'utilisateur active le toggle "Tester un autre dimensionnement PV", **Then** le champ pv_kwc est deverrouille, le mode bascule en baseline simulee, le slider AC reapparait, et un message indique "PV rescale -> baseline simulee (les mesures ne sont plus valides pour cette taille PV)".
2. **Given** un CSV eligible en mode what-if, **When** l'utilisateur desactive le toggle, **Then** pv_kwc revient a pv_kwc_ref, le mode rebascule en baseline mesuree et le slider AC disparait.

---

### User Story 3 - CSV partiel (pas de pac_kwh) (Priority: P3)

L'utilisateur uploade un CSV sans pac_kwh. L'app reste en mode baseline simulee (thermostat ou pv_tracking) comme aujourd'hui. Aucun changement de comportement.

**Why this priority**: Cas de non-regression. Le comportement existant doit etre preserve pour les CSV incomplets.

**Independent Test**: Uploader un CSV avec pv_kwh + offtake_kwh + feedin_kwh mais sans pac_kwh. Verifier que le slider AC et le checkbox "Suivi PV existant" restent visibles.

**Acceptance Scenarios**:

1. **Given** un CSV sans pac_kwh, **When** le sidebar s'affiche, **Then** le slider AC et le checkbox "Suivi PV existant" restent visibles, le mode est baseline simulee.
2. **Given** un CSV avec pac_kwh mais un taux de NA > 10% sur pac_kwh, **When** le sidebar s'affiche, **Then** le mode reste baseline simulee.

---

### Edge Cases

- Que se passe-t-il si le CSV contient pac_kwh mais avec beaucoup de valeurs manquantes (NA) ? → Rester en baseline simulee si le taux de NA depasse 10%.
- Que se passe-t-il si pv_kwc_ref n'est pas renseigne par l'utilisateur en mode CSV ? → Pre-remplir avec heuristique max(pv_kwh) / 0.25 / 0.90 + message "Verifiez cette valeur".
- Que se passe-t-il si l'utilisateur passe de CSV a Demo ? → Retour au mode baseline simulee, slider AC re-affiche, toggle what-if masque.
- Que se passe-t-il avec le guard_baseline ? → Fonctionne tel quel : compare facture optimisee vs facture mesuree.
- Que se passe-t-il si t_ballon est present dans le CSV ? → ECS estimee depuis delta_t (meilleure qualite), champ ecs_kwh_jour masque.
- Que se passe-t-il si t_ballon est absent mais pac_kwh present ? → ECS par profil synthetique, champ ecs_kwh_jour visible pour ajustement, bandeau le notifie.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Le systeme DOIT detecter automatiquement si un CSV est "eligible baseline mesuree" (presence de pac_kwh + offtake_kwh + feedin_kwh/intake_kwh, avec un taux de NA < 10% sur pac_kwh).
- **FR-002**: Le systeme DOIT proposer un mode baseline `"measured"` dans la classe Baseline qui retourne le dataframe prepare sans re-simulation thermique (pass-through).
- **FR-003**: Le systeme DOIT masquer le slider AC, le bouton "Calibrer les bornes" et le checkbox "Suivi PV existant" quand la baseline mesuree est active.
- **FR-004**: Le systeme DOIT afficher un bandeau informatif avec l'AC mesuree (lecture seule) quand la baseline mesuree est active. Si t_ballon est absent, le bandeau DOIT indiquer "ECS estime par profil synthetique (pas de t_ballon)".
- **FR-005**: Le systeme DOIT verrouiller le champ pv_kwc (= pv_kwc_ref) en mode baseline mesuree, avec un toggle "Tester un autre dimensionnement PV" pour le deverrouiller. Activer le toggle bascule en baseline simulee.
- **FR-006**: Le systeme DOIT pre-remplir pv_kwc_ref avec une estimation heuristique du CSV (max(pv_kwh) / 0.25 / 0.90) comme suggestion modifiable, avec le message "Verifiez cette valeur".
- **FR-007**: Le systeme DOIT masquer le champ ecs_kwh_jour quand t_ballon est present dans le CSV (ECS estimee depuis delta_t). Le champ reste visible quand t_ballon est absent (profil synthetique ajustable).
- **FR-008**: Le systeme DOIT mettre a jour les vignettes lire-les-resultats et cas-usage-faq pour documenter le mode baseline mesuree.
- **FR-009**: Le systeme NE DOIT PAS modifier le comportement existant pour le mode Demo ou les CSV sans pac_kwh.

### Key Entities

- **Baseline mesuree**: Les donnees reelles du CSV (offtake_kwh, intake_kwh, pac_kwh, et optionnellement t_ballon) utilisees directement comme scenario de reference sans simulation.
- **Baseline simulee**: Le comportement existant (thermostat ou pv_tracking) qui simule un scenario de reference via un modele thermique et un parametre alpha.
- **CSV eligible**: Un CSV contenant au minimum pv_kwh, pac_kwh, offtake_kwh et feedin_kwh/intake_kwh avec un taux de NA < 10% sur pac_kwh. La presence de t_ballon est optionnelle (ameliore la qualite ECS).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En mode baseline mesuree, les KPI baseline (soutirage, injection, conso PAC) correspondent exactement aux sommes des colonnes du CSV (tolerance < 0.1%).
- **SC-002**: En mode baseline mesuree, le slider AC n'est pas visible, le champ pv_kwc est verrouille, et le bandeau est affiche.
- **SC-003**: L'activation du toggle what-if PV re-affiche le slider et deverrouille pv_kwc en moins d'un cycle reactif Shiny.
- **SC-004**: Les tests unitaires existants (test-R6_baseline.R, test-R6_kpi.R) passent sans modification (non-regression).
- **SC-005**: Un nouveau test unitaire valide que Baseline$run(mode = "measured") retourne le dataframe inchange (colonnes offtake_kwh, intake_kwh identiques a l'entree).

## Assumptions

- Le CSV uploade a un pas de temps de 15 minutes (coherent avec dt_h = 0.25).
- Les colonnes pac_kwh du CSV sont fiables (sous-compteur reel).
- L'estimation heuristique de pv_kwc_ref (max/0.25/0.90) est une suggestion, pas une verite — l'utilisateur peut la corriger.
- Le mode Demo n'est pas concerne par cette feature.
- L'optimiseur (LP/MILP/QP) n'a pas besoin de savoir si la baseline est mesuree ou simulee — il travaille sur les memes colonnes.
- La presence de t_ballon ameliore la qualite de l'estimation ECS mais n'est pas requise pour la baseline mesuree.

## Terminology

Pour eviter toute confusion dans le code et la documentation :

| Terme | Definition | Colonnes / contexte |
|---|---|---|
| **Donnees brutes** (raw) | CSV tel qu'uploade, avant tout traitement | pv_kwh, pac_kwh, offtake_kwh, feedin_kwh, t_ballon, t_ext |
| **Donnees preparees** (prepared) | Apres prepare_df : rescaling PV, ajout prix, calcul conso_hors_pac | + pv_kwh_original, prix_offtake, prix_injection, conso_hors_pac, soutirage_estime_kwh |
| **Baseline** | Scenario de reference "sans EMS". Peut etre **mesuree** ou **simulee** | offtake_kwh, intake_kwh, t_ballon |
| **Baseline mesuree** | Donnees reelles du CSV utilisees directement (pass-through) | Mode "measured" dans Baseline$run() |
| **Baseline simulee** | Comportement re-simule par le modele thermique (thermostat ou pv_tracking) | Mode "thermostat" ou "pv_tracking" dans Baseline$run() |
| **CSV eligible** | CSV avec pac_kwh + compteur (NA < 10%) | Condition d'activation de la baseline mesuree |
| **Optimise** | Resultat du solveur LP/MILP/QP | sim_offtake, sim_intake, sim_t_ballon, sim_pac_on |

## Impacted Files

| Fichier | Nature du changement |
|---|---|
| `R/R6_baseline.R` | Nouveau mode `"measured"` (pass-through) |
| `R/R6_simulation.R` | Propager mode "measured" dans run_baseline() |
| `R/mod_sidebar.R` | Detection CSV eligible, masquage conditionnel UI (slider AC, checkbox suivi PV, champ ECS), toggle what-if PV, verrouillage pv_kwc, pre-remplissage pv_kwc_ref, bandeau informatif |
| `R/fct_sizing.R` | Pas de changement (compute_ac_bounds non appele en mode measured) |
| `R/R6_kpi.R` | Pas de changement (utilise deja pac_kwh si disponible) |
| `R/R6_optimizer.R` | Pas de changement (guard_baseline fonctionne tel quel) |
| `R/R6_data_generator.R` | Pas de changement (prepare_df gere deja pac_kwh) |
| `vignettes/lire-les-resultats.Rmd` | Documenter le mode baseline mesuree |
| `vignettes/cas-usage-faq.Rmd` | FAQ "Baseline mesuree vs simulee" |
| `tests/testthat/test-R6_baseline.R` | Nouveau test pour mode "measured" |
