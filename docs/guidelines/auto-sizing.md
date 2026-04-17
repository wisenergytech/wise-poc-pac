# Dimensionnement automatique — Ballon et PV

Ce document decrit les formules de dimensionnement automatique utilisees
dans l'application PAC Optimizer quand les checkboxes "Auto" sont cochees.

## Volume du ballon (25 L/kW)

### Formule

```
Volume (L) = P_pac (kW) x 25, arrondi au 50 L le plus proche
```

### Justification

La regle de 20-30 L/kW est une pratique courante dans l'industrie pour
les ballons tampons de pompe a chaleur. On utilise 25 L/kW comme compromis.

### Exemples

| PAC | Volume auto |
|-----|-------------|
| 2 kW | 50 L |
| 5 kW | 150 L |
| 10 kW | 250 L |
| 20 kW | 500 L |
| 60 kW | 1500 L |

### Quand utiliser le mode manuel

- Si le volume reel du ballon est connu (donne constructeur)
- Si l'installation a un ballon surdimensionne (ex: 2 ballons en serie)
- Si le ballon sert aussi de tampon chauffage (volumes plus importants)

## Puissance PV (couvre la consommation PAC)

Le modele de dimensionnement PV utilise **deux formules** selon la taille
de la PAC, car les profils de consommation sont fondamentalement differents.

Le seuil est fixe a **10 kW** :
- **<= 10 kW** : PAC individuelle, typiquement ECS uniquement
- **> 10 kW** : PAC collective ou mixte (chauffage + ECS)

### Modele petite PAC (<= 10 kW) — ECS detaille

```
kWc = Consommation_PAC_annuelle / 950

ou :
  Consommation_PAC_annuelle = (ECS_jour + Pertes_jour) / COP_moyen x 365
  ECS_jour = 6 kWh/jour x (Volume_ballon / 200)
  Pertes_jour = 0.004 x (T_consigne - 20) x 24  [kWh/jour]
  COP_moyen = COP_nominal (saisi par l'utilisateur)
  950 = production annuelle en Belgique (kWh/kWc/an)
```

**Decomposition :**

1. **ECS journalier** : un menage type consomme ~150 L/jour d'eau chaude.
   Pour un ballon de 200 L, cela represente ~6 kWh thermiques/jour
   (delta T de ~25 C entre eau froide et eau chaude). On proportionne
   lineairement au volume du ballon.

2. **Pertes thermiques** : `k x (T_consigne - T_amb) x 24h`, soit
   ~2.9 kWh/jour pour une consigne de 50 C. Meme coefficient `k = 0.004`
   que dans les optimiseurs et la baseline.

3. **Consommation electrique** : `(ECS + Pertes) / COP`

**Exemples :**

| PAC | Ballon | COP | ECS/j | Pertes/j | Conso/an | kWc auto |
|-----|--------|-----|-------|----------|----------|----------|
| 2 kW | 50 L | 3.5 | 1.5 kWh | 2.9 kWh | 458 kWh | 0.5 kWc |
| 2 kW | 200 L | 3.5 | 6.0 kWh | 2.9 kWh | 928 kWh | 1.0 kWc |
| 5 kW | 150 L | 3.5 | 4.5 kWh | 2.9 kWh | 773 kWh | 1.0 kWc |
| 10 kW | 250 L | 3.5 | 7.5 kWh | 2.9 kWh | 1085 kWh | 1.5 kWc |

### Modele grosse PAC (> 10 kW) — Heures equivalentes

```
kWc = Consommation_PAC_annuelle / 950

ou :
  Consommation_PAC_annuelle = P_pac x Heq_jour x 365 / COP_moyen
  P_pac = puissance electrique de la PAC (kW)
  Heq_jour = 5 heures equivalentes pleine charge par jour
  COP_moyen = COP_nominal
  950 = production annuelle en Belgique (kWh/kWc/an)
```

**Pourquoi un modele different ?**

Une PAC de plus de 10 kW dessert generalement plusieurs logements et/ou
fait du chauffage d'ambiance en plus de l'ECS. Le modele ECS detaille
(base sur le volume du ballon) sous-estime largement la consommation
car il ne prend pas en compte le chauffage.

Le modele par heures equivalentes est plus realiste pour ces installations :

- **5 heures/jour** est une moyenne annuelle typique pour une PAC mixte
  (chauffage + ECS) en climat belge
- En hiver : 8-12 h/jour (chauffage + ECS)
- En ete : 2-3 h/jour (ECS uniquement)
- En mi-saison : 4-6 h/jour

**Exemples :**

| PAC | COP | Heq/j | Conso/an | kWc auto |
|-----|-----|-------|----------|----------|
| 15 kW | 3.5 | 5h | 7 821 kWh | 8.5 kWc |
| 20 kW | 3.5 | 5h | 10 429 kWh | 11.0 kWc |
| 40 kW | 3.5 | 5h | 20 857 kWh | 22.0 kWc |
| 60 kW | 3.5 | 5h | 31 286 kWh | 33.0 kWc |
| 20+40 kW | 3.5 | 5h | 31 286 kWh | 33.0 kWc |

Le dernier exemple correspond a l'installation de Profondeville (2 PAC
de 20 et 40 kW en cascade).

