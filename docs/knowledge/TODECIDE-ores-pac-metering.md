# Compteurs ORES vs PAC — resolution du probleme d'unites

*Cree le 2026-06-02 — resolu le 2026-06-02*

## Contexte

On comparait les donnees du compteur ORES (`wise.k0001_ores`) avec les compteurs PAC (`raw.k0001`, colonnes `EM_PAC_301` et `EM_PAC_501`). Le bilan energetique ne matchait pas : la PAC semblait consommer 48x plus que le site entier.

## Probleme initial

En utilisant `EM_PAC_301_ENER_P_IMP_PERIOD` comme energie (kWh) et `EM_PAC_301_PWR_TOT_P` comme puissance (kW), on obtenait :

- PAC total : 8 364 kWh sur 16 jours
- ORES offtake : 175 kWh sur 16 jours
- Ratio : 48x — physiquement impossible

## Investigation

### 1. Verification par courant et tension (V × I × PF)

Les colonnes de courant/tension dans `raw.k0001` montrent :
- GSHP : 232 V, **0.11 A**, PF 0.31 → P = 232 × 0.11 × 0.31 × √3 ≈ **14 W** (pas 16 kW)
- ASHP : 232 V, **1.35 A**, PF 0.01 → P ≈ **5 W** (pas 10 kW)

→ `PWR_TOT_P` ne peut pas etre en kW avec ces courants.

### 2. Relecture du mail de Lucia (19 mai)

Lucia avait precise les colonnes :
> - `EM_PAC_301_ENER_P_IMP_PERIOD` **is the power**
> - `EM_PAC_301_ENER_P_IMP_T12_PERIOD` **is the energy index**

On avait utilise `PERIOD` comme energie et `PWR_TOT_P` comme puissance. En realite :
- **`ENER_P_IMP_PERIOD`** = puissance instantanee en **W** (pas kWh)
- **`ENER_P_IMP_T12_PERIOD`** = index cumulatif d'energie en **Wh** (pas kWh)
- **`PWR_TOT_P`** = probablement une mesure interne du controleur (pas la puissance elec du compresseur)

### 3. Verification avec les index T12

En utilisant les deltas de l'index T12 (en Wh, divise par 1000 → kWh) :

| Journee du 16 mai | Si T12 en Wh → kWh | ORES (kWh) | Ratio |
|--------------------|--------------------|------------|-------|
| GSHP | 7.8 | — | — |
| ASHP | 51.3 | — | — |
| **PAC total** | **59.1** | **23.7** | **2.5x** |

Ratio 2.5x : **plausible !** La PAC (59 kWh) consomme plus que le soutirage ORES (24 kWh) car une partie vient de l'autoconsommation PV (~35 kWh).

### 4. Verification multi-jours (15 mai - 1 juin)

Avec les unites corrigees :
- GSHP : **37 kWh** sur 17 jours (~2.2 kWh/jour — quasi-arretee en mai)
- ASHP : **599 kWh** sur 17 jours (~35 kWh/jour, ~1.5 kW moyen)
- PAC total : **637 kWh**
- ORES offtake : **178 kWh**
- Ratio PAC/ORES : **3.6x** — coherent avec l'autoconsommation PV

## Resolution

Le script `data-raw/fetch_bq_dual_pac.R` a ete corrige :
- **Energie** : delta de `EM_PAC_*_ENER_P_IMP_T12_PERIOD` (index Wh cumulatif) ÷ 1000 → kWh
- **Puissance** : `EM_PAC_*_ENER_P_IMP_PERIOD` (W) ÷ 1000 → kW (pour diagnostics)
- Les colonnes `PWR_TOT_P` ne sont plus utilisees (mesure interne controleur, pas puissance compresseur)

## Lecons apprises

1. **Toujours verifier les unites avec V × I × PF** — pas se fier aux noms de colonnes
2. **Relire les mails sources** — Lucia avait donne la bonne info, on l'avait mal interpretee
3. **Le "unit check" etait circulaire** — comparer deux colonnes en unites inconnues ne prouve rien
4. **Les spikes dans les donnees** (ASHP > 2000) sont probablement des artefacts du protocole de communication avec le controleur — pas des mesures reelles

## Questions restantes pour Karno

Les questions d'unites sont resolues. Il reste :

1. **Schema electrique** : on confirme que ORES voit la chaufferie (PAC + auxiliaires + PV). Le bilan `PAC > ORES` s'explique par l'autoconsommation PV. Est-ce correct ?

2. **`PWR_TOT_P` vs `ENER_P_IMP_PERIOD`** : les deux semblent mesurer des choses differentes. `PWR_TOT_P` a des valeurs tres faibles (courants < 1.5 A) qui ne correspondent pas aux compresseurs. Que mesure exactement `PWR_TOT_P` ?

3. **Spikes ASHP** : les valeurs `EM_PAC_501_ENER_P_IMP_PERIOD > 500 W` et `EM_PAC_501_ENER_P_IMP_T12_PERIOD` avec des sauts d'index — est-ce un defaut connu du compteur ou du protocole Modbus ?
