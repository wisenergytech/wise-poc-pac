# Feature Specification: Import à deux CSV avec détection automatique PAC et PV reconstitué

**Feature Branch**: `006-dual-csv-import`
**Created**: 2026-05-05
**Status**: Draft
**Input**: User description: "Import à deux CSV (Installation + ORES) avec détection automatique PAC et PV reconstitué"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Upload et jointure des deux CSV (Priority: P1)

L'utilisateur uploade deux fichiers séparés dans le sidebar : un CSV "Installation" (données monitoring PAC : consommation électrique, COP, température ballon) et un CSV "ORES" (compteur réseau : index cumulatifs soutirage et injection). L'application détecte automatiquement le pas de temps de chaque fichier, agrège au quart d'heure si nécessaire, convertit les index ORES en deltas, et joint les deux sources par timestamp. Un rapport d'import s'affiche avec le nombre de points, la couverture temporelle, et les éventuelles anomalies.

**Why this priority**: Sans la jointure des deux sources, rien d'autre ne fonctionne. C'est le fondement de toute la chaîne.

**Independent Test**: Uploader les deux CSV bruts de Profondeville (bq_k0001_raw.csv + bq_k0001_ores_raw.csv). Vérifier que l'app affiche un rapport d'import avec le nombre de quarts d'heure joints, la période couverte, et aucune erreur bloquante.

**Acceptance Scenarios**:

1. **Given** deux CSV valides au pas de 5 min couvrant la même période, **When** l'utilisateur uploade les deux fichiers, **Then** l'app affiche un rapport confirmant la jointure (ex: "12 500 quarts d'heure, 2025-11-20 → 2026-04-30") et passe à l'étape suivante.
2. **Given** un CSV installation au pas de 5 min et un CSV ORES au pas de 15 min, **When** l'utilisateur uploade les deux, **Then** l'app agrège le CSV installation à 15 min avant la jointure et affiche "Agrégation 5 min → 15 min appliquée".
3. **Given** deux CSV dont les périodes ne se recouvrent que partiellement, **When** l'utilisateur uploade les deux, **Then** l'app joint uniquement la période commune et affiche un warning indiquant les dates exclues.
4. **Given** un seul des deux fichiers uploadé, **When** l'utilisateur n'a pas encore chargé le second, **Then** l'app affiche un message invitant à charger le fichier manquant, sans erreur.

---

### User Story 2 - Détection automatique de la consommation PAC (Priority: P2)

