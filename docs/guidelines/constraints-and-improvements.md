# Contraintes, violations et pistes d'amelioration

Ce document complete `optimization-modes.md` avec une analyse detaillee des
contraintes physiques et mathematiques, des cas de violation, et des voies
d'amelioration possibles.

## 1. Inventaire des contraintes

### 1.1 Contraintes thermiques

| Contrainte | Formule | Type | Appliquee dans |
|---|---|---|---|
| **Temperature min** | `T_bal[t] >= T_min` | Soft (MILP: slack + penalite 10 EUR/C) | MILP, LP, QP, Smart, Baseline |
| **Temperature max** | `T_bal[t] <= T_max` | Hard | MILP, LP, QP, Smart, Baseline |
| **Dynamique thermique** | `T[t] = (T[t-1] * (cap - k) + chaleur_pac + k * T_amb - ECS) / cap` | Hard (==) | MILP, LP, QP |
| **Relaxation ECS** | Si `ECS[t] > chaleur_pac[t]` alors `T_min_eff = T_min - 10` | Conditionnel | Tous |

**Parametres** :
- `cap` = volume_ballon_l * 0.001163 (kWh/C)
- `k_perte` = 0.004 * dt_h (coefficient de perte proportionnel)
- `T_amb` = 20 C (temperature ambiante fixe)
- `dt_h` = 0.25 (pas de 15 minutes)

### 1.2 Contraintes electriques

| Contrainte | Formule | Type | Appliquee dans |
|---|---|---|---|
| **Bilan energetique** | `PV + offtake (+decharge) = conso + PAC + injection (+charge)` | Hard (==) | MILP, LP, QP |
| **Non-negativite** | `offtake >= 0`, `injection >= 0` | Hard | MILP, LP, QP |
| **Puissance PAC** | MILP: `pac_on` in {0,1}. LP/QP: `pac_load` in [0,1] | Hard | MILP, LP, QP |

### 1.3 Contraintes batterie

| Contrainte | Formule | Type | Appliquee dans |
|---|---|---|---|
| **SOC min** | `SOC[t] >= batt_soc_min * batt_kwh` | Hard | MILP, LP, QP |
| **SOC max** | `SOC[t] <= batt_soc_max * batt_kwh` | Hard | MILP, LP, QP |
| **Puissance charge** | `charge[t] <= batt_kw * dt_h` | Hard | MILP, LP, QP |
| **Puissance decharge** | `decharge[t] <= batt_kw * dt_h` | Hard | MILP, LP, QP |
| **Dynamique SOC** | `SOC[t] = SOC[t-1] + charge * eff - decharge / eff` | Hard (==) | MILP, LP, QP |
| **Anti-simultaneite** | `charge[t] * decharge[t] = 0` | Hard (MILP), Non enforce (LP/QP) | MILP uniquement |

## 2. Violations possibles par algorithme

### 2.1 Baseline

**Mode reactif (thermostat pur)** :
- **T_min** : violation systematique. Le thermostat ne reagit qu'APRES que T
  descend sous T_min. Il y a toujours une fraction de quart d'heure de retard.
- **T_max** : violation possible si la PAC etait ON et que l'ECS est faible
  (aucune anticipation du depassement).
- Le thermostat est **aveugle** : il ne connait ni les prix Belpex, ni la
  production PV, ni les tirages ECS futurs. Il voit uniquement T_ballon.
- Le bilan electrique est correct par construction (loi physique, pas une
  decision de l'algorithme).

**Mode proactif** :
- Ajoute un look-ahead d'un pas : "si la PAC reste OFF, T tombera-t-elle sous
  T_min ?". Reduit les violations mais ne les elimine pas (look-ahead 1 seul pas,
  pas de prevision ECS).

### 2.2 Smart (rule-based)

- **T_min** : peut etre viole si l'ECS d'un quart d'heure depasse la capacite
  de chauffe de la PAC. C'est physiquement inevitable.
- **T_min** : le look-ahead est de ~2h (horizon_qt = 16). Si une chute de T
  se produit au-dela de l'horizon, elle ne sera pas anticipee.
- **Aucune garantie mathematique** d'optimalite ni de faisabilite. Les regles
  heuristiques couvrent les cas courants mais pas tous les cas limites.