### Production PV de reference : 950 kWh/kWc/an

Cette valeur est utilisee dans les deux modeles. Elle correspond a :
- Localisation : Belgique (region wallonne)
- Orientation : sud
- Inclinaison : 35 deg
- Source : donnees PVGIS (Photovoltaic Geographical Information System)
- Tient compte de la nebulosite moyenne belge (~1500 h de soleil/an)

### Limites communes aux deux modeles

- Les 950 kWh/kWc/an supposent une orientation sud optimale.
  Est/ouest : -15%. Nord : -40%.
- Le COP moyen annuel est generalement inferieur au COP nominal
  (mesure a 7 C). En Belgique, compter 80-90% du nominal en moyenne.
- Le dimensionnement couvre la consommation PAC uniquement, pas la
  consommation du reste du batiment.
- Le resultat est arrondi au 0.5 kWc le plus proche.

### Limites specifiques au modele ECS (<= 10 kW)

- Suppose que la PAC sert uniquement a l'ECS.
  Si la PAC fait aussi du chauffage, la consommation reelle est plus elevee.
- Les 6 kWh/jour pour 200 L supposent un menage moyen.

### Limites specifiques au modele heures equivalentes (> 10 kW)

- Les 5 heures/jour sont une moyenne. Une PAC dans un batiment tres
  mal isole ou dans un climat plus rude tournera plus longtemps.
- Le modele ne distingue pas ECS et chauffage — il les regroupe.

### Quand utiliser le mode manuel

- Si la puissance PV reelle est connue (installation existante)
- Si l'orientation des panneaux n'est pas optimale
- Si la PAC ne fait que du chauffage (pas d'ECS) ou inversement
- Pour tester differents scenarii de dimensionnement

## Charge de chauffage d'ambiance (grosses PAC > 10 kW)

Pour les PAC de plus de 10 kW, le generateur de donnees synthetiques ajoute
automatiquement une charge de **chauffage d'ambiance** en plus de l'ECS.
Ce chauffage depend de la temperature exterieure reelle (Open-Meteo).

### Modele

Loi lineaire classique de deperdition thermique du batiment :

```
Q_chauffage(t) = G x max(0, T_seuil - T_ext(t)) x dt_h   [kWh par qt]
```

Ou :
- `G` = coefficient de deperdition du batiment (kW/K)
- `T_seuil` = 15 C (seuil de chauffage : en-dessous, le batiment chauffe)
- `T_ext(t)` = temperature exterieure reelle au quart d'heure t
- `dt_h` = 0.25 h (pas de temps)

### Estimation de G

Le coefficient G est derive de la puissance PAC en supposant que la PAC
est dimensionnee pour couvrir le besoin a T_ext = -5 C (temperature de
dimensionnement standard en Belgique) :

```
P_pac_thermique = G x (T_seuil - T_dim)
P_pac x COP = G x (15 - (-5))
G = P_pac x COP / 20   [kW/K]
```

Avec COP = 3.5 :

| PAC | G (kW/K) | Charge a 0 C | Charge a -5 C | Charge a 10 C |
|-----|----------|-------------|--------------|--------------|
| 15 kW | 2.6 | 39 kWh/j | 52 kWh/j | 13 kWh/j |
| 20 kW | 3.5 | 53 kWh/j | 70 kWh/j | 18 kWh/j |
| 40 kW | 7.0 | 105 kWh/j | 140 kWh/j | 35 kWh/j |
| 60 kW | 10.5 | 158 kWh/j | 210 kWh/j | 53 kWh/j |

(Les charges ci-dessus sont les charges de CHAUFFAGE seul, par jour.
L'ECS s'y ajoute.)

### Pourquoi T_seuil = 15 C ?

Le seuil de 15 C (et non 20 C) tient compte des apports gratuits du batiment :
- Apports internes : occupants, electromenager, eclairage (~3-5 W/m2)
- Apports solaires passifs (fenetres)
- Ces apports compensent ~5 C de deperdition en moyenne

### Source des temperatures

Les temperatures exterieures proviennent des fichiers CSV locaux
`data/openmeteo_temp_YYYY.csv`, generes via l'API Open-Meteo
(historique horaire, localisation Profondeville, Belgique).

Les donnees horaires sont interpolees au quart d'heure via interpolation
lineaire (`interpolate_temperature_15min()` dans `R/openmeteo.R`).

Si les fichiers Open-Meteo ne sont pas disponibles, un modele sinusoidal
synthetique est utilise en fallback.

### Impact sur les resultats

La charge de chauffage est ajoutee au champ `soutirage_ecs_kwh` du
dataframe d'entree. Du point de vue des optimiseurs et de la baseline,
c'est une demande thermique supplementaire que la PAC doit satisfaire.

En hiver, la charge de chauffage domine largement l'ECS :
- PAC 60 kW en janvier (T_moy ~3 C) : ~2500 kWh/j de chauffage vs ~45 kWh/j d'ECS
- PAC 60 kW en avril (T_moy ~10 C) : ~500 kWh/j de chauffage vs ~45 kWh/j d'ECS
- PAC 60 kW en juillet (T_moy ~18 C) : ~0 kWh/j de chauffage vs ~45 kWh/j d'ECS
