# Paysage des librairies d'optimisation PAC

*Capture le 2026-05-19 -- source : session de travail*

## Contexte

Avant de continuer a developper notre optimizer custom (MILP/LP/QP en R), nous avons evalue s'il existait une librairie ou plateforme open-source capable de remplacer notre implementation pour l'optimisation tarifaire d'une PAC collective.

## Ce qu'on a decouvert

### Librairies evaluees

| Librairie | Langage | Ce qu'elle fait | Verdict |
|-----------|---------|----------------|---------|
| **openEMS** | Python | Solveur de champs electromagnetiques (FDTD) | Hors sujet (confusion de nom) |
| **OpenEMS** | Java | EMS temps reel (Modbus, MQTT, pilotage onduleurs) | Pertinent pour pilotage reel futur, overkill pour simulation POC |
| **emhass** | Python | MILP pour scheduling PAC + batterie + PV (Home Assistant) | Residentiel mono-batiment, COP fixe, pas de multi-logements |
| **FlexMeasures** | Python | EMS API-first, scheduling LP, forecasting ML | Le plus serieux candidat B2B -- mais modele thermique trop simplifie |
| **oemof-thermal** | Python | Modelisation thermique (stockage, PAC, solaire) | Simulation uniquement, pas d'optimiseur integre |
| **HPLIB** | Python | Courbes COP realistes par modele de PAC | Librairie de donnees COP, pas d'optimisation |
| **do-mpc** | Python | MPC non-lineaire generique | Il faut coder tout le modele soi-meme, overkill pour LP/MILP |
| **Pyomo / Linopy** | Python | Frameworks d'optimisation (equivalent ompr) | Meme niveau que notre stack : le solveur, pas le modele |
| **EnergyPlus / Modelica** | C++/Modelica | Simulation thermique ultra-detaillee | Pas d'optimisation tarifaire, oriente conception batiment |
| **OCHRE** (NREL) | Python | Simulation residentielle avec PAC | Simulation pure, pas d'optimisation, residentiel US |

### FlexMeasures -- analyse approfondie

FlexMeasures est le candidat le plus credible pour du B2B (API REST, multi-actifs, forecasting ML). Mapping avec notre code :

- `optimizer_milp.R` -> LP scheduler integre
- `R6_thermal_model.R` -> modele "storage" generique (SoC + pertes %)
- `R6_data_generator.R` (tarifs) -> sensors "consumption-price" / "production-price"
- `R6_optimizer.R` (blocs glissants) -> scheduler natif

**Limites identifiees** :
- LP uniquement (pas de MILP binaire on/off)
- COP fixe par schedule (pas de raffinement iteratif `f(T_ext, T_ballon)`)
- Pas de modelisation des puisages ECS (eau chaude sanitaire)
- Contraintes hard sur SoC-min (infaisabilite -> fallback, pas de soft constraints)
- Pas de blocs glissants avec lookahead ni valeur terminale
- Infra lourde : PostgreSQL + Redis + Flask

### Notre avantage competitif

Notre probleme est a l'intersection de trois domaines que personne ne combine :

1. **Optimisation MILP** (on/off binaire PAC) + LP + QP
2. **Thermique variable** (COP iteratif, ECS, pertes proportionnelles, T_amb)
3. **Tarification multi-contrat belge** (BELIX peak/off-peak, spot dynamique, fixe)

Fonctionnalites uniques de notre implementation :
- COP variable `f(T_ext, T_ballon)` avec raffinement iteratif (`R6_optimizer.R:74-82`)
- Soft constraints avec slack + penalite (`optimizer_milp.R:186-187, 245`)
- Blocs glissants avec lookahead (`R6_optimizer.R:40-69`)
- Valeur terminale (recompense ballon chaud en fin de bloc)
- Guard anti-regression (revert si opti > baseline, `R6_optimizer.R:149-179`)
- Batterie integree dans le meme MILP avec anti-simultaneite

## Implications

- **Decision** : conserver notre optimizer custom R pour la phase POC et simulation retrospective
- **Enrichissements possibles** : integrer HPLIB pour des courbes COP par modele de PAC, open-meteo pour le forecast meteo
- **Industrialisation future** : FlexMeasures comme backend d'optimisation si passage au multi-sites/multi-clients, avec Shiny en frontend diagnostic
- **Pilotage temps reel** : OpenEMS (Java) ou do-mpc pertinents quand on passera au controle live de la PAC

## References

- `R/optimizer_milp.R` -- solveur MILP (ompr/HiGHS)
- `R/optimizer_lp.R` -- solveur LP continu
- `R/optimizer_qp.R` -- solveur QP (CVXR)
- `R/R6_optimizer.R` -- orchestration blocs, raffinement COP, guard anti-regression
- `R/R6_thermal_model.R` -- modele thermique du ballon
- `R/R6_data_generator.R` -- generation de donnees et injection des tarifs
- `R/fct_helpers.R:14-23` -- calcul COP variable
- FlexMeasures : https://flexmeasures.readthedocs.io
- emhass : https://emhass.readthedocs.io
