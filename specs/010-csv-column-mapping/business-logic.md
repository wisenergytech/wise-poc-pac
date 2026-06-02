# Business Logic: CSV Column Mapping dynamique

**Feature Branch**: `010-csv-column-mapping`
**Created**: 2026-05-26

## Core Business Rules

### BL-001: Detection automatique des colonnes a l'import
A chaque import de CSV, le systeme detecte l'integralite des noms de colonnes presentes dans le fichier et les rend disponibles dans les selecteurs de mapping. Cette detection se produit avant toute autre action utilisateur et ne requiert aucune intervention manuelle.

*Derive de FR-001 et US-1.*

### BL-002: Champs requis et champs optionnels
Les champs requis pour toute simulation sont : timestamp et au moins un champ energetique (PV ou offtake/feedin). Les champs optionnels sont : PAC 1, PAC 2, temperature ballon (t_ballon), temperature sol (t_sol), temperature exterieure (t_ext). Chaque selecteur de mapping propose toutes les colonnes du CSV plus une option explicite "Non disponible". La simulation ne peut pas demarrer si un champ requis n'est pas mappe.

*Derive de FR-002 et FR-005.*

### BL-003: Pre-suggestion par correspondance de mots-cles
A l'issue de la detection des colonnes, le systeme applique un matching par mots-cles (insensible a la casse) pour pre-remplir les selecteurs. Les regles de correspondance sont fixes et ordonnees par priorite decroissante :

| Mot-cle dans le nom de colonne | Champ cible |
|---|---|
| `timestamp`, `time`, `datetime`, `date` | timestamp |
| `pv`, `solar`, `photovoltaic` | PV |
| `offtake`, `soutirage`, `consumption`, `import`, `grid_import` | offtake |
| `feedin`, `injection`, `export`, `grid_export`, `intake` | feedin |
| `gshp`, `geo`, `geothermal`, `pac_301`, `pac_3` | PAC 1 (type GSHP pre-selectionne) |
| `ashp`, `aero`, `aerothermal`, `pac_501`, `pac_5` | PAC 2 (type ASHP pre-selectionne) |
| `pac`, `hp`, `heat_pump`, `heatpump` | PAC 1 (type non pre-selectionne) |
| `t_ballon`, `tank`, `buffer`, `t_tank` | temperature ballon |
| `t_sol`, `ground`, `borehole`, `soil` | temperature sol |
| `t_ext`, `outdoor`, `ambient`, `external` | temperature exterieure |
| `cop` avec prefixe `gshp` | COP de la PAC correspondant a PAC 1 si GSHP |
| `cop` avec prefixe `ashp` | COP de la PAC correspondant a PAC 2 si ASHP |

Si aucun mot-cle ne correspond pour un champ, le selecteur reste vide et l'utilisateur mappe manuellement.

*Derive de FR-003 et US-2.*

### BL-004: Retrocompatibilite avec le format natif
Si les colonnes du CSV correspondent exactement aux noms internes attendus (`timestamp`, `pv_kwh`, `offtake_kwh`, `feedin_kwh` ou `intake_kwh`), le mapping est considere complet et la simulation peut demarrer sans aucune action utilisateur. Ce comportement est non-negociable et ne doit provoquer aucune regression par rapport au comportement existant.

*Derive de FR-004 et SC-002.*

### BL-005: Validation du mapping avant simulation
Avant le lancement de toute simulation, le systeme verifie que : (a) le champ timestamp est mappe, (b) au moins un champ energetique est mappe. Si l'une de ces conditions n'est pas remplie, la simulation est bloquee et un message d'erreur identifie precisement le ou les champs manquants. La validation detecte egalement si une colonne mappee contient des valeurs non numeriques pour les champs numeriques, et bloque la simulation en consequence.

*Derive de FR-005 et edge cases.*

### BL-006: Renommage interne transparent
Une fois le mapping valide et la simulation lancee, le systeme renomme les colonnes sources vers les noms internes attendus. Ce renommage est strictement interne : le CSV original n'est jamais modifie. Les resultats produits par la simulation sont identiques a ceux obtenus avec un CSV au format natif.

