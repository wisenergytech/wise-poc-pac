# Dimensionnement automatique — Ballon et PV

Ce document decrit les formules de dimensionnement automatique utilisees
dans l'application PAC Optimizer quand les checkboxes "Auto" sont cochees.

---

## 1. Volume du ballon (mode Auto)

### Principe physique

Le ballon tampon stocke de l'energie thermique pour permettre a l'optimiseur
de decaler le fonctionnement de la PAC dans le temps (chauffer quand c'est
pas cher / quand le PV produit, consommer plus tard).

Le dimensionnement repond a la question : **quel volume faut-il pour stocker
N heures de production thermique de la PAC ?**

### Formule

```
volume_L = energie_thermique / (delta_T * capacite_specifique_eau)
```

Ou :

```
energie_thermique = P_pac * COP * heures_stockage     [kWh_th]
delta_T           = 2 * tolerance                       [°C]
capacite_specifique = 0.001163                          [kWh / (L * °C)]
heures_stockage   = 2                                   [h]
```

Resultat arrondi au 50 L le plus proche.

### Explication de chaque terme

**P_pac (kW)** : puissance electrique nominale de la PAC.

**COP** : coefficient de performance. Multiplie par P_pac, donne la
puissance thermique : `P_thermique = P_pac * COP`.

**heures_stockage = 2h** : on dimensionne le ballon pour stocker 2 heures
de production thermique a pleine charge. C'est un compromis :
- 1h serait trop court pour exploiter les creux de prix (le Belpex varie
  sur des plages de 2-4h)
- 4h donnerait un ballon enorme, couteux et avec plus de pertes

**delta_T** : la plage de temperature utilisable du ballon. Si la tolerance
est de 5°C (ex: consigne 50°C, plage 45-55°C), alors delta_T = 10°C.
C'est l'ecart entre T_min et T_max dans lequel le ballon peut osciller.

**0.001163 kWh/(L*°C)** : capacite thermique massique de l'eau.
1 litre d'eau chauffe de 1°C stocke 0.001163 kWh (= 4.186 kJ / 3600).

### Exemple detaille

PAC 20 kW, COP 3.5, tolerance 5°C :

```
Etape 1 : Puissance thermique
  P_th = 20 * 3.5 = 70 kW_th

Etape 2 : Energie a stocker (2h)
  E = 70 * 2 = 140 kWh_th

Etape 3 : Plage de temperature
  delta_T = 2 * 5 = 10°C

Etape 4 : Volume
  V = 140 / (10 * 0.001163) = 140 / 0.01163 = 12 038 L

Etape 5 : Arrondi
  V = arrondi(12038 / 50) * 50 = 12 050 L
```

### Tableau d'exemples

| PAC | COP | Tolerance | delta_T | E_th (kWh) | Volume auto |
|-----|-----|-----------|---------|------------|-------------|
| 2 kW | 3.5 | 5°C | 10°C | 14 kWh | 1 200 L |
| 5 kW | 3.5 | 5°C | 10°C | 35 kWh | 3 000 L |
| 10 kW | 3.5 | 5°C | 10°C | 70 kWh | 6 050 L |
| 20 kW | 3.5 | 5°C | 10°C | 140 kWh | 12 050 L |
| 60 kW | 3.5 | 5°C | 10°C | 420 kWh | 36 100 L |
| 20 kW | 3.5 | 3°C | 6°C | 140 kWh | 20 050 L |
| 20 kW | 4.0 | 5°C | 10°C | 160 kWh | 13 750 L |

On constate que le volume est tres sensible a la tolerance : une tolerance
de 3°C au lieu de 5°C augmente le volume de 66%.

### Informations derivees affichees

Le dashboard affiche aussi :

```
stockage_kwh_th = volume * 0.001163 * delta_T    [kWh thermiques]
stockage_kwh_e  = stockage_kwh_th / COP           [kWh electriques]
flexibilite_h   = stockage_kwh_th / (P_pac * COP) [heures]
```

Exemple (20 kW, COP 3.5, 12 050 L, delta_T 10°C) :

```
stockage    = 12050 * 0.001163 * 10 = 140.1 kWh_th (= 40.0 kWh_e)
flexibilite = 140.1 / (20 * 3.5) = 2.0 h
```

### Quand utiliser le mode manuel

