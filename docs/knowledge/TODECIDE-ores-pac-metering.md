# Question Karno : incoherence compteur ORES vs compteurs PAC

*Prepare le 2026-06-02 -- a envoyer a Clement/William*

## Contexte

On essaie de faire le bilan energetique du site pour valider notre optimiseur. On compare les donnees du compteur ORES (`wise.k0001_ores`) avec les nouveaux compteurs electriques des PAC (`raw.k0001`, colonnes `EM_PAC_301` et `EM_PAC_501`).

William a confirme (mail du 18 mai) que "le compteur ORES comptabilise le prelevement et l'injection sur le reseau" et que "la nuit, tout ce qui est comptabilise par le compteur est utilise par la chaufferie".

## Observation 1 : ORES ne voit pas les PAC la nuit

La nuit du 16 mai 2026 (pas de PV, pas d'injection), les deux PAC tournent a pleine puissance mais le compteur ORES ne voit quasi rien :

| Heure (UTC) | ORES (kW) | GSHP EM_PAC_301 (kW) | ASHP EM_PAC_501 (kW) | PAC total (kW) |
|-------------|-----------|----------------------|----------------------|----------------|
| 21:05 | 0.32 | 15.9 | 9.3 | 25.2 |
| 21:15 | 0.31 | 16.0 | 9.2 | 25.3 |
| 21:30 | 0.31 | 16.1 | 9.9 | 25.9 |
| 21:45 | 0.31 | 16.0 | 9.4 | 25.3 |
| 22:00 | 0.30 | 16.0 | 9.6 | 25.6 |

Les PAC consomment ~25 kW mais ORES ne voit que 0.3 kW (talon).

**Sur toute la periode 15 mai - 1 juin** :
- Consommation ORES totale : **175 kWh** (16 jours) = 0.46 kW moyen
- Consommation PAC estimee : **8 364 kWh** = 22 kW moyen

## Observation 2 : spikes dans les compteurs PAC

La colonne `EM_PAC_501_PWR_TOT_P` (puissance ASHP) montre des valeurs aberrantes periodiques. Ces spikes **correlent** avec des hausses ponctuelles du compteur ORES :

| Heure (UTC) | ORES (kW) | GSHP EM_PAC_301 (kW) | ASHP EM_PAC_501 (kW) | Commentaire |
|-------------|-----------|----------------------|----------------------|-------------|
| 22:05 | 0.31 | 16.0 | 10.4 | Normal |
| 22:10 | 1.73 | 16.0 | **2 540** | Spike ASHP, ORES monte |
| 22:15 | 3.37 | 16.1 | **3 097** | Spike |
| 22:25 | 3.97 | 16.1 | **3 596** | Spike |
| 22:35 | 4.21 | 16.1 | **3 766** | Spike |

La GSHP (`EM_PAC_301_PWR_TOT_P`) est stable a ~16 kW. L'ASHP a des spikes reguliers a >2000 kW (physiquement impossible pour une Hoval Belaria Pro 24).

La colonne `EM_PAC_501_ENER_P_IMP_PERIOD` montre le meme probleme — des sauts de valeur (644, 518, 90 kWh puis 2.5 kWh par periode de 5 min).

## Observation 3 : correlation ORES ↔ spikes ASHP

Les plus grosses consommations ORES coincident avec les spikes ASHP :

| Moment | ORES (kW) | GSHP (kW) | ASHP (kW) |
|--------|-----------|-----------|-----------|
| 26 mai 11:35 | **126** | 17.1 | 9.0 |
| 16 mai 03:45 | **12.8** | 8 618 | 3 113 |
| 16 mai 03:50 | **12.7** | 8 773 | 2 779 |
| 16 mai 04:10 | **6.6** | 16.3 | 10.5 |

Quand les deux compteurs PAC ont des spikes, ORES monte aussi. En fonctionnement "normal" (GSHP ~16 kW, ASHP ~10 kW), ORES ne voit que 0.3 kW.

## Hypotheses

**H1 — Les compteurs EM_PAC ne sont pas en kW.** Si `PWR_TOT_P` etait en W (pas kW), la GSHP serait a 16 W et l'ASHP a 10 W. Mais 16 W est trop faible pour une PAC, et ca ne colle pas avec la fiche constructeur (Carrier 61WG035 = 10-11 kW elec nominal).

**H2 — Le compteur ORES dans BQ (`wise.k0001_ores`) ne couvre pas les PAC.** Les PAC seraient sur un circuit separe (triphas ?) non mesure par ce compteur. Les 0.3 kW de talon = auxiliaires/circulateurs.

**H3 — Les valeurs "normales" des compteurs PAC (16 kW, 10 kW) sont fausses.** Ce seraient les spikes qui sont les vraies valeurs, et les 16/10 kW seraient des valeurs de veille/standby. Mais physiquement 16 kW est coherent avec la Carrier 61WG035.

**H4 — Les compteurs PAC reportent des valeurs internes au controleur**, pas des mesures electriques reelles. Les spikes seraient des artefacts du protocole de communication.

## Questions pour Karno

1. **Le compteur ORES dans BigQuery (`wise.k0001_ores`) mesure-t-il bien la chaufferie PAC incluses ?** Nos donnees montrent que la nuit, ORES voit 0.3 kW alors que les PAC declarent consommer 25 kW.

2. **Les colonnes `EM_PAC_301_PWR_TOT_P` et `EM_PAC_501_PWR_TOT_P` — quelle est l'unite ?** kW ? W ? Autre ? Et les spikes reguliers a >2000 sur l'ASHP — est-ce un defaut du compteur ou du protocole ?

3. **Les colonnes `EM_PAC_*_ENER_P_IMP_PERIOD` — qu'est-ce qu'elles mesurent exactement ?** Energie par periode de 5 min (kWh) ? Index cumulatif ? Autre ? On observe des sauts non expliques (644 → 518 → 90 → 2.5).

4. **Schema electrique simplifie** : pouvez-vous nous confirmer ce qui est en amont et en aval du compteur ORES ? Les PAC sont-elles sur le meme circuit ou un circuit triphas separe ?

## Impact sur le POC

Sans reponse a ces questions, on ne peut pas :
- Calculer la part PAC dans la conso du site
- Calculer le PV disponible pour la PAC (vs le reste du batiment)
- Produire des KPIs financiers fiables (facture baseline vs optimisee)

L'optimiseur fonctionne techniquement (scheduling PAC optimal sous contraintes thermiques + prix), mais les resultats chiffres (EUR economises) ne sont pas fiables tant que le bilan energetique n'est pas resolu.
