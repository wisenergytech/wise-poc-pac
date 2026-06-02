# Feature Specification: CSV Column Mapping dynamique

**Feature Branch**: `010-csv-column-mapping`
**Created**: 2026-05-26
**Status**: Draft
**Input**: See `discovery/010-csv-column-mapping.md`

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Mapper les colonnes d'un CSV importe (Priority: P1)

En tant qu'utilisateur, je veux pouvoir associer chaque colonne de mon CSV aux champs attendus par l'app via des selecteurs dans le sidebar, afin de ne pas avoir a renommer manuellement mes colonnes avant import.

**Why this priority**: Sans le mapping, l'app ne peut pas ingerer un CSV dont les colonnes ne correspondent pas au format actuel. C'est le prerequis de toute la feature.

**Independent Test**: L'utilisateur importe un CSV avec des noms de colonnes non-standard (ex: `ts`, `solar_kw`, `grid_import_kwh`), mappe chaque colonne via les selecteurs, et lance une simulation qui produit des resultats corrects.

**Acceptance Scenarios**:

1. **Given** l'utilisateur importe un CSV, **When** le fichier est charge, **Then** un panneau de mapping apparait avec un selecteur par champ requis (timestamp, PV, offtake, feedin) et chaque selecteur propose la liste des colonnes du CSV.
2. **Given** le CSV a des colonnes nommees exactement comme le format actuel (`timestamp`, `pv_kwh`, `offtake_kwh`, `feedin_kwh`), **When** le fichier est charge, **Then** le mapping est pre-rempli automatiquement et l'utilisateur peut lancer la simulation sans intervention (retrocompatibilite).
3. **Given** l'utilisateur a mappe les colonnes, **When** il lance la simulation, **Then** les donnees sont renommees en interne vers les noms attendus par l'app et la simulation produit des resultats identiques a ceux obtenus avec un CSV au format natif.
4. **Given** l'utilisateur ne mappe pas une colonne requise (ex: timestamp), **When** il tente de lancer la simulation, **Then** un message d'erreur clair indique quelles colonnes sont manquantes.

---

### User Story 2 - Pre-suggestion intelligente du mapping (Priority: P1)

En tant qu'utilisateur, je veux que l'app devine les associations probables a partir des noms de colonnes de mon CSV, afin de gagner du temps quand mes colonnes ont des noms explicites.

**Why this priority**: Meme importance que US-1 — sans la pre-suggestion, l'utilisateur doit tout mapper a la main a chaque import, ce qui est fastidieux.

**Independent Test**: L'utilisateur importe le CSV `bq_k0001_dual_pac.csv` et tous les champs sont automatiquement mappes correctement sans intervention.

**Acceptance Scenarios**:

1. **Given** un CSV avec une colonne `gshp_kwh`, **When** le fichier est charge, **Then** le champ "PAC 1" est pre-rempli avec `gshp_kwh`.
2. **Given** un CSV avec une colonne `ashp_kwh`, **When** le fichier est charge, **Then** le champ "PAC 2" est pre-rempli avec `ashp_kwh`.
3. **Given** un CSV avec une colonne `t_ballon`, **When** le fichier est charge, **Then** le champ "Temperature ballon" est pre-rempli avec `t_ballon`.
4. **Given** un CSV avec des colonnes aux noms totalement differents (ex: `col_A`, `col_B`), **When** le fichier est charge, **Then** aucun champ n'est pre-rempli et l'utilisateur peut tout mapper manuellement.
5. **Given** un CSV au format actuel (`pac_kwh` unique), **When** le fichier est charge, **Then** le champ "PAC 1" est pre-rempli avec `pac_kwh` et "PAC 2" reste vide.

---

### User Story 3 - Configurer chaque PAC independamment (Priority: P2)

En tant qu'utilisateur, je veux pouvoir definir pour chaque PAC mappee son type, son mode, sa puissance et son COP nominal, afin que l'optimiseur utilise les bons parametres pour chaque machine.

**Why this priority**: La configuration PAC est deja partiellement implementee (feature 009). Cette story l'enrichit en liant la config a la colonne mappee.

**Independent Test**: L'utilisateur mappe deux colonnes PAC, configure PAC 1 comme GSHP on/off 40 kWth et PAC 2 comme ASHP inverter 24 kWth, et l'optimiseur dual utilise ces parametres.

**Acceptance Scenarios**:

1. **Given** l'utilisateur a mappe une colonne pour PAC 1, **When** il configure type=GSHP, mode=on/off, puissance=40 kWth, COP=4.5, **Then** ces parametres sont transmis a l'optimiseur.
2. **Given** l'utilisateur a mappe une colonne pour PAC 2, **When** il la configure, **Then** l'optimiseur dual est active automatiquement (pac2_active = TRUE).
3. **Given** l'utilisateur n'a mappe aucune colonne pour PAC 2, **When** il lance la simulation, **Then** l'optimiseur mono-PAC est utilise (comportement actuel).

---

### User Story 4 - Explorer les colonnes reelles du CSV (Priority: P2)

En tant qu'utilisateur, je veux que l'explorateur de donnees propose les noms de colonnes reels de mon CSV dans les dropdowns, afin de pouvoir visualiser n'importe quelle serie temporelle de mon fichier.

**Why this priority**: L'exploration est utile pour comprendre les donnees mais n'est pas necessaire pour l'optimisation.

**Independent Test**: L'utilisateur importe un CSV avec 15 colonnes, ouvre l'onglet Comparaison, et voit les 15 colonnes numeriques disponibles dans les selecteurs de series.

**Acceptance Scenarios**:

1. **Given** un CSV avec des colonnes `gshp_kwh`, `ashp_kwh`, `cop_gshp`, `cop_ashp`, **When** l'utilisateur ouvre l'explorateur, **Then** ces 4 colonnes apparaissent dans les dropdowns avec leurs noms reels.
2. **Given** un CSV importe et une simulation terminee, **When** l'utilisateur consulte l'explorateur, **Then** il voit a la fois les colonnes du CSV original et les colonnes generees par la simulation (sim_offtake, sim_t_ballon, etc.).
3. **Given** le mode Demo est actif (pas de CSV), **When** l'utilisateur consulte l'explorateur, **Then** le comportement est identique a l'existant (variables hardcodees).

---

### Edge Cases

- **CSV avec une seule colonne numerique** : le mapping ne propose qu'une option par champ, l'utilisateur doit confirmer ou changer.
- **CSV sans colonne timestamp** : message d'erreur clair, la simulation ne peut pas demarrer.
- **CSV avec des colonnes dupliquees** : les selecteurs affichent toutes les colonnes, l'utilisateur choisit laquelle utiliser.
- **Changement de CSV en cours de session** : le mapping est reinitialise, les pre-suggestions recalculees.
- **Colonne mappee avec des valeurs non numeriques** : message d'erreur a la validation, avant la simulation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Quand un CSV est importe, le systeme DOIT detecter automatiquement les noms de colonnes et les proposer dans des selecteurs de mapping.
- **FR-002**: Le systeme DOIT afficher un selecteur par champ requis (timestamp, PV, offtake, feedin) et par champ optionnel (PAC 1, PAC 2, t_ballon, t_sol, t_ext). Chaque selecteur propose les colonnes du CSV + une option "Non disponible".
- **FR-003**: Le systeme DOIT pre-remplir les selecteurs en utilisant un matching par mots-cles sur les noms de colonnes. Regles de matching :
  - `timestamp`, `time`, `datetime`, `date` → champ timestamp
  - `pv`, `solar`, `photovoltaic` → champ PV
  - `offtake`, `soutirage`, `consumption`, `import`, `grid_import` → champ offtake
  - `feedin`, `injection`, `export`, `grid_export`, `intake` → champ feedin
  - `pac`, `hp`, `heat_pump`, `heatpump` → champ PAC 1
  - `gshp`, `geo`, `geothermal`, `pac_301`, `pac_3` → champ PAC 1 (type GSHP pre-selectionne)
  - `ashp`, `aero`, `aerothermal`, `pac_501`, `pac_5` → champ PAC 2 (type ASHP pre-selectionne)
  - `t_ballon`, `tank`, `buffer`, `t_tank` → champ temperature ballon
  - `t_sol`, `ground`, `borehole`, `soil` → champ temperature sol
  - `t_ext`, `outdoor`, `ambient`, `external` → champ temperature exterieure
  - `cop` → champ COP (si prefixe gshp/ashp, associer a la PAC correspondante)
- **FR-004**: Si les colonnes du CSV correspondent exactement au format actuel (`timestamp`, `pv_kwh`, `offtake_kwh`, `feedin_kwh`/`intake_kwh`), le mapping DOIT etre automatique sans intervention utilisateur (retrocompatibilite).
- **FR-005**: Le systeme DOIT valider que les champs requis (timestamp, au moins un champ energetique) sont mappes avant de permettre le lancement de la simulation.
- **FR-006**: Pour chaque PAC mappee, le systeme DOIT afficher les controles de configuration : type (ASHP/GSHP), mode (on/off ou inverter), puissance thermique (kWth), COP nominal.
- **FR-007**: Si une colonne PAC 2 est mappee, le systeme DOIT activer automatiquement le mode dual (pac2_active = TRUE) et utiliser le DualOptimizer.
- **FR-008**: L'explorateur de donnees DOIT proposer dans ses dropdowns toutes les colonnes numeriques du CSV importe, avec leurs noms reels, en plus des variables generees par la simulation.
- **FR-009**: En mode Demo, le comportement de l'explorateur DOIT rester identique a l'existant (variables hardcodees).
- **FR-010**: Quand l'utilisateur change de CSV, le mapping DOIT etre reinitialise et les pre-suggestions recalculees.

### Key Entities

- **Column Mapping** : association entre un nom de colonne du CSV importe et un champ interne de l'app (timestamp, pv_kwh, offtake_kwh, etc.). Contient : nom source (CSV), nom cible (interne), statut (mappe/non mappe), confiance de la pre-suggestion.
- **PAC Configuration** : ensemble des parametres d'une PAC associee a une colonne mappee : type (ASHP/GSHP), mode (on/off, inverter), puissance thermique (kWth), COP nominal.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: L'utilisateur peut importer le CSV `bq_k0001_dual_pac.csv` et lancer une simulation dual sans renommer aucune colonne — le mapping est entierement pre-rempli.
- **SC-002**: L'utilisateur peut importer un CSV au format actuel (`pac_kwh` unique) et lancer une simulation sans aucune action supplementaire par rapport au comportement actuel (retrocompatibilite).
- **SC-003**: L'explorateur de donnees affiche toutes les colonnes numeriques du CSV importe dans ses dropdowns.
- **SC-004**: Le temps entre l'import du CSV et le mapping pre-rempli ne depasse pas 2 secondes pour un fichier de 10 000 lignes.

## Assumptions

- Les CSV importes sont au pas de 15 minutes (pas de resampling).
- Les noms de colonnes des CSV reels suivent des conventions suffisamment explicites pour que le matching par mots-cles fonctionne dans la majorite des cas.
- Le mode Demo n'est pas impacte par cette feature.
- La validation de coherence des donnees (valeurs aberrantes, negatifs, trous) est hors scope.
- L'import de formats autres que CSV (Excel, Parquet) est hors scope.
