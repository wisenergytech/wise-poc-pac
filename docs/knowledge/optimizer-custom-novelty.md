# Notre optimizer custom est novateur dans sa combinaison

*Capture le 2026-05-20 -- source : session de travail*

## Contexte

Apres evaluation de 10+ librairies et plateformes open-source (FlexMeasures, emhass, OpenEMS, oemof-thermal, HPLIB, do-mpc, Pyomo, EnergyPlus, OCHRE), aucune ne couvre la combinaison de fonctionnalites que notre optimizer implemente. Voir `docs/knowledge/optimizer-landscape-pac.md` pour l'evaluation detaillee.

## Ce qu'on a decouvert

### Ce qui existe sur le marche

Le marche se segmente en 4 categories, chacune ne couvrant qu'une partie du probleme :

1. **Frameworks d'optimisation generiques** (Pyomo, ompr, CVXR) -- le solveur sans le modele
2. **EMS generiques** (FlexMeasures, OpenEMS) -- scheduling LP basique, COP fixe, modele thermique simplifie
3. **Simulateurs thermiques** (EnergyPlus, Modelica) -- physique detaillee sans optimisation tarifaire
4. **Outils residentiels** (emhass) -- mono-maison, pas de collectif

### Notre combinaison unique

Notre optimizer combine 7 fonctionnalites que personne n'integre dans un seul outil :

| # | Fonctionnalite | Fichier source | Ce que les autres font |
|---|---------------|----------------|----------------------|
| 1 | MILP binaire (on/off PAC) | `R/optimizer_milp.R` | FlexMeasures : LP continu (pas de on/off) |
| 2 | COP iteratif f(T_ext, T_ballon) | `R/R6_optimizer.R` (boucle de raffinement) | emhass/FlexMeasures : COP fixe par schedule |
| 3 | Puisages ECS dans la dynamique thermique | `R/R6_thermal_model.R` | Aucun EMS ne modelise les soutirages eau chaude |
| 4 | Soft constraints (slack + penalite) | `R/optimizer_milp.R` (variables slack) | FlexMeasures : hard SoC-min → infaisabilite → fallback |
| 5 | Blocs glissants + lookahead + valeur terminale | `R/R6_optimizer.R` (orchestration blocs) | FlexMeasures : horizon unique |
| 6 | Multi-contrat belge (BELIX, spot, fixe) | `R/R6_data_generator.R` (tarifs) | emhass : prix spot uniquement |
| 7 | Guard anti-regression automatique | `R/R6_optimizer.R` (revert si opti > baseline) | Aucun equivalent identifie |

### Pourquoi cette combinaison compte

Les acteurs commerciaux resolvent un probleme **plus simple** : "quand allumer un actif flexible vu les prix". Notre probleme est plus riche : "quand allumer une PAC collective en tenant compte de la physique reelle du ballon, des puisages, du COP non-lineaire, et de plusieurs structures tarifaires belges".

Le COP iteratif est particulierement important : sur une PAC eau/eau, le COP varie de 1.5 a 5.5 selon T_ballon et T_ext. Un COP fixe a 3.5 peut donner un scheduling qui surchauffe le ballon (COP reel = 2) ou sous-estime la capacite (COP reel = 5).

## Implications

- **Differenciateur technique reel** pour Wise en tant qu'energy service company pour le pilotage de PAC collectives
- **A documenter et packager proprement** pour en faire un argument commercial
- **Pas academique** : c'est exactement ce dont un operateur de PAC collective a besoin
- **Enrichissements identifies** : HPLIB (courbes COP par modele PAC), open-meteo (forecast meteo) pourraient renforcer encore l'avantage

## References

- `docs/knowledge/optimizer-landscape-pac.md` -- evaluation detaillee des alternatives
- `R/optimizer_milp.R` -- solveur MILP
- `R/R6_optimizer.R` -- orchestration, COP iteratif, guard anti-regression
- `R/R6_thermal_model.R` -- modele thermique du ballon
- `R/R6_data_generator.R` -- tarifs multi-contrat