- Si le volume reel du ballon est connu (donne constructeur)
- Si l'installation a un ballon surdimensionne (ex: 2 ballons en serie)
- Si le ballon sert aussi de tampon chauffage (volumes plus importants)

---

## 2. Puissance PV (mode Auto)

### Principe

Le PV est dimensionne pour **couvrir la consommation electrique annuelle
de la PAC**. Le modele utilise deux approches selon la taille de la PAC,
car les profils de consommation sont fondamentalement differents.

Le seuil est fixe a **10 kW** :
- **<= 10 kW** : PAC individuelle, typiquement ECS uniquement
- **> 10 kW** : PAC collective ou mixte (chauffage + ECS)

### Formule commune

```
kWc = consommation_PAC_annuelle / 950
```

Resultat arrondi au 0.5 kWc le plus proche.

**950 kWh/kWc/an** = production annuelle PV de reference en Belgique
(orientation sud, inclinaison 35°, source PVGIS). Tient compte de la
nebulosite moyenne belge (~1500 h de soleil/an).

### Modele petite PAC (<= 10 kW) — ECS detaille

```
consommation_annuelle = (ECS_jour + Pertes_jour) / COP * 365
```

Ou :

```
ECS_jour     = 6 * volume_ballon / 200     [kWh_th/jour]
Pertes_jour  = 0.004 * (T_consigne - 20) * 24  [kWh_th/jour]
COP          = COP_nominal (saisi par l'utilisateur)
```

**ECS_jour** : un menage type consomme ~150 L/jour d'eau chaude. Pour un
ballon de 200 L, cela represente ~6 kWh thermiques/jour (delta T de ~25°C
entre eau froide a 10°C et eau chaude a 55°C). Proportionnel au volume.

**Pertes_jour** : pertes thermiques du ballon par conductivite. Le
coefficient 0.004 est le meme que dans les optimiseurs et la baseline
(coherence du modele). `T_consigne - 20` = ecart entre le ballon et
la temperature ambiante du local technique (~20°C).

**Exemple** (PAC 5 kW, ballon 150 L, COP 3.5, consigne 50°C) :

```
Etape 1 : Besoins thermiques journaliers
  ECS     = 6 * 150/200 = 4.5 kWh_th/jour
  Pertes  = 0.004 * (50 - 20) * 24 = 2.88 kWh_th/jour
  Total   = 4.5 + 2.88 = 7.38 kWh_th/jour

Etape 2 : Consommation electrique annuelle
  Conso   = 7.38 / 3.5 * 365 = 770 kWh_e/an

Etape 3 : Dimensionnement PV
  kWc     = 770 / 950 = 0.81
  Arrondi = 1.0 kWc
```

### Tableau d'exemples (petite PAC)

| PAC | Ballon | COP | Consigne | ECS/j | Pertes/j | Conso/an | kWc auto |
|-----|--------|-----|----------|-------|----------|----------|----------|
| 2 kW | 50 L | 3.5 | 50°C | 1.5 kWh | 2.9 kWh | 458 kWh | 0.5 kWc |
| 2 kW | 200 L | 3.5 | 50°C | 6.0 kWh | 2.9 kWh | 928 kWh | 1.0 kWc |
| 5 kW | 150 L | 3.5 | 50°C | 4.5 kWh | 2.9 kWh | 773 kWh | 1.0 kWc |
| 10 kW | 250 L | 3.5 | 50°C | 7.5 kWh | 2.9 kWh | 1 085 kWh | 1.5 kWc |
| 5 kW | 150 L | 3.5 | 60°C | 4.5 kWh | 3.8 kWh | 869 kWh | 1.0 kWc |

On voit que la consigne a un impact modere : passer de 50°C a 60°C
augmente les pertes de ~1 kWh/j mais le PV reste le meme (arrondi).

### Modele grosse PAC (> 10 kW) — Heures equivalentes

```
consommation_annuelle = P_pac * Heq_jour * 365 / COP
```

Ou :

```
P_pac    = puissance electrique de la PAC (kW)
Heq_jour = 5 heures equivalentes pleine charge par jour
COP      = COP_nominal
```

**Pourquoi un modele different ?**

Une PAC > 10 kW dessert generalement plusieurs logements et/ou fait du
chauffage d'ambiance en plus de l'ECS. Le modele ECS detaille (base sur
le volume du ballon) sous-estime largement la consommation car il ne
prend pas en compte le chauffage.