Après la jointure, l'application identifie automatiquement la consommation électrique de la PAC en suivant une cascade de priorités : (a) colonnes GSHP_power/ASHP_power si présentes et non nulles, (b) colonne sous-compteur PAC dédiée si détectée, (c) heuristique COP/talon si COP disponible. L'utilisateur est informé de la méthode utilisée et des résultats (puissance PAC estimée, talon de l'installation).

**Why this priority**: Séparer la PAC du reste de l'installation est indispensable pour que la simulation d'optimisation ait un sens. Sans cette séparation, les KPIs de l'app sont faux.

**Independent Test**: Uploader les CSV de Profondeville (GSHP_power et ASHP_power à 0, COP disponible). Vérifier que l'app détecte le cas "heuristique COP", affiche la puissance PAC P95 estimée (~12-13 kW) et le talon (~2 kW).

**Acceptance Scenarios**:

1. **Given** un CSV installation avec GSHP_power et ASHP_power non nuls, **When** les données sont traitées, **Then** la conso PAC est calculée directement depuis ces colonnes et le rapport indique "PAC détectée via sous-compteur (GSHP + ASHP)".
2. **Given** un CSV installation avec GSHP_power/ASHP_power à 0 mais COP disponible, **When** les données sont traitées, **Then** l'heuristique talon est appliquée (talon = médiane quand COP=0, PAC pure = elec - talon quand COP>0) et le rapport affiche "PAC estimée par heuristique COP | P95 = XX kW | Talon = XX W".
3. **Given** un CSV installation sans colonnes GSHP/ASHP et sans COP, **When** les données sont traitées, **Then** un warning s'affiche "Impossible de séparer la consommation PAC du reste de l'installation" et l'app utilise Elec_consumption en totalité comme proxy.
4. **Given** un COP avec des valeurs aberrantes (> 7), **When** l'heuristique s'applique, **Then** les pas avec COP > 7 sont exclus du calcul PAC (traités comme anomalies de capteur).

---

### User Story 3 - PV reconstitué par bilan énergétique (Priority: P3)

L'application reconstitue automatiquement la production PV réelle à partir du bilan énergétique (PV = Elec_consumption - offtake + feedin). Le diagnostic de stabilité PV mensuel est exécuté. Si le PV est instable (mise en service progressive détectée), un warning propose à l'utilisateur soit de restreindre la période aux mois stables, soit d'utiliser le scaling Elia (avec un kWc à renseigner) en alternative.

**Why this priority**: Le PV reconstitué est nécessaire pour les KPIs d'autoconsommation et pour le simulateur d'optimisation, mais l'app peut fonctionner sans (en mode dégradé avec Elia scalé).

**Independent Test**: Uploader les CSV de Profondeville. Vérifier que le PV reconstitué est calculé, que le diagnostic détecte la mise en service progressive (CV > 30%), et qu'un warning propose de restreindre la période ou d'utiliser Elia.

**Acceptance Scenarios**:

1. **Given** des données jointes avec un bilan nocturne cohérent (écart < 0.05 kWh), **When** le PV est reconstitué, **Then** les valeurs négatives de pv_reel sont mises à 0 et le total PV reconstitué est affiché.
2. **Given** un PV reconstitué avec un coefficient de variation mensuel > 30%, **When** le diagnostic s'exécute, **Then** un warning s'affiche "PV instable : mise en service progressive détectée (ratio de X.XX à X.XX)" avec suggestion de restreindre la période.
3. **Given** un PV reconstitué instable, **When** l'utilisateur choisit le mode Elia, **Then** un champ kWc apparaît, et le PV Elia scalé remplace le PV reconstitué dans toute la simulation.
4. **Given** un PV reconstitué stable (CV < 30%), **When** le diagnostic s'exécute, **Then** le PV reconstitué est utilisé directement sans warning, avec un message de confirmation "PV reconstitué stable (ratio ≈ X.XX)".

---

### User Story 4 - Diagnostic énergétique complet (Priority: P4)

Le diagnostic énergétique (déjà implémenté dans fct_data_diagnostic.R) s'exécute après la jointure et la détection PAC. Il valide la cohérence du périmètre de mesure, le taux d'autoconsommation PV, la puissance PAC, et la stabilité PV. Les résultats sont affichés dans le rapport d'import sous forme de checklist visuelle (vert/orange/rouge).

**Why this priority**: Le diagnostic est un filet de sécurité qui aide l'utilisateur à comprendre ses données. L'app fonctionne sans, mais les résultats pourraient être erronés sans les warnings.

**Independent Test**: Uploader les CSV de Profondeville. Vérifier que les 4 diagnostics s'affichent correctement (périmètre OK, autocons ~0%, PAC P95 ~13 kW, PV instable).

**Acceptance Scenarios**:

1. **Given** des données jointes, **When** le diagnostic s'exécute, **Then** chaque test affiche un résultat visuel (vert = OK, orange = attention, rouge = problème) avec un message explicatif.
2. **Given** un écart nocturne médian > 0.05 kWh, **When** le test de périmètre s'exécute, **Then** un warning orange indique "Périmètres potentiellement différents" avec les métriques.

---

### Edge Cases

- Que se passe-t-il si les timestamps des deux CSV sont dans des fuseaux horaires différents ?
- Que se passe-t-il si l'index ORES décroît (retour compteur, remplacement compteur) ?
- Que se passe-t-il si le COP est à 0 sur toute la période (PAC jamais éteinte selon le capteur) ?
- Que se passe-t-il si Elec_consumption < offtake - feedin la nuit (PV reconstitué négatif) ?
- Que se passe-t-il si le pas de temps varie au sein d'un même fichier (données irrégulières) ?
- Que se passe-t-il si les colonnes ont des noms légèrement différents (majuscules, underscores) ?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Le sidebar DOIT afficher deux zones d'upload distinctes : "Données installation (monitoring PAC)" et "Données compteur ORES"
- **FR-002**: Le système DOIT détecter automatiquement le pas de temps de chaque CSV (5-min, 15-min, horaire) à partir des 10 premiers timestamps
- **FR-003**: Le système DOIT agréger les données au pas de 15 minutes si le pas natif est plus fin (somme pour les énergies/puissances, moyenne pour les températures et COP)
- **FR-004**: Le système DOIT convertir les index cumulatifs ORES en deltas par pas de temps (offtake_kwh = delta(Consumption_index), feedin_kwh = delta(Injection_index)), avec un plancher à 0 pour les deltas négatifs
- **FR-005**: Le système DOIT joindre les deux sources par timestamp (inner join sur la période commune)
- **FR-006**: Le système DOIT détecter la consommation PAC en suivant la cascade : (a) GSHP_power + ASHP_power si non nuls → (b) colonne sous-compteur dédiée → (c) heuristique COP/talon → (d) warning si aucune méthode applicable
- **FR-007**: L'heuristique COP DOIT calculer le talon comme la médiane de Elec_consumption quand COP = 0, et la PAC pure comme max(0, Elec_consumption - talon) quand COP > 0 et COP < 7
- **FR-008**: Le système DOIT reconstituer le PV réel par bilan énergétique : pv_reel = max(0, Elec_consumption - offtake_kwh + feedin_kwh)
- **FR-009**: Le système DOIT exécuter le diagnostic de stabilité PV (coefficient de variation mensuel du ratio pv_reel/pv_elia) et signaler une instabilité si CV > 30%
- **FR-010**: L'utilisateur DOIT pouvoir choisir entre PV reconstitué (défaut) et PV Elia scalé (avec champ kWc à renseigner) comme source PV pour la simulation
- **FR-011**: Le système DOIT afficher un rapport d'import complet après le traitement (points joints, période, méthode PAC utilisée, diagnostics énergétiques)
- **FR-012**: Le système DOIT valider la présence des colonnes obligatoires dans chaque CSV et afficher une erreur explicite si des colonnes manquent
- **FR-013**: Le système DOIT gérer les timestamps sans indication de fuseau en les interprétant comme Europe/Brussels par défaut

### Key Entities

- **Données Installation**: Séries temporelles du monitoring PAC (Elec_consumption, COP, T_tankUp, GSHP_power, ASHP_power, SP_tank, SP_supply). Représente la consommation totale de l'installation technique et l'état de la PAC.
- **Données ORES**: Séries temporelles du compteur réseau (index cumulatifs soutirage et injection). Représente les échanges avec le réseau électrique pour le même périmètre que l'installation.
- **Profil PAC estimé**: Série temporelle de la consommation électrique attribuée à la PAC seule (séparée du talon). Dérivée des données installation par l'une des méthodes de la cascade.
- **PV reconstitué**: Série temporelle de la production PV réelle, dérivée du bilan énergétique. Peut être remplacé par le PV Elia scalé si instable.
- **Diagnostic énergétique**: Ensemble de tests de cohérence (périmètre, autoconsommation, puissance PAC, stabilité PV) qui valident la qualité des données importées.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: L'utilisateur peut charger ses deux fichiers bruts et obtenir un jeu de données prêt à simuler en moins de 10 secondes (pour 50 000 lignes par fichier)
- **SC-002**: La puissance PAC P95 estimée par l'heuristique COP est cohérente avec la puissance nominale déclarée de l'installation (écart < 50%)
- **SC-003**: Le PV reconstitué par bilan énergétique est cohérent la nuit (valeurs nocturnes < 0.05 kWh dans 95% des cas après filtrage)
- **SC-004**: Le diagnostic détecte correctement une mise en service progressive du PV (coefficient de variation > 30% sur les données Profondeville)
- **SC-005**: L'utilisateur comprend quelle méthode de détection PAC a été utilisée et peut évaluer la fiabilité du résultat grâce au rapport d'import

## Assumptions

- Les deux CSV proviennent de la même installation (même périmètre de comptage) et couvrent une période commune
- Les timestamps sont en heure locale Europe/Brussels (pas d'indication de timezone dans les fichiers bruts)
- Le compteur ORES fournit des index cumulatifs croissants (sauf remplacement de compteur, traité comme edge case)
- L'ancien mode d'upload single-CSV est supprimé (pas de rétrocompatibilité)
- Le mode Démo de l'app (données synthétiques) reste inchangé
- Les colonnes optionnelles (SP_tank, SP_supply) ne sont pas bloquantes si absentes
- La colonne COP = 0 est un indicateur fiable de l'arrêt du compresseur PAC
- Le talon de l'installation (éclairage, auxiliaires) est relativement stable dans le temps (variabilité < facteur 2 entre jour et nuit)
