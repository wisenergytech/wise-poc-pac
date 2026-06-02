# Business Rules — Index global

Ce fichier centralise toutes les regles metier extraites des specs du projet. Chaque regle reference sa spec source pour la tracabilite.

**Derniere mise a jour**: 2026-05-26

---

## Spec 009 — Dual PAC Optimizer

Source : `specs/009-dual-pac-optimizer/business-logic.md`

| ID | Nom | Resume |
|----|-----|--------|
| BL-009-001 | Activation optionnelle de la seconde PAC | PAC 2 desactivee par defaut ; comportement mono-PAC inchange quand PAC 2 est inactive. |
| BL-009-002 | Configuration independante de chaque PAC | Chaque PAC se configure avec type (ASHP/GSHP), puissance, mode (on/off ou inverter), COP nominal. |
| BL-009-003 | Dispatch conjoint via un unique solveur | Quand PAC 2 est active, un seul probleme d'optimisation combine les deux PAC (contrainte ballon commun). |
| BL-009-004 | Modelisation COP differenciee par type | ASHP : COP(T_ext, T_ballon) ; GSHP : COP(T_sol, T_ballon). Evalue independamment a chaque pas de temps. |
| BL-009-005 | Lissage obligatoire pour PAC inverter | Variation de puissance bornee par ramp_max entre deux pas de temps consecutifs (montee et descente). |
| BL-009-006 | Raffinement iteratif des COP — deux passes | Les COP sont recalcules apres la premiere passe avec les temperatures de ballon resultantes, puis optimisation relancee. |
| BL-009-007 | Guard anti-regression | Le cout dual ne peut pas depasser le meilleur cout mono-PAC ; revert automatique si c'est le cas. |
| BL-009-008 | Format de sortie compatible avec l'existant | Resultats duaux augmentent le format existant de sim_pac1_on, sim_pac2_load, sim_pac1_kwh, sim_pac2_kwh. |
| BL-009-009 | Heritage BaseOptimizer | DualOptimizer herite de BaseOptimizer et surcharge uniquement solve_block(). |
| BL-009-010 | Extension modele thermique deux sources | Deux contributions thermiques (PAC 1 + PAC 2) sur un meme ballon a chaque pas de temps. |
| BL-009-011 | Proxy T_sol saisonnier | T_sol = T_annuelle_moy + 0.3 * (T_mensuelle_moy - T_annuelle_moy) quand aucune mesure n'est disponible. |
| BL-009-012 | Inalterable — solveurs existants | Les solveurs MILP, LP et QP mono-PAC existants ne sont pas modifies. |

---

## Spec 010 — CSV Column Mapping dynamique

Source : `specs/010-csv-column-mapping/business-logic.md`

| ID | Nom | Resume |
|----|-----|--------|
| BL-010-001 | Detection automatique des colonnes a l'import | A chaque import CSV, toutes les colonnes sont detectees et proposees dans les selecteurs avant toute action utilisateur. |
| BL-010-002 | Champs requis et champs optionnels | Requis : timestamp + au moins un champ energetique. Optionnels : PAC 1, PAC 2, t_ballon, t_sol, t_ext. Option "Non disponible" toujours presente. |
| BL-010-003 | Pre-suggestion par mots-cles | Matching insensible a la casse sur liste de mots-cles fixes ; les colonnes non reconnues laissent le selecteur vide. |
| BL-010-004 | Retrocompatibilite format natif | Colonnes au format natif (timestamp, pv_kwh, offtake_kwh, feedin_kwh) → mapping automatique sans intervention. |
| BL-010-005 | Validation du mapping avant simulation | Timestamp manquant ou champ numerique non numerique → simulation bloquee avec message d'erreur explicite. |
| BL-010-006 | Renommage interne transparent | Colonnes renommees en interne uniquement ; le CSV source n'est jamais modifie. |
| BL-010-007 | Configuration PAC liee au mapping | Les controles de configuration PAC (type, mode, puissance, COP) ne sont accessibles que si la colonne PAC correspondante est mappee. |
| BL-010-008 | Activation automatique du mode dual | Colonne mappee sur PAC 2 → pac2_active = TRUE et DualOptimizer utilise. Pas de mapping PAC 2 → mono-PAC. |
| BL-010-009 | Explorateur avec colonnes reelles | Dropdowns de l'explorateur proposent toutes les colonnes numeriques reelles du CSV + colonnes de simulation. Mode Demo inchange. |
| BL-010-010 | Reinitialisation au changement de CSV | Nouveau CSV → mapping reinitialise, pre-suggestions recalculees, configurations PAC effacees. |
| BL-010-011 | Unicite du mapping par champ cible | Une colonne source ne peut etre assignee qu'a un seul champ cible. |
