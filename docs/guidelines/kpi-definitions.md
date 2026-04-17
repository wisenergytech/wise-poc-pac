# Definitions des KPIs

Ce document decrit chaque KPI affiche dans le dashboard, sa formule de calcul, ses unites et son interpretation.

## Presentation

Chaque KPI est affiche avec :
- **Valeur absolue** : le chiffre principal (ex: 142 kWh)
- **Variation relative** : pourcentage vs baseline (ex: -12.3% vs baseline)
- **Gain/reduction** : delta en valeur absolue (ex: +142 kWh)
- **Info-bulle** : explication au survol du "i"

---

## Onglet Energie

### Production PV
- **Formule** : `sum(pv_kwh)`
- **Unite** : kWh
- **Note** : Identique en baseline et optimise (meme ensoleillement). Varie avec le dimensionnement PV (kWc).

### Autoconsommation
- **Formule** : `1 - injection_opti / production_PV`
- **Unite** : %
- **Baseline** : `1 - injection_base / production_PV`
- **Gain** : difference en points de pourcentage
- **Interpretation** : Part du PV consommee sur place. Plus c'est haut, moins on "gaspille" de PV en injection a bas prix.

### Moins de soutirage
- **Formule** : `sum(offtake_kwh) - sum(sim_offtake)`
- **Unite** : kWh
- **Relatif** : `(opti - base) / |base|` — negatif = reduction (positif pour le KPI)
- **Interpretation** : Chaque kWh de soutirage evite est un kWh non achete au reseau. C'est la source principale d'economie.

### Moins d'injection
- **Formule** : `sum(intake_kwh) - sum(sim_intake)`
- **Unite** : kWh
- **Relatif** : `(opti - base) / |base|` — negatif = reduction
- **Interpretation** : Energie PV gardee sur place (autoconsommee ou stockee) plutot que vendue au reseau a un prix generalement inferieur au prix d'achat.

### Heures PAC
- **Formule** : `sum(sim_pac_on) * 0.25`
- **Unite** : h
- **Note** : Nombre de quarts d'heure ou la PAC est active, convertis en heures. Pas de comparaison baseline car le mode de calcul differe (thermostat vs optimiseur).

### Cycles batterie
- **Formule** : `sum(max(0, batt_flux)) / capacite_batterie`
- **Unite** : cycles
- **Note** : Affiche uniquement si batterie active. Un cycle = une charge complete de 0% a 100%.

---

## Onglet Finances

### Facture baseline
- **Formule** : `sum(offtake_kwh * prix_offtake) - sum(intake_kwh * prix_injection)`
- **Unite** : EUR
- **Interpretation** : Cout net de l'electricite sans optimisation. Soutirage paye - injection revendue.

### Facture optimisee
- **Formule** : `sum(sim_offtake * prix_offtake) - sum(sim_intake * prix_injection)`
- **Unite** : EUR
- **Relatif** : `(facture_opti - facture_base) / |facture_base|`
- **Interpretation** : Cout net avec pilotage intelligent de la PAC. Devrait etre inferieur a la baseline.

### Economie nette
- **Formule** : `facture_baseline - facture_optimisee`
- **Unite** : EUR
- **Interpretation** : Economie totale. Inclut 3 composantes : reduction de soutirage, variation de revenu d'injection, et arbitrage horaire (chauffer quand c'est moins cher).

### Reduction facture
- **Formule** : `economie / |facture_baseline| * 100`
- **Unite** : %
- **Interpretation** : Pourcentage de reduction du cout energetique net.

### Economie soutirage
- **Formule** : `sum(offtake_kwh * prix_offtake) - sum(sim_offtake * prix_offtake)`
- **Unite** : EUR
- **Relatif** : `(cout_sout_opti - cout_sout_base) / |cout_sout_base|`
- **Interpretation** : Economie liee uniquement a la reduction du soutirage reseau. Composante principale de l'economie totale.

### Delta injection
- **Formule** : `revenu_injection_opti - revenu_injection_base`
- **Unite** : EUR
- **Interpretation** : Variation du revenu d'injection. Generalement negatif car l'optimisation reduit l'injection (on autoconsomme plus). C'est normal et souhaitable si le prix d'autoconsommation > prix d'injection.

---

## Onglet Impact CO2

### CO2 evite
- **Formule** : `sum((offtake_kwh - sim_offtake) * co2_intensity) / 1000`
- **Unite** : kg CO2eq
- **Relatif** : `(co2_opti - co2_base) / |co2_base|`
- **Interpretation** : Emissions evitees grace au deplacement de la consommation vers des heures moins carbonees. Methodologie GHG Protocol Scope 2 (consumption-based).

### Intensite baseline
- **Formule** : `sum(offtake_kwh * co2_intensity) / sum(offtake_kwh)`
- **Unite** : gCO2eq/kWh
- **Interpretation** : Intensite carbone moyenne ponderee par le profil de consommation baseline. Reflete le mix electrique aux heures ou l'on consomme sans optimisation.

### Intensite optimisee
- **Formule** : `sum(sim_offtake * co2_intensity) / sum(sim_offtake)`
- **Unite** : gCO2eq/kWh
- **Relatif** : `(intensite_opti - intensite_base) / |intensite_base|`
- **Gain** : difference en gCO2eq/kWh
- **Interpretation** : Plus bas que baseline = la consommation a ete deplacee vers des heures plus vertes. En Belgique, les heures bon marche (nuit, weekend) sont souvent nucleaire+eolien (< 150 gCO2/kWh) tandis que les pointes (soir) sont gaz naturel (> 250 gCO2/kWh).

### Reduction intensite
- **Formule** : `(intensite_before - intensite_after) / intensite_before * 100`
- **Unite** : %
- **Interpretation** : Pourcentage de reduction de l'intensite carbone. Reflete le "double dividende" : optimiser sur le prix optimise aussi sur le carbone.

### Equivalent voiture
- **Formule** : `co2_saved_kg * 1000 / 120`
- **Unite** : km
- **Facteur** : 120 gCO2/km (norme EU WLTP 2024, voiture moyenne)
- **Interpretation** : Visualisation tangible du CO2 evite.

### Equivalent arbres
- **Formule** : `co2_saved_kg / 25`
- **Unite** : arbres/an
- **Facteur** : 25 kg CO2/arbre/an (estimation FAO, arbre feuillu mature)
- **Interpretation** : Nombre d'arbres necessaires pour absorber le meme volume de CO2 en 1 an.

---

## Sources de donnees CO2

| Priorite | Dataset | Type | Couverture |
|----------|---------|------|------------|
| 1 | Elia ODS192 | Historique, consumption-based | Oct 2024 — present |
| 2 | Elia ODS191 | Temps reel, consumption-based | Jour courant |
| 3 | Elia ODS201 | Mix de generation (calcule) | Temps reel |
| 4 | Fallback | Profil synthetique belge | Toujours disponible |

L'API Elia est publique (pas de cle necessaire). Les donnees consumption-based incluent les imports/exports avec les pays voisins et representent l'intensite reelle du kWh consomme en Belgique.