- Un **filet de securite** empeche les economies negatives : si le Smart fait
  pire que la baseline, les resultats de la baseline sont substitues.

### 2.3 MILP

- **T_min** : **violation intentionnelle possible** via la variable slack avec
  penalite de 10 EUR/C par quart d'heure. Le solveur accepte de violer T_min
  si le cout de chauffer depasse 10 EUR/C (rare en pratique).
- **T_min** : relaxation automatique a T_min - 10 pendant les gros tirages
  ECS (quand la PAC ne peut pas physiquement compenser).
- **Tous les autres** : jamais violes. Les contraintes de bilan energetique,
  dynamique thermique, T_max et SOC sont hard (==, <=, >=). Si le solveur
  ne trouve pas de solution faisable, le tryCatch declenche un fallback Smart.
- **Bord de bloc** : chaque bloc de 4-24h est optimise independamment. L'etat
  final du bloc N est l'etat initial du bloc N+1. Si un bloc termine a T_min
  "juste", le bloc suivant n'a pas de marge.
- **Tolerance solveur** : violations de l'ordre de 1e-6 (bruit numerique).

### 2.4 LP

- Memes garanties que le MILP (memes contraintes hard).
- **Anti-simultaneite batterie** : NON enforcee. Charge et decharge simultanees
  possibles en theorie. En pratique, economiquement dissuade par le rendement
  `batt_eff < 1` (on perd de l'energie a charger et decharger simultanement).
  Si `batt_rendement = 100%`, le solveur POURRAIT charger et decharger en meme
  temps sans cout.

### 2.5 QP

- Memes que LP, plus :
- **T_min intra-bloc** : la contrainte `T_bal >= T_min` est **conditionnellement
  desactivee** quand `ECS > chaleur_pac` a un quart d'heure donne. T peut
  descendre librement sous T_min pendant ces periodes.
- **Economies negatives possibles** : les penalites de confort (w_comfort) et
  lissage (w_smooth) augmentent le cout de la solution. Avec des poids eleves,
  la facture QP peut depasser la facture baseline. Un filet de securite
  (guard_baseline) substitue la baseline si c'est le cas.

### 2.6 Resume

| Algo | T_min | T_max | SOC | Anti-simult. | Bilan | Eco. neg. |
|---|---|---|---|---|---|---|
| Baseline reactif | Viole | Viole | n/a | n/a | OK | n/a |
| Baseline proactif | Peut violer | Peut violer | n/a | n/a | OK | n/a |
| Smart | Peut violer | Rare | n/a | n/a | OK | Empeche (guard) |
| MILP | Slack (intentionnel) | Jamais | Jamais | Jamais | Jamais | Empeche (guard*) |
| LP | Slack (intentionnel) | Jamais | Jamais | Possible | Jamais | Empeche (guard*) |
| QP | Desactive si gros ECS | Jamais | Jamais | Possible | Jamais | Empeche (guard) |

## 3. Conditions declenchant des violations

1. **ECS > capacite PAC en 1 qt** — physiquement inevitable pour tous les
   algos. Un tirage de 4 kWh instantane fait chuter T de ~20 C dans un ballon
   de 200L. La PAC ne peut pas compenser dans le meme quart d'heure.

2. **Bord de bloc** — le bloc N optimise sans connaitre le bloc N+1. Si le
   bloc N termine a T_min, le bloc N+1 demarre sans marge.

3. **Desaccord modele/realite** — `soutirage_estime_kwh` est une estimation.
   Si l'ECS reel differe, le T reel diverge du T simule.

4. **Tolerances solveur** — violations de l'ordre de 1e-6. Notre onglet
   Contraintes peut les signaler, mais c'est du bruit numerique.

5. **Relaxation intentionnelle T_min - 10** — pendant les gros ECS, tous les
   algos acceptent T jusqu'a T_min - 10 C. C'est voulu (la PAC ne peut pas
   compenser instantanement), mais c'est une "violation" de la contrainte
   nominale.

## 4. Role de la baseline

La baseline represente un systeme **totalement aveugle** :
- Ne connait pas les prix Belpex
- Ne connait pas la production PV
- Ne connait pas les tirages ECS futurs
- Voit uniquement la temperature du ballon

Le bilan electrique (autoconsommation du PV) est correct physiquement : si la
PAC tourne en meme temps que le PV produit, le soutirage reseau est
mecaniquement reduit. La baseline "autoconsomme" **par accident** (coincidence
temporelle), pas par intelligence.

### Les 4 modes de baseline

| Mode | Decision | Connait le PV ? | Connait les prix ? | Autoconso typique |
|---|---|---|---|---|
| **Reactif** | T < T_min → ON, T > consigne → OFF | Non | Non | ~10-15% |
| **Programmateur** | PAC forcee 11h-15h, sinon reactif | Indirect (l'installateur sait) | Non | ~40-50% |
| **Surplus PV** | PAC ON quand surplus > 50% P_pac, sinon reactif | Oui (capteur onduleur) | Non | ~50-70% |
| **Proactif** | Reactif + anticipation 1 pas (T tomberait sous T_min ?) | Non | Non | ~15-20% |

**Reactif** : thermostat classique des annees 80. Pire cas, gains affiches
maximaux mais peu realistes pour une installation recente avec PV.

**Programmateur** : l'installateur a regle "chauffer entre 11h et 15h".
Tres courant. Le plus realiste pour un client typique avec PV et un
installateur competent.

**Surplus PV** : onduleur avec sortie surplus (Fronius, SMA, Huawei).
Represente un client qui a investi dans un boitier de gestion basique.
Bonne autoconsommation sans aucune optimisation de prix.

**Proactif** : thermostat intelligent qui anticipe les chutes de T.
Avantage la baseline, gains affiches minimaux.

Le choix de baseline est critique pour la credibilite des resultats.
Recommandation : demander au client quel mode correspond a son installation
actuelle.

## 5. Filets de securite

Deux mecanismes empechent d'afficher des economies negatives :

### guard_baseline (tous les modes)

```r
guard_baseline <- function(sim, df_prep, p, mode_label) {
  facture_baseline <- sum(df_prep$offtake_kwh * df_prep$prix_offtake - ...)
  facture_opti <- sum(sim$sim_offtake * sim$prix_offtake - ...)
  if (facture_opti > facture_baseline) {
    # Substituer les resultats par la baseline
    sim$sim_offtake <- df_prep$offtake_kwh
    ...
  }
}
```

Applique a : **MILP**, **LP**, **QP** et **Smart**.

**Pourquoi MILP et LP aussi ?** Depuis l'introduction de `COP(T_ext, T_ballon)`,
la baseline et les optimiseurs utilisent des modeles COP differents :
- Baseline/Smart : `COP(T_ext, T_ballon_reel)` — varie a chaque pas
- Optimiseurs : `COP(T_ext, T_consigne)` — linearise (fixe)

La baseline reactive cycle entre T_min et T_consigne, donc elle beneficie
d'un COP moyen meilleur (ballon plus froid = COP plus eleve). Cette asymetrie
casse la garantie mathematique "l'optimum ne peut pas etre pire qu'une
solution faisable" car la baseline n'est plus une solution faisable du
probleme de l'optimiseur (equations thermiques differentes).

Le guard_baseline est donc necessaire pour les 4 modes.

### Fallback erreur (MILP, LP, QP)

Si le solveur retourne une erreur ou un probleme infaisable, un fallback
vers le Smart est active automatiquement.

## 6. Pistes d'amelioration

### 6.1 COP variable avec T_ballon (IMPLEMENTE)

**Etat actuel** : `COP = f(T_ext)` uniquement.

**Amelioration implementee** : `COP = f(T_ext, T_ballon)`. Le COP diminue de
1% par degre au-dessus de T_ballon_ref (50 C) :

```
COP = (COP_nominal + 0.1 * (T_ext - T_ref)) * (1 - 0.01 * (T_ballon - 50))
```

Exemples pour COP_nominal = 3.5, T_ext = 7 C :
- T_ballon = 45 C → COP = 3.68 (+5%)
- T_ballon = 50 C → COP = 3.50 (reference)
- T_ballon = 55 C → COP = 3.33 (-5%)

**Application** :
- Baseline et Smart : COP calcule avec le T_ballon reel a chaque pas
  (simulation sequentielle, T connu). La baseline est penalisee car elle
  maintient le ballon en haut de la plage (cycle consigne/T_min).
- Optimiseurs MILP/LP/QP : COP linearise autour de T_consigne (T_ballon
  est une variable de decision, un COP variable rendrait le probleme
  non-lineaire).

### 6.2 Blocs chevauchants (IMPLEMENTE)

**Etat actuel** : blocs disjoints [0-4h][4-8h][8-12h].

**Amelioration implementee** : blocs chevauchants. Chaque bloc est etendu
avec les donnees du bloc suivant comme lookahead. L'optimiseur resout le
bloc etendu (ex: 8h) mais ne garde que la premiere moitie (4h) :

```
Bloc 1 : optimise [0-8h], execute [0-4h], jette [4-8h]
Bloc 2 : optimise [4-12h], execute [4-8h], jette [8-12h]
Bloc 3 : optimise [8-16h], execute [8-12h], jette [12-16h]
...
```

**Avantages** :
- Le bloc voit les prix et le PV du bloc suivant → decisions mieux informees
- Plus besoin de valeur terminale (le lookahead la remplace naturellement)
- Equivalent a un MPC offline : re-optimise avec de l'info fraiche a chaque bloc

**Cout** : double la taille du probleme par bloc. Pour LP/QP (polynomials),
l'impact est negligeable. Pour MILP (NP-hard), le temps de calcul peut
augmenter significativement avec des blocs de base > 12h.

**Applique a** : MILP, LP et QP.

### 6.3 Valeur terminale (IMPLEMENTE)

**Note** : la valeur terminale (implementee precedemment) est desormais
rendue caduque par les blocs chevauchants qui fournissent un lookahead
naturel. Le coefficient `prix_terminal_per_deg` est mis a 0 dans les trois
optimiseurs. Le mecanisme reste en place et peut etre reactive si les blocs
chevauchants sont desactives (ex: pour le dernier bloc qui n'a pas de
lookahead, ou si le doublement du temps de calcul est problematique).

Cela evite les effets de bord
ou le bloc N "vide" le ballon sans considerer les besoins du bloc N+1.

### 6.3 Prediction des tirages ECS

**Etat actuel** : ECS historique/estime utilise tel quel (prevision parfaite
en simulation).
**Amelioration** : apprendre les patterns typiques (douche 7h, vaisselle 19h)
a partir de l'historique et pre-chauffer en anticipation. Critique pour un
deploiement temps reel ou l'ECS futur est inconnu.

### 6.4 Valeur terminale (IMPLEMENTE)

**Etat actuel** : chaque bloc se terminait sans incitation a garder le ballon
chaud. Le dernier quart d'heure "vidait" souvent le ballon a T_min car il
n'y avait aucun cout associe a cette perte d'energie stockee.

**Amelioration implementee** : un terme de valeur terminale est soustrait de
l'objectif de chaque bloc (sauf le dernier) :

```
Objectif = cout_electricite + penalite_slack - T_bal[n] * prix_terminal_per_deg
```

Ou `prix_terminal_per_deg` represente le cout qu'aurait le bloc suivant pour
rechauffer le ballon de 1 C :

```
prix_terminal_per_deg = capacite_kwh_par_degre / COP_moyen * prix_offtake_moyen_bloc_suivant
```

**Effet** : l'optimiseur garde le ballon plus chaud en fin de bloc quand les
prix du bloc suivant sont eleves (pre-stockage intelligent). Il le laisse
tomber si les prix suivants sont bas (pas de cout a rechauffer).

**Applique a** : MILP, LP et QP (meme formule dans les trois).

### 6.5 Model Predictive Control (MPC)

**Etat actuel** : optimisation one-shot sur toute la periode (offline).
**Amelioration** : boucle de controle en temps reel :
1. Optimiser sur un horizon glissant (ex: 24h)
2. Executer les 15 premieres minutes
3. Re-optimiser avec les nouvelles mesures (T reel, PV reel, prix actualises)
4. Repeter

Le MPC absorbe naturellement les erreurs de prediction et s'adapte aux
conditions reelles.

### 6.6 Contrainte Belpex : architecture de deploiement reel

Les prix Belpex day-ahead sont publies a **13h pour le lendemain** (00h-24h).
Cela impose une architecture a deux etages :

**Etage 1 — Planification globale (13h, quotidien)** :
- Declenchee a la publication des prix J+1
- Optimise sur une fenetre de 12-36h avec prix reels
- Produit un profil PAC "planifie" pour les prochaines heures

**Etage 2 — MPC court terme (toutes les 15 min)** :
- Re-optimise les 2-4h suivantes avec les mesures reelles
  (T_ballon, PV, prix connus)
- Utilise le profil planifie comme guide
- Corrige les ecarts (ECS imprevu, nuage, erreur de prevision)

**Prevision pour la zone inconnue** (au-dela de la fenetre Belpex) :
- Naif : profil de prix moyen historique par heure (semaine/weekend)
- Saisonnier : meme jour, semaine precedente
- PV : prevision meteo Open-Meteo a 7 jours

```
13h00 : Prix J+1 publies
  +-- Optimisation globale 13h -> J+1 24h (36h, prix reels)
  |     +-- Profil PAC "planifie"
  |
Chaque 15 min : MPC court terme
  +-- Re-optimise 2-4h avec T_ballon reel, PV reel, prix reels
  +-- Execute les 15 prochaines minutes
  +-- Corrige les ecarts
```

**Note** : en simulation offline (notre cas actuel), tous les prix sont connus
a l'avance. Le MPC et l'architecture Belpex n'apportent rien en simulation
mais sont essentiels pour un deploiement reel.

### 6.7 Modele thermique enrichi

**Etat actuel** : modele lineaire proportionnel (pertes = k * dt).
**Ameliorations possibles** :
- Stratification du ballon (eau chaude en haut, froide en bas)
- Pertes dans les tuyaux (entre PAC et ballon)
- Dynamique de montee en temperature de la PAC (inertie compresseur)
- Effet de la temperature de retour sur le COP

### 6.8 Cout de cyclage

**Etat actuel** : ni la PAC ni la batterie n'ont de cout de cyclage dans
l'objectif.
**Amelioration** : ajouter un cout de degradation par cycle batterie
(~0.05-0.15 EUR/cycle) et une penalite pour les changements ON/OFF
frequents de la PAC. Le QP avec poids lissage adresse partiellement ce
point mais de facon heuristique.

### 6.9 Tarification avancee

**Etat actuel** : prix soutirage fixe ou spot, prix injection proportionnel.
**Ameliorations possibles** :
- Tarifs bi-horaires (heures pleines/creuses)
- Capacite tarifaire (pointe quart-horaire facturee)
- Peak shaving (ecretage de pointe via batterie/PAC)

### 6.10 Multi-objectif

**Etat actuel** : mono-objectif (minimiser le cout, ou cout + confort en QP).
**Ameliorations possibles** :
- Optimiser simultanement cout, confort et autoconsommation
- Empreinte carbone (intensite CO2 du grid varie dans le temps)
- Front de Pareto montrant les compromis

### 6.11 Note sur la reformulation de l'objectif

Reformuler de "minimiser le cout" a "maximiser les economies" ne change **rien**
mathematiquement. La facture baseline est une constante (calculee avant
l'optimisation, independante des variables de decision). Soustraire une
constante de la fonction objectif ne change pas l'optimum :

```
max (C - f(x))  ≡  min f(x)
```

## 7. Dimensionnement du ballon et impact sur les economies

### 7.1 Le ratio stockage/puissance : facteur limitant n°1

L'economie maximale theorique depend directement de la capacite de stockage
thermique du ballon, qui determine combien de temps l'optimiseur peut decaler
la consommation vers les periodes moins cheres :

```
Economie_max = Capacite_stockage_elec × Ecart_prix × Nb_cycles/jour × Nb_jours
```

La capacite de stockage electrique equivalente est :

```
Cap_elec = Volume × 0.001163 × (2 × tolerance) / COP     [kWh_e]
```

Et la flexibilite temporelle (heures de decalage possible) :

```
Flex_heures = Cap_elec / P_pac     [h]
```

### 7.2 Exemple : PAC 60 kW avec ancien vs nouveau dimensionnement

| | Ancien (25 L/kW) | Nouveau (2h de stockage) |
|---|---|---|
| Volume | 1 500 L | 36 100 L |
| Stockage thermique | 17.4 kWh_th | 420 kWh_th |
| Stockage electrique | 5 kWh_e | 120 kWh_e |
| Flexibilite | ~5 min | 2h |
| Eco. max theorique (60j, spot) | ~120 EUR | ~2 880 EUR |

Avec le ballon de 1 500 L, l'optimiseur ne peut decaler que 5 minutes de
chauffage. L'essentiel du potentiel d'economie est inaccessible.

### 7.3 Formule du dimensionnement automatique

Le mode auto calcule le volume necessaire pour stocker 2h de chaleur PAC
dans la plage de tolerance :

```
V_auto = P_pac × COP × 2h / (2 × tolerance × 0.001163)
```

Parametres :
- `P_pac` : puissance electrique de la PAC (kW)
- `COP` : coefficient de performance nominal
- `2h` : duree de flexibilite cible (permet de couvrir un cycle prix haut
  typique ou d'exploiter le pic PV de midi a 14h)
- `2 × tolerance` : plage de temperature exploitable (T_min a T_max)
- `0.001163` : capacite calorifique de l'eau (kWh / L / C)

### 7.4 Leviers pour maximiser les economies

Par ordre d'impact :

1. **Volume du ballon** — c'est la batterie thermique. Dimensionner pour 2h
   de stockage (mode auto) au lieu de 25 L/kW.

2. **Tolerance de temperature** — passer de +/-5C a +/-10C double la capacite
   du meme ballon. C'est gratuit si le process le permet.

3. **Batterie electrique** — ajoute du stockage electrique en complement du
   stockage thermique. Particulierement utile quand le ballon est a sa taille
   max physique.

4. **Contrat dynamique** — plus les prix varient, plus le gain par kWh decale
   est important. En contrat fixe, seul le gain d'autoconsommation PV compte.

5. **Blocs d'optimisation longs** — un bloc de 24h peut decider de pre-chauffer
   le matin pour eviter le pic de 18h. Un bloc de 4h ne voit pas cette
   opportunite.

6. **PV correctement dimensionne** — assez de surplus pour remplir le ballon
   pendant les heures de production gratuite.

## 8. Ameliorations complementaires (IMPLEMENTEES)

### 8.1 Valeur terminale sur le dernier bloc

Le dernier bloc n'a pas de lookahead (pas de donnees au-dela). Sans valeur
terminale, l'optimiseur vide le ballon a T_min en fin de simulation (aucun
cout associe a la perte d'energie stockee).

**Fix** : pour le dernier bloc uniquement (`i_lookahead_end == i_end`), la
valeur terminale est calculee avec le prix moyen du bloc lui-meme :

```
prix_terminal_per_deg = capacite_kwh_par_degre / COP_moyen * prix_offtake_moyen
```

Les blocs intermediaires continuent a utiliser le lookahead (overlap).

### 8.2 Anti-simultaneite batterie LP/QP

Le MILP utilise une variable binaire `batt_ch[t]` pour empecher charge et
decharge simultanees. Le LP et QP n'avaient aucune contrainte equivalente.

**Fix** : ajout d'une relaxation lineaire dans LP et QP :

```
charge[t] + decharge[t] <= batt_pw
```

Cela empeche de charger et decharger a pleine puissance simultanement.
Ce n'est pas aussi strict que la contrainte binaire du MILP (charge partielle
+ decharge partielle reste possible) mais elimine les cas abusifs.

### 8.3 Penalite slack configurable

La penalite de violation de T_min etait fixee a 10 EUR/C dans le code.

**Fix** : slider dans l'UI (visible pour MILP et LP), valeur par defaut
2.5 EUR/C. Une penalite plus basse permet a l'optimiseur d'explorer des
temperatures proches de T_min ou le COP est meilleur, augmentant les economies.
Une penalite trop basse risque de causer des violations de confort.

### 8.4 COP iteratif

Les optimiseurs linearisent le COP autour de T_consigne. Mais la solution
optimale peut maintenir le ballon a des temperatures differentes.

**Fix** : boucle de 2 iterations dans chaque optimiseur :
1. Resoudre avec COP linearise a T_consigne
2. Extraire la trajectoire T_ballon de la solution
3. Recalculer COP(T_ext, T_ballon_resolu) → `cop_override`
4. Re-resoudre avec le COP corrige

Le COP de la 2e iteration reflete mieux la realite. L'optimiseur exploite
le gain de COP aux temperatures basses.

### 8.5 ECS parametre utilisateur

Le soutirage ECS etait calcule automatiquement (`p_pac_kw / 2 * reference`).
Pour des installations specifiques, cette estimation peut etre fausse.

**Fix** : champ `numericInput` dans la sidebar permettant de specifier la
demande ECS en kWh_th/jour. Si vide, l'estimation automatique est utilisee.

### 8.6 Type de batiment pour le chauffage

Le coefficient de deperdition thermique G etait derive automatiquement de
la puissance PAC. Pour une meme puissance, un batiment passif et un batiment
ancien ont des charges tres differentes.

**Fix** : selecteur "Type de batiment" (visible pour PAC > 10 kW) avec
trois profils :
- Passif (G × 0.4) : tres bien isole
- Standard RT2012 (G × 1.0) : construction recente
- Ancien (G × 1.8) : peu isole

### 8.7 Export CSV

Bouton "Exporter CSV" disponible apres simulation. Exporte le dataframe
filtre avec colonnes baseline et optimisees :
- timestamp, t_ext, pv_kwh, prix_offtake, prix_injection
- conso_hors_pac, soutirage_estime_kwh
- t_ballon_baseline, offtake_baseline, injection_baseline
- t_ballon_opti, offtake_opti, injection_opti
- pac_on_opti, cop_opti, decision
- batt_soc, batt_flux (si batterie active)

### 8.8 Comparaison cote-a-cote des modes (A FAIRE)

Lancer Smart + LP + MILP sur les memes donnees et afficher les 3 courbes
sur le meme graphique. Permet de voir visuellement quel mode fait quoi.
Non implemente — necessite une refonte UI significative.

### 8.9 Scaling ECS corrige

L'ECS etait proportionnel au volume du ballon (`volume / 200`). Avec le
nouveau dimensionnement auto (36 100 L pour 60 kW), le facteur devenait
180× — absurde. Les blocs d'optimisation devenaient infaisables.

**Fix** : l'ECS scale desormais avec la puissance PAC (`p_pac_kw / 2`).
Le volume du ballon est un choix de stockage, pas un indicateur de demande.

## 9. Timeseries de verification (A IMPLEMENTER)

Liste des timeseries necessaires pour verifier le respect des contraintes
et la validite physique de l'optimisation. Classees par priorite.

### 9.1 Verification des contraintes

**#1 — Marge temperature vs bornes** (CRITIQUE)

```
marge_min[t] = T_ballon[t] - T_min
marge_max[t] = T_max - T_ballon[t]
```

Afficher les marges plutot que T brut. Violations = marge negative.
Distinguer :
- Violations physiques (ECS > capacite PAC, inevitables)
- Violations slack (optimiseur a choisi de violer, cout < penalite)
- Violations numeriques (bruit solveur ~1e-6)

**#2 — SOC batterie : coherence flux vs stock** (UTILE)

```
residu_soc[t] = SOC[t] - SOC[t-1] - charge[t] * η + decharge[t] / η
```

Doit etre ~0 a chaque qt. Si non nul → incoherence modele batterie.

**#3 — Charge + decharge simultanees** (UTILE)

```
simult[t] = min(charge[t], decharge[t])
```

Doit etre ~0 partout. Si > 0 → anti-simultaneite violee (LP/QP).

### 9.2 Verification physique (lois de conservation)

**#4 — Bilan electrique : residu** (CRITIQUE)

```
residu[t] = PV + offtake - conso_hors_pac - PAC_elec - injection (± batterie)
```

Doit etre **exactement 0** a chaque qt. Tout ecart = bug comptable.
C'est la loi de conservation de l'energie electrique.

**#5 — Bilan thermique : residu** (CRITIQUE)

```
residu[t] = T[t] - ( T[t-1] * (cap-k)/cap + chaleur_PAC/cap + k*T_amb/cap - ECS/cap )
```

Doit etre ~0 a chaque qt. Un ecart signale une incoherence entre la
trajectoire T et le modele thermique. En mode COP iteratif, un petit
residu est attendu (COP solve 2 ≠ solve 1).

**#6 — Conservation energie totale sur la periode** (HAUTE)

```
Entrant  = sum(PV) + sum(offtake)
Sortant  = sum(injection) + sum(conso_hors_pac) + sum(pertes_thermiques)
Stock    = ΔT_ballon * cap / COP + ΔSOC_batterie
Residu   = Entrant - Sortant - Stock
```

Doit etre ~0 sur la periode complete.

### 9.3 Verification de la coherence economique

**#7 — Prix effectif du kWh thermique** (HAUTE)

```
prix_th[t] = (offtake[t] * prix_offtake[t] - injection[t] * prix_injection[t]) / chaleur_PAC[t]
```

Quand la PAC est ON. Montre a quel prix l'optimiseur chauffe. Les valeurs
doivent etre concentrees aux heures creuses/PV. Des pics de prix thermique
= opportunites manquees.

**#8 — Cout marginal baseline vs optimiseur** (DIAGNOSTIC)

Comparer le prix effectif du kWh thermique entre baseline et optimiseur,
heure par heure. L'optimiseur devrait systematiquement chauffer moins cher.
Les qt ou la baseline chauffe moins cher sont des anomalies a investiguer.

### 9.4 Verification de la validite monde reel

**#9 — Puissance PAC vs capacite physique** (MOYENNE)

```
puissance[t] = pac_load[t] * P_pac_kw
```

Doit etre <= P_pac_kw a chaque qt. Pour le MILP (binaire), puissance = 0
ou P_pac_kw. Pour LP/QP, verifier pac_load ∈ [0, 1]. Des valeurs hors
bornes = bug solveur.

**#10 — Taux de variation de T_ballon** (MOYENNE)

```
dT_dt[t] = (T[t] - T[t-1]) / dt_h    [C/h]
```

Borne physique haute : chaleur_PAC_max / cap. Borne basse :
-(ECS_max + pertes_max) / cap. Des variations extremes signalent un
modele irrealiste ou des ECS synthetiques aberrants.

**#11 — COP realise vs COP theorique** (DIAGNOSTIC)

```
COP_realise = chaleur_PAC_effective / elec_PAC
COP_theorique = calc_cop(T_ext, T_ballon)
```

Si ca diverge → incoherence modele COP.

**#12 — Autoconsommation PV reelle** (UTILE)

```
autoconso[t] = min(PV[t], conso_totale[t])
pct = sum(autoconso) / sum(PV)
```

Comparer baseline vs optimiseur. L'optimiseur devrait augmenter
l'autoconsommation (PAC vers heures PV). Si non → l'optimiseur
privilegie le prix spot, ce qui peut etre correct en dynamique mais
suspect en fixe.

### 9.5 Resume des priorites

| Priorite | # | Timeserie | Verifie |
|---|---|---|---|
| CRITIQUE | 4 | Bilan electrique residu | Conservation energie |
| CRITIQUE | 5 | Bilan thermique residu | Coherence modele thermique |
| HAUTE | 1 | Marge T_min / T_max | Respect contraintes confort |
| HAUTE | 7 | Prix effectif kWh thermique | Qualite de l'optimisation |
| MOYENNE | 9 | Puissance PAC vs capacite | Faisabilite physique |
| MOYENNE | 10 | dT/dt taux de variation | Realisme physique |
| UTILE | 2 | SOC residu | Coherence batterie |
| UTILE | 12 | Autoconsommation PV | Strategie PV |
| DIAGNOSTIC | 8 | Prix marginal baseline vs opti | Anomalies optimisation |
| DIAGNOSTIC | 11 | COP realise vs theorique | Coherence modele COP |

Les #4 et #5 sont les "smoke tests" — si ceux-la echouent, tout le reste
est suspect. Les #1 et #7 sont les plus utiles pour evaluer la qualite
de l'optimisation au quotidien.