**Pourquoi 5 heures/jour ?**

C'est une moyenne annuelle typique pour une PAC mixte (chauffage + ECS)
en climat belge :
- Hiver (dec-fev) : 8-12 h/jour (chauffage dominant)
- Mi-saison (mars-mai, sep-nov) : 4-6 h/jour
- Ete (juin-aout) : 2-3 h/jour (ECS uniquement)

**Exemple** (PAC 20 kW, COP 3.5) :

```
Etape 1 : Consommation annuelle
  Conso = 20 * 5 * 365 / 3.5 = 10 429 kWh_e/an

Etape 2 : Dimensionnement PV
  kWc   = 10429 / 950 = 10.98
  Arrondi = 11.0 kWc
```

### Tableau d'exemples (grosse PAC)

| PAC | COP | Heq/j | Conso/an | kWc auto |
|-----|-----|-------|----------|----------|
| 15 kW | 3.5 | 5h | 7 821 kWh | 8.5 kWc |
| 20 kW | 3.5 | 5h | 10 429 kWh | 11.0 kWc |
| 40 kW | 3.5 | 5h | 20 857 kWh | 22.0 kWc |
| 60 kW | 3.5 | 5h | 31 286 kWh | 33.0 kWc |
| 20+40 kW | 3.5 | 5h | 31 286 kWh | 33.0 kWc |

Le dernier exemple correspond a l'installation de Profondeville (2 PAC
de 20 et 40 kW en cascade, entree comme 60 kW dans le simulateur).

### Limites communes aux deux modeles

- Les 950 kWh/kWc/an supposent une orientation sud optimale.
  Est/ouest : -15%. Nord : -40%.
- Le COP moyen annuel est generalement inferieur au COP nominal
  (mesure a 7°C). En Belgique, compter 80-90% du nominal en moyenne.
- Le dimensionnement couvre la consommation PAC uniquement, pas la
  consommation du reste du batiment.

### Quand utiliser le mode manuel