*Derive de FR-003, acceptance scenario 3 de US-1.*

### BL-007: Configuration PAC liee au mapping
Des qu'une colonne est mappee sur PAC 1 ou PAC 2, les controles de configuration correspondants deviennent disponibles : type de source (ASHP/GSHP), mode de fonctionnement (on/off ou inverter), puissance thermique nominale (kWth), COP nominal. Ces controles ne sont accessibles que si la colonne PAC correspondante est effectivement mappee.

*Derive de FR-006 et US-3.*

### BL-008: Activation automatique du mode dual
Si et seulement si une colonne est mappee sur PAC 2, le mode dual est active automatiquement (pac2_active = TRUE) et le DualOptimizer est utilise pour la simulation. Si aucune colonne n'est mappee sur PAC 2, le mode mono-PAC reste actif.

*Derive de FR-007 et US-3, acceptance scenario 2 et 3.*

### BL-009: Explorateur de donnees avec colonnes reelles
L'explorateur de donnees propose dans ses dropdowns toutes les colonnes numeriques du CSV importe, avec leurs noms reels tels qu'ils apparaissent dans le fichier. Les colonnes generees par la simulation (sim_offtake, sim_t_ballon, etc.) sont ajoutees en complement. Ce comportement s'applique uniquement quand un CSV est charge ; en mode Demo, le comportement existant (variables hardcodees) est conserve.

*Derive de FR-008 et FR-009, US-4.*

### BL-010: Reinitialisation du mapping au changement de CSV
Quand l'utilisateur importe un nouveau CSV, le mapping precedent est integralement reinitialise : tous les selecteurs reviennent a l'etat vide, les pre-suggestions sont recalculees sur les colonnes du nouveau fichier, et toute configuration PAC associee a l'ancien mapping est effacee.

*Derive de FR-010 et edge case "changement de CSV".*

### BL-011: Unicite du mapping par champ cible
Une meme colonne source peut etre assignee a un seul champ cible. Si un CSV contient des colonnes avec des noms dupliques, chaque occurrence est presentee separement dans les selecteurs et l'utilisateur choisit laquelle utiliser. Il ne peut pas mapper deux colonnes sources differentes vers le meme champ cible simultanement.

*Derive de l'edge case "colonnes dupliquees" et du principe de coherence du mapping.*

## Business Invariants

- La simulation ne peut jamais demarrer si le champ timestamp n'est pas mappe.
- Le renommage interne des colonnes ne modifie jamais le fichier CSV source.
- Le comportement en mode Demo est identique a l'existant, independamment de toute evolution du mapping.
- Un CSV au format natif produit exactement les memes resultats avant et apres l'introduction du mapping dynamique (retrocompatibilite totale).
- Le mode dual n'est actif que si et seulement si une colonne PAC 2 est mappee.
- Le mapping est toujours reinitialise integralement lors d'un changement de CSV.

## State Transitions

### Cycle de vie du mapping

```
[CSV charge]
     |
     | Detection des colonnes
     v
[Colonnes detectees — selecteurs disponibles]
     |
     | Application du matching mots-cles
     v
[Pre-suggestions calculees]
     |
     +--[Format natif detecte]---> [Mapping complet automatique]
     |
     | Utilisateur confirme ou ajuste les selecteurs
     v
[Mapping soumis a validation]
     |
     +--[Champ requis manquant]---> [Erreur — simulation bloquee]
     +--[Colonne non numerique]---> [Erreur — simulation bloquee]
     |
     v
[Mapping valide — simulation autorisee]
     |
     | Lancement simulation
     v
[Renommage interne des colonnes]
     |
     v
[Simulation executee avec les noms internes]
```

### Activation du mode dual

```
[Mapping PAC 2 = vide]  -->  mode mono-PAC actif
[Mapping PAC 2 = colonne assignee]  -->  mode dual actif (pac2_active = TRUE)
[Changement de CSV]  -->  Mapping PAC 2 reinitialise  -->  mode mono-PAC par defaut
```
