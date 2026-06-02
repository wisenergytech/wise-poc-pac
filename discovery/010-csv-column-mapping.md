# Discovery: CSV Column Mapping dynamique

**Feature**: `010-csv-column-mapping`
**Created**: 2026-05-26

## Verbatim

> L'app doit pouvoir ingerer un CSV avec soit une soit deux PAC. L'utilisateur fait le mapping des colonnes via l'UI :
> - Colonne PAC 1 + sa config (type ASHP/GSHP, mode on-off/inverter, puissance, COP nominal)
> - Colonne PAC 2 (optionnelle) + sa config
> - Colonnes communes (timestamp, pv, offtake, feedin, t_ballon, t_sol, t_ext) avec des valeurs pre-suggerees basees sur les noms de colonnes du CSV importe
>
> L'explorateur de donnees (mod_comparaison) doit reprendre les noms de colonnes reels du CSV passe en input (pas des noms hardcodes) dans les dropdowns de la section CSV.

## Structured Understanding

### Contexte

Aujourd'hui, le mode CSV de l'app attend un format fixe avec des noms de colonnes hardcodes (`timestamp`, `pv_kwh`, `pac_kwh`, `offtake_kwh`, `feedin_kwh`, `t_ballon`, optionnellement `t_ext`). Le nouveau dataset dual PAC (`bq_k0001_dual_pac.csv`) a des colonnes separees pour chaque PAC (`gshp_kwh`, `ashp_kwh`) plus des colonnes supplementaires (`t_sol`, `cop_gshp`, `cop_ashp`). L'app ne sait pas les ingerer sans renommage manuel prealable.

De plus, l'explorateur de donnees (mod_comparaison) utilise des noms de variables hardcodes dans ses dropdowns. Quand un utilisateur importe un CSV avec des noms de colonnes differents, il ne peut pas les explorer.

### Probleme

L'utilisateur ne peut pas importer un CSV dont les colonnes ne correspondent pas exactement au format attendu, ni explorer ses propres colonnes dans l'interface. Il doit adapter manuellement son fichier au format rigide de l'app, ce qui est source d'erreurs et empeche l'utilisation directe de datasets reels (comme ceux issus de BigQuery).

### User Stories

#### US-1: Mapper les colonnes d'un CSV importe
En tant qu'utilisateur, je veux pouvoir associer chaque colonne de mon CSV aux champs attendus par l'app (timestamp, PV, offtake, feedin, PAC 1, PAC 2, temperatures) via des selecteurs dans le sidebar, afin de ne pas avoir a renommer manuellement mes colonnes avant import.

#### US-2: Pre-suggestion intelligente du mapping
En tant qu'utilisateur, je veux que l'app pre-remplisse le mapping en devinant les associations probables a partir des noms de colonnes de mon CSV (ex: une colonne nommee "gshp_kwh" est automatiquement suggeree pour PAC 1), afin de gagner du temps quand mes colonnes ont des noms explicites.

#### US-3: Configurer chaque PAC independamment
En tant qu'utilisateur, je veux pouvoir definir pour chaque PAC mappee son type (ASHP/GSHP), son mode (on/off ou inverter), sa puissance et son COP nominal, afin que l'optimiseur utilise les bons parametres pour chaque machine.

#### US-4: Explorer les colonnes reelles du CSV
En tant qu'utilisateur, je veux que l'explorateur de donnees (onglet Comparaison) propose dans ses dropdowns les noms de colonnes reels de mon CSV importe, afin de pouvoir visualiser n'importe quelle serie temporelle de mon fichier sans etre limite aux variables hardcodees.

### Scope

**In scope** :
- Interface de mapping colonnes dans le sidebar (selecteurs alimentes par les colonnes du CSV importe)
- Pre-suggestion du mapping basee sur les noms de colonnes (fuzzy matching ou regles simples)
- Configuration PAC 1 et PAC 2 (optionnelle) avec type, mode, puissance, COP
- Dropdowns de l'explorateur alimentes dynamiquement par les colonnes du CSV
- Retrocompatible avec le format CSV actuel (si les colonnes ont les noms attendus, le mapping est automatique)

**Out of scope** :
- Modification du mode Demo (qui genere ses propres donnees)
- Validation de coherence des donnees importees (ex: verifier que les kWh sont positifs)
- Import de formats autres que CSV (Excel, Parquet, API)
- Transformation des donnees (resampling, interpolation) — le CSV doit etre au pas 15 min

### Hypotheses a Valider
- Les noms de colonnes des CSV reels sont suffisamment explicites pour qu'un matching par mots-cles (pac, gshp, ashp, pv, offtake, feedin, temp, ballon, sol) fonctionne dans la majorite des cas.

### Open Questions
- Faut-il supporter le mapping de colonnes supplementaires arbitraires (ex: "humidity", "wind_speed") pour l'explorateur, ou seulement les colonnes mappees + les colonnes non mappees du CSV ?