- Si la puissance PV reelle est connue (installation existante)
- Si l'orientation des panneaux n'est pas optimale
- Si la PAC ne fait que du chauffage (pas d'ECS) ou inversement
- Pour tester differents scenarii de dimensionnement

---

## 3. Charge de chauffage d'ambiance (grosses PAC > 10 kW)

Pour les PAC > 10 kW, le generateur de donnees synthetiques ajoute
automatiquement une charge de **chauffage d'ambiance** en plus de l'ECS.

### Principe physique

Les deperditions thermiques d'un batiment sont proportionnelles a
l'ecart entre la temperature interieure et la temperature exterieure.
C'est la loi lineaire de deperdition :

```
Q_chauffage(t) = G * max(0, T_seuil - T_ext(t)) * dt_h     [kWh/qt]
```

### Explication de chaque terme

**G (kW/K)** : coefficient de deperdition global du batiment. Represente
la puissance thermique perdue par degre d'ecart interieur/exterieur.
Depend de l'isolation, de la surface, des fenetres, etc.

**T_seuil = 15°C** : seuil de chauffage. En-dessous de cette temperature
exterieure, le batiment a besoin de chauffage. On utilise 15°C (et non
20°C) car les apports gratuits compensent ~5°C :
- Apports internes : occupants, electromenager, eclairage (~3-5 W/m2)
- Apports solaires passifs (fenetres)

**T_ext(t)** : temperature exterieure reelle au quart d'heure t
(source : Open-Meteo, fichiers CSV locaux).

**dt_h = 0.25h** : pas de temps (15 minutes).

### Estimation de G a partir de la puissance PAC

Le coefficient G est inconnu en general. On le deduit de la puissance
de la PAC en supposant qu'elle est dimensionnee pour couvrir le besoin
a la **temperature de dimensionnement** (-5°C en Belgique) :

```
A T_dim = -5°C, la PAC doit fournir toute la puissance thermique :
  P_pac * COP = G * (T_seuil - T_dim)
  P_pac * COP = G * (15 - (-5))
  G = P_pac * COP / 20
```

**Exemple** (PAC 20 kW, COP 3.5) :

```
G = 20 * 3.5 / 20 = 3.5 kW/K
```

Cela signifie : pour chaque degre en-dessous de 15°C, le batiment perd
3.5 kW de chaleur.

### Calcul de la charge pour une journee

Journee d'hiver avec T_ext = 0°C (constante, pour simplifier) :

```
Q par quart d'heure = 3.5 * max(0, 15 - 0) * 0.25 = 3.5 * 15 * 0.25 = 13.1 kWh
Q par jour = 13.1 * 96 = ... non, c'est 3.5 * 15 * 24 = 1260 kWh/jour
      mais en kWh electrique : 1260 / COP = 1260 / 3.5 = 360 kWh_e/jour
```

Attendons — clarifions. La charge thermique par jour :

```
Q_th/jour = G * (T_seuil - T_ext) * 24 = 3.5 * 15 * 24 = 1260 kWh_th/jour
```

En electrique PAC :

```
Q_elec/jour = Q_th / COP = 1260 / 3.5 = 360 kWh_e/jour
```

Mais le simulateur additionne la charge de chauffage au champ
`soutirage_ecs_kwh` en kWh thermiques — c'est la demande que la PAC
doit satisfaire. La conversion en electrique est faite par le modele
thermique du ballon (via le COP).

### Tableau d'exemples

| PAC | G (kW/K) | T_ext = 0°C | T_ext = -5°C | T_ext = 10°C | T_ext = 18°C |
|-----|----------|-------------|-------------|-------------|-------------|
| 15 kW | 2.6 | 39 kWh_th/j | 52 kWh_th/j | 13 kWh_th/j | 0 |
| 20 kW | 3.5 | 53 kWh_th/j | 70 kWh_th/j | 18 kWh_th/j | 0 |
| 40 kW | 7.0 | 105 kWh_th/j | 140 kWh_th/j | 35 kWh_th/j | 0 |
| 60 kW | 10.5 | 158 kWh_th/j | 210 kWh_th/j | 53 kWh_th/j | 0 |

Les charges ci-dessus sont les charges de CHAUFFAGE seul. L'ECS s'y ajoute.
A T_ext >= 15°C, la charge de chauffage est nulle (seul l'ECS reste).

### Ordres de grandeur saisonniers (PAC 60 kW)

| Saison | T_ext moy | Chauffage/j | ECS/j | Total/j |
|--------|-----------|-------------|-------|---------|
| Janvier | ~3°C | ~2 520 kWh_th | ~45 kWh_th | ~2 565 kWh_th |
| Avril | ~10°C | ~500 kWh_th | ~45 kWh_th | ~545 kWh_th |
| Juillet | ~18°C | 0 | ~45 kWh_th | ~45 kWh_th |

En hiver, le chauffage represente >98% de la demande thermique.

### Source des temperatures

Les temperatures exterieures proviennent des fichiers CSV locaux
`data/openmeteo_temperature_YYYY.csv`, generes via l'API Open-Meteo
(historique horaire, localisation Profondeville, Belgique).

Les donnees horaires sont interpolees au quart d'heure via interpolation
lineaire (`interpolate_temperature_15min()` dans `R/openmeteo.R`).

Si les fichiers Open-Meteo ne sont pas disponibles, un modele sinusoidal
synthetique est utilise en fallback.

---

## 4. Resume des constantes

| Constante | Valeur | Source / justification |
|-----------|--------|----------------------|
| Capacite thermique eau | 0.001163 kWh/(L*°C) | Physique (4.186 kJ/(kg*K) / 3600) |
| Heures stockage ballon | 2 h | Compromis flexibilite/taille |
| Production PV Belgique | 950 kWh/kWc/an | PVGIS (sud, 35°, Wallonie) |
| ECS menage type | 6 kWh_th/jour pour 200 L | ~150 L/jour, delta 25°C |
| Coeff pertes ballon k | 0.004 kWh/(°C*qt) | Meme que optimiseurs (coherence modele) |
| Heq pleine charge PAC | 5 h/jour | Moyenne annuelle PAC mixte Belgique |
| T_seuil chauffage | 15°C | 20°C interieur - 5°C apports gratuits |
| T_dim Belgique | -5°C | Temperature de dimensionnement standard |
| Arrondi volume | 50 L | Standard industriel |
| Arrondi PV | 0.5 kWc | Pas des panneaux courants (~400 Wc) |
