# Definitions des KPIs

Ce document decrit chaque KPI affiche dans le dashboard, sa formule de calcul detaillee, ses unites, son interpretation et un exemple chiffre.

Tous les exemples utilisent un scenario de reference :

> **Scenario exemple** : 1 journee (96 quarts d'heure), PAC 20 kW, PV 10 kWc, contrat dynamique.

## Affichage

Chaque KPI est affiche avec jusqu'a 3 lignes :
- **Valeur absolue** : le chiffre principal (ex: `142 kWh`)
- **% vs baseline** : variation relative (ex: `-12.3% vs baseline`)
- **Gain/reduction** : delta en valeur absolue (ex: `+142 kWh`)

Le pictogramme **(i)** au survol affiche une explication courte.

---

## Onglet Energie

### 1. Production PV

**Unite** : kWh

La production PV est la somme de l'energie produite par les panneaux sur la periode. Elle est identique en baseline et en optimise (meme ensoleillement, meme dimensionnement). Pas de comparaison baseline.

**Formule** :

```
production_pv = sum( pv_kwh[t] )    pour t = 1..N
```

La colonne `pv_kwh` est proportionnelle au dimensionnement choisi :

```
pv_kwh[t] = pv_kwh_ref[t] * (pv_kwc / pv_kwc_ref)
```

**Exemple** :

| Qt | pv_kwh |
|----|--------|
| 10:00 | 1.8 kWh |
| 10:15 | 1.9 kWh |
| 10:30 | 2.0 kWh |
| 10:45 | 1.7 kWh |
| ... | ... |

Production PV = 1.8 + 1.9 + 2.0 + 1.7 + ... = **48.2 kWh** (sur la journee)

---

### 2. Autoconsommation

**Unite** : %

Part du PV utilisee sur place. Ce qui n'est pas autoconsomme est injecte dans le reseau.

**Formule** :

```
autoconso = (1 - injection / production_PV) * 100
```

**Exemple** :

| | Baseline | Optimise |
|--|----------|----------|
| Production PV | 48.2 kWh | 48.2 kWh |
| Injection reseau | 22.5 kWh | 15.3 kWh |
| Autoconsommation | 1 - 22.5/48.2 = **53.3%** | 1 - 15.3/48.2 = **68.3%** |

Affichage dans le dashboard :
- **Valeur** : 68.3%
- **% vs baseline** : +28.1% vs baseline (= (68.3 - 53.3) / 53.3 * 100)
- **Gain** : +15 pts (= 68.3 - 53.3, exprime en points de pourcentage)

L'optimisation a fait passer l'autoconsommation de 53% a 68% en deplacant la consommation PAC vers les heures de production PV.

---

### 3. Moins de soutirage

**Unite** : kWh

Reduction du soutirage reseau grace a l'optimisation. Chaque kWh evite est un kWh non achete.

**Formule** :

```
moins_soutirage = sum(offtake_kwh) - sum(sim_offtake)
```

**Exemple** :

| | Baseline | Optimise |
|--|----------|----------|
| Soutirage total | 65.0 kWh | 52.8 kWh |

Affichage dans le dashboard :
- **Valeur** : 12 kWh (= 65.0 - 52.8)
- **% vs baseline** : -18.8% vs baseline (= (52.8 - 65.0) / 65.0 * 100)
- **Gain** : +12 kWh

L'optimisation a evite 12.2 kWh de soutirage en chauffant le ballon pendant les heures de surplus PV plutot que pendant les heures de pointe.

---

### 4. Moins d'injection

**Unite** : kWh

Reduction de l'injection reseau. Chaque kWh d'injection evitee est un kWh de PV consomme sur place au lieu d'etre vendu au reseau a un prix generalement inferieur au prix d'achat.

**Formule** :

```
moins_injection = sum(intake_kwh) - sum(sim_intake)
```

**Exemple** :

| | Baseline | Optimise |
|--|----------|----------|
| Injection totale | 22.5 kWh | 15.3 kWh |

Affichage dans le dashboard :
- **Valeur** : 7 kWh (= 22.5 - 15.3)
- **% vs baseline** : -32.0% vs baseline (= (15.3 - 22.5) / 22.5 * 100)
- **Gain** : +7 kWh

7.2 kWh de PV qui auraient ete injectes a ~0.03 EUR/kWh ont ete autoconsommes (valeur ~0.25 EUR/kWh).

---

### 5. Conso PAC

**Unite** : kWh electriques

Consommation electrique de la pompe a chaleur. Comparee entre baseline (thermostat) et optimise.

**Formule optimise** :

```
conso_pac_opti = sum( sim_pac_on[t] * P_pac_kw * dt_h )
```

Ou `sim_pac_on` est le taux de charge [0-1], `P_pac_kw` la puissance nominale (20 kW), `dt_h` le pas de temps (0.25 h).

**Formule baseline** :

Le taux de charge baseline (thermostat on/off) n'est pas sauvegarde directement. On le deduit du bilan energetique :

```
conso_pac_base = sum( offtake_kwh + pv_kwh - intake_kwh - conso_hors_pac )
```

Logique : tout ce qui rentre dans le systeme (reseau + PV) moins tout ce qui en sort (injection + conso hors PAC) = ce que la PAC a consomme.

**Exemple** :

*Baseline* (thermostat, PAC = on/off 20 kW) :

```
offtake total  = 65.0 kWh
pv total       = 48.2 kWh
intake total   = 22.5 kWh
conso_hors_pac = 55.7 kWh
conso_pac_base = 65.0 + 48.2 - 22.5 - 55.7 = 35.0 kWh
```

*Optimise* (taux de charge continu LP) :

```
sum(sim_pac_on * 20 * 0.25) = sum(sim_pac_on * 5)
Si sum(sim_pac_on) = 6.4 → conso_pac_opti = 6.4 * 5 = 32.0 kWh
```

Affichage dans le dashboard :
- **Valeur** : 32 kWh
- **% vs baseline** : -8.6% vs baseline (= (32 - 35) / 35 * 100)
- **Gain** : -3 kWh

La PAC consomme 3 kWh de moins en optimise. C'est possible car l'optimiseur chauffe davantage quand le COP est meilleur (heures plus chaudes) et evite de chauffer quand le COP est mauvais.

---

### 6. Cycles batterie

**Unite** : cycles (sans dimension)

Nombre de cycles complets de charge/decharge de la batterie. Affiche uniquement si la batterie est activee. Pas de comparaison baseline (pas de batterie en baseline).

**Formule** :

```
cycles = sum( max(0, batt_flux[t]) ) / capacite_batterie
```

`batt_flux` > 0 = charge, < 0 = decharge. On ne compte que la charge. Un cycle = une charge complete de 0% a 100%.

**Exemple** (batterie 10 kWh) :

```
energie chargee totale = 15.3 kWh
cycles = 15.3 / 10 = 1.5
```

---

## Onglet Finances

### 7. Facture baseline

**Unite** : EUR

Cout net de l'electricite sans optimisation. C'est la reference, pas de comparaison.

**Formule** :

```
facture_base = sum( offtake_kwh[t] * prix_offtake[t] )
             - sum( intake_kwh[t] * prix_injection[t] )
```

Pour chaque quart d'heure, on multiplie le soutirage par le prix spot d'achat et l'injection par le prix de revente.

**Exemple** (3 quarts d'heure) :

| Qt | offtake (kWh) | prix_offtake (EUR/kWh) | intake (kWh) | prix_injection (EUR/kWh) |
|----|---------------|------------------------|--------------|--------------------------|
| 08:00 | 3.2 | 0.28 | 0 | 0.03 |
| 12:00 | 0 | 0.15 | 2.1 | 0.03 |
| 18:00 | 4.5 | 0.35 | 0 | 0.03 |

```
cout_soutirage   = 3.2*0.28 + 0*0.15 + 4.5*0.35 = 0.896 + 0 + 1.575 = 2.471 EUR
revenu_injection = 0*0.03 + 2.1*0.03 + 0*0.03 = 0.063 EUR
facture_base     = 2.471 - 0.063 = 2.408 EUR
```

Sur une journee complete : **Facture baseline = 18.50 EUR**

---

### 8. Facture optimisee

**Unite** : EUR

Cout net avec pilotage intelligent de la PAC. Meme formule que la baseline, avec les flux optimises.

**Formule** :

```
facture_opti = sum( sim_offtake[t] * prix_offtake[t] )
             - sum( sim_intake[t] * prix_injection[t] )
```

**Exemple** :

```
facture_opti = 15.20 EUR
```

Affichage dans le dashboard :
- **Valeur** : 15 EUR
- **% vs baseline** : -17.8% vs baseline (= (15.20 - 18.50) / 18.50 * 100)

---

### 9. Economie nette

**Unite** : EUR

Difference entre facture baseline et optimisee. Pas de % vs baseline (c'est deja un delta).

**Formule** :

```
economie = facture_baseline - facture_optimisee
```

L'economie se decompose en 3 composantes :

1. **Eco. soutirage** : kWh evites, valorises au prix spot de chaque heure
2. **Perte injection** : kWh non vendus, valorises au prix d'injection
3. **Arbitrage horaire** : gain d'avoir consomme aux heures les moins cheres

```
eco_soutirage   = sum(offtake_kwh * prix_offtake) - sum(sim_offtake * prix_offtake)
perte_injection = sum(intake_kwh * prix_injection) - sum(sim_intake * prix_injection)
arbitrage       = economie - eco_soutirage + perte_injection
```

**Exemple** :

```
facture_base = 18.50 EUR
facture_opti = 15.20 EUR
economie     = 18.50 - 15.20 = 3.30 EUR

Decomposition :
  eco_soutirage   = 19.12 - 15.83             = +3.29 EUR
  perte_injection = 0.68 - 0.46               = +0.22 EUR (revenu perdu)
  arbitrage       = 3.30 - 3.29 + 0.22        = +0.23 EUR
  TOTAL           = 3.29 - 0.22 + 0.23        = +3.30 EUR
```

Affichage : **+3 EUR**

---

### 10. Reduction facture

**Unite** : %

Pourcentage de reduction du cout energetique. Pas de % vs baseline (c'est deja un ratio).

**Formule** :

```
reduction = economie / |facture_baseline| * 100
```

**Exemple** :

```
reduction = 3.30 / 18.50 * 100 = 17.8%
```

---

### 11. Economie soutirage

**Unite** : EUR

Economie liee uniquement a la reduction du soutirage reseau. C'est la composante principale de l'economie totale.

**Formule** :

```
eco_soutirage = sum( offtake_kwh[t] * prix_offtake[t] )
              - sum( sim_offtake[t] * prix_offtake[t] )
```

Attention : ce n'est pas simplement "kWh evites * prix moyen". Chaque quart d'heure a son propre prix spot. L'economie capture la valeur reelle des kWh evites au prix auquel ils auraient ete achetes.

**Exemple** :

```
cout_sout_base = 19.12 EUR
cout_sout_opti = 15.83 EUR
eco_soutirage  = 19.12 - 15.83 = 3.29 EUR
```

Affichage dans le dashboard :
- **Valeur** : 3 EUR
- **% vs baseline** : -17.2% vs baseline (= (15.83 - 19.12) / 19.12 * 100)

---

### 12. Delta injection

**Unite** : EUR

Variation du revenu d'injection. Generalement **negatif** car l'optimisation reduit l'injection (on autoconsomme plus de PV).

**Formule** :

```
delta_injection = sum( sim_intake[t] * prix_injection[t] )
               - sum( intake_kwh[t] * prix_injection[t] )
```

C'est normal et souhaitable : chaque kWh autoconsomme "vaut" le prix d'achat evite (~0.25 EUR/kWh) au lieu du prix d'injection (~0.03 EUR/kWh). On perd un peu de revenu d'injection mais on economise beaucoup plus en soutirage.

**Exemple** :

```
revenu_inj_base = 0.68 EUR
revenu_inj_opti = 0.46 EUR
delta_injection = 0.46 - 0.68 = -0.22 EUR
```

Affichage : **-0 EUR** (arrondi). On perd 0.22 EUR de revenu d'injection, mais on economise 3.29 EUR de soutirage.

---

## Onglet Impact CO2

### 13. CO2 evite

**Unite** : kg CO2eq

Emissions CO2 evitees grace au deplacement de la consommation vers des heures moins carbonees. Methodologie GHG Protocol Scope 2 (consumption-based).

**Formule** :

```
co2_saved[t] = (offtake_kwh[t] - sim_offtake[t]) * co2_intensity[t]   # en gCO2eq
co2_saved_kg = sum( co2_saved ) / 1000
```

Le signe est important :
- **Positif** = soutirage reduit a une heure carbonee → CO2 evite
- **Negatif** = soutirage augmente a une heure carbonee → CO2 ajoute (rare)

**Exemple** (4 quarts d'heure) :

| Qt | offtake_base | sim_offtake | delta (kWh) | co2_intensity (gCO2/kWh) | co2_saved (g) |
|----|-------------|-------------|-------------|--------------------------|---------------|
| 08:00 | 3.2 | 1.0 | +2.2 | 230 | 2.2 * 230 = **+506** |
| 12:00 | 0 | 0 | 0 | 120 | 0 * 120 = **0** |
| 14:00 | 0.5 | 2.0 | -1.5 | 95 | -1.5 * 95 = **-143** |
| 18:00 | 4.5 | 2.8 | +1.7 | 280 | 1.7 * 280 = **+476** |

```
co2_saved_total = (506 + 0 - 143 + 476) / 1000 = 0.839 kg
```

A 08h et 18h, l'optimiseur a reduit le soutirage pendant des heures carbonees (gaz en marginal). A 14h, il a augmente le soutirage mais pendant une heure verte (solaire) — le bilan reste largement positif.

Affichage dans le dashboard :
- **Valeur** : 0.8 kg (sur ces 4 qt)
- **% vs baseline** : -5.2% vs baseline (= (co2_opti - co2_base) / co2_base * 100)
- **Gain** : +1 kg

Sur une journee complete : **CO2 evite = 2.8 kg**

---

### 14. Intensite baseline

**Unite** : gCO2eq/kWh

Intensite carbone moyenne ponderee par le profil de consommation baseline. C'est la reference, pas de comparaison.

Ce n'est **pas** la moyenne simple de l'intensite du reseau : c'est l'intensite "vue" par la consommation. Si on consomme beaucoup a 18h (280 gCO2/kWh) et peu a 14h (95 gCO2/kWh), l'intensite ponderee sera elevee.

**Formule** :

```
intensite_baseline = sum( offtake_kwh[t] * co2_intensity[t] )
                   / sum( offtake_kwh[t] )
```

**Exemple** :

| Qt | offtake_kwh | co2_intensity | offtake * co2 |
|----|-------------|---------------|---------------|
| 08:00 | 3.2 | 230 | 736 |
| 12:00 | 0 | 120 | 0 |
| 14:00 | 0.5 | 95 | 48 |
| 18:00 | 4.5 | 280 | 1 260 |

```
intensite_baseline = (736 + 0 + 48 + 1260) / (3.2 + 0 + 0.5 + 4.5)
                   = 2044 / 8.2
                   = 249 gCO2/kWh
```

L'intensite ponderee (249) est bien plus haute que la moyenne simple des 4 heures ((230+120+95+280)/4 = 181) car on consomme surtout aux heures carbonees.

---

### 15. Intensite optimisee

**Unite** : gCO2eq/kWh

Meme formule que la baseline, avec les flux optimises. Si l'optimiseur a deplace la consommation vers des heures vertes, cette intensite sera plus basse.

**Formule** :

```
intensite_optimisee = sum( sim_offtake[t] * co2_intensity[t] )
                    / sum( sim_offtake[t] )
```

**Exemple** :

| Qt | sim_offtake | co2_intensity | sim_offtake * co2 |
|----|-------------|---------------|-------------------|
| 08:00 | 1.0 | 230 | 230 |
| 12:00 | 0 | 120 | 0 |
| 14:00 | 2.0 | 95 | 190 |
| 18:00 | 2.8 | 280 | 784 |

```
intensite_optimisee = (230 + 0 + 190 + 784) / (1.0 + 0 + 2.0 + 2.8)
                    = 1204 / 5.8
                    = 208 gCO2/kWh
```

Affichage dans le dashboard :
- **Valeur** : 208 gCO2/kWh
- **% vs baseline** : -16.5% vs baseline (= (208 - 249) / 249 * 100)
- **Gain** : -41 gCO2/kWh

L'optimisation a reduit l'intensite carbone de 41 gCO2/kWh en deplacant la conso vers des heures nucleaire+eolien (14h, solaire abondant → intensite basse).

---

### 16. Reduction intensite

**Unite** : %

Pourcentage de reduction de l'intensite carbone. Pas de % vs baseline (c'est deja un ratio).

**Formule** :

```
reduction = (intensite_baseline - intensite_optimisee) / intensite_baseline * 100
```

**Exemple** :

```
reduction = (249 - 208) / 249 * 100 = 16.5%
```

Cela illustre le **"double dividende"** : en Belgique, les heures electriques bon marche (nuit, weekend) sont aussi les heures les moins carbonees (nucleaire + eolien). Optimiser le cout optimise aussi le carbone.

---

### 17. Equivalent voiture

**Unite** : km

Visualisation tangible du CO2 evite, exprimee en kilometres de voiture thermique.

**Formule** :

```
equiv_km = co2_saved_kg * 1000 / 120
```

Facteur de conversion : 120 gCO2/km (norme EU WLTP 2024, voiture moyenne neuve).

**Exemple** :

```
equiv_km = 2.8 * 1000 / 120 = 23 km
```

Les 2.8 kg de CO2 evites en 1 jour correspondent a 23 km en voiture thermique. Extrapole sur 1 an : ~8 400 km.

---

### 18. Equivalent arbres

**Unite** : arbres/an

Nombre d'arbres necessaires pour absorber le CO2 evite en un an.

**Formule** :

```
equiv_arbres = co2_saved_kg / 25
```

Facteur de conversion : 25 kg CO2/arbre/an (estimation FAO, arbre feuillu mature en zone temperee).

**Exemple** :

```
equiv_arbres = 2.8 / 25 = 0.1 arbre/an (pour 1 jour)
```

Extrapole sur 1 an : 2.8 * 365 / 25 = **40.9 arbres/an**.

---

## Sources de donnees CO2

| Priorite | Dataset | Type | Couverture | Resolution |
|----------|---------|------|------------|------------|
| 1 | Elia ODS192 | Historique, consumption-based | Oct 2024 — present | Horaire |
| 2 | Elia ODS191 | Temps reel, consumption-based | Jour courant | Horaire |
| 3 | Elia ODS201 | Mix de generation (calcule) | Temps reel | 15 min |
| 4 | Fallback | Profil synthetique belge 2024 | Toujours disponible | Horaire |

**API** : `https://opendata.elia.be/api/explore/v2.1/catalog/datasets/{dataset}/records`
Pas de cle d'authentification requise — API publique.

**Methodologie** : les donnees consumption-based (ODS192/191) incluent les imports/exports avec les pays voisins et representent l'intensite reelle du kWh consomme en Belgique. Le calcul ODS201 (fallback) utilise les facteurs lifecycle IPCC AR5 par type de combustible (12 gCO2/kWh nucleaire, 490 gCO2/kWh gaz, etc.) appliques au mix de generation observe.

**Interpolation** : les donnees horaires sont interpolees lineairement au pas de 15 min via `approx()` pour s'aligner avec les timestamps de simulation. Les valeurs manquantes sont remplacees par la mediane du profil.

---

## Glossaire

| Terme | Definition |
|-------|-----------|
| offtake_kwh | Energie soutiree du reseau (achetee) par quart d'heure, en kWh |
| sim_offtake | Idem, apres optimisation |
| intake_kwh | Energie injectee dans le reseau (vendue) par quart d'heure, en kWh |
| sim_intake | Idem, apres optimisation |
| pv_kwh | Production photovoltaique par quart d'heure, en kWh |
| conso_hors_pac | Consommation electrique du batiment hors PAC, en kWh/qt |
| sim_pac_on | Taux de charge de la PAC entre 0 et 1 (0 = arretee, 1 = pleine puissance) |
| prix_offtake | Prix spot d'achat de l'electricite, en EUR/kWh |
| prix_injection | Prix de revente de l'injection, en EUR/kWh |
| co2_intensity | Intensite carbone du reseau electrique, en gCO2eq/kWh |
| P_pac_kw | Puissance electrique nominale de la PAC, en kW |
| dt_h | Pas de temps = 0.25 h (15 minutes) |
| COP | Coefficient de performance de la PAC (chaleur produite / electricite consommee) |
| Baseline | Simulation de reference avec thermostat classique (on/off selon temperature) |
| Optimise | Simulation avec pilotage intelligent (MILP, LP, QP ou Smart) |
