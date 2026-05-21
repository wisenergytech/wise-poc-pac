# Optimisation couplee ASHP+GSHP — etat de l'art et faisabilite

*Capture le 2026-05-21 -- source : session de travail*

## Contexte

L'installation de Profondeville dispose de deux PAC (20 kW + 40 kW). La question s'est posee de savoir si on pouvait utiliser des solveurs differents par type de PAC (binaire on/off pour l'une, continu lisse pour l'autre) et si la litterature couvrait deja ce type d'optimisation couplee.

## Ce qu'on a decouvert

### Faisabilite technique : un seul MILP mixte

Les deux PAC alimentent le meme ballon thermique, donc elles sont **interdependantes** via la contrainte thermique. L'approche correcte est un **seul MILP** combinant variables binaires et continues :

```r
# PAC on/off (compresseur fixe, ex: GSHP)
y_gshp[t] in {0, 1}                    # binaire
p_gshp[t] = y_gshp[t] * P_nom_gshp     # puissance fixe quand allumee

# PAC inverter (vitesse variable, ex: ASHP)
p_ashp[t] in [0, P_max_ashp]           # continu

# Contrainte thermique couplee (meme ballon)
T[t+1] = T[t] + (COP_gshp(T_sol) * p_gshp[t]
                + COP_ashp(T_ext) * p_ashp[t]
                - pertes - ecs[t]) / C_ballon

# Objectif : min cout total
min Sum prix[t] * (p_gshp[t] + p_ashp[t])
```

Le solveur decide automatiquement le dispatch optimal :
- **Hiver froid** : GSHP preferee (COP stable ~4 vs ASHP degradee ~2)
- **Mi-saison** : ASHP (COP ~4.5, pas d'usure du sol)
- **Prix bas** : les deux si besoin de stocker dans le ballon
- **Prix haut** : aucune

### Extension de notre code existant

L'extension de `R/optimizer_milp.R` serait moderee car le pattern existe deja (PAC + batterie dans le meme MILP avec anti-simultaneite) :
- Ajouter `p_ashp[t]` (continues) + `y_gshp[t]` (binaires) dans le meme modele ompr
- Deux fonctions COP distinctes dans le raffinement iteratif de `R/R6_optimizer.R`
- Contrainte thermique couplee (meme structure que l'actuelle, avec deux termes de production)

### Etat de l'art academique

| Papier | Annee | Methode | Apport cle |
|--------|-------|---------|------------|
| **MILP for Dual Source Heat Pump** (IEEE) | 2019 | MILP | Dispatch ASHP/GSHP selon prix, COP variable par source. Le plus proche de notre cas. |
| D'Ettorre et al. (Applied Thermal Eng.) | 2019 | MILP + MPC | Impact de l'horizon de prediction sur les gains avec stockage thermique |
| Wang et al. (Renewable Energy) | 2022 | Mode switching | ASHP+GSHP hotel : cout reduit a 58% vs GSHP seul |
| Stojiljkovic et al. (Thermal Science) | 2025 | Optimisation | Tarifs progressifs + ToU sur systeme hybride |
| Adaptive COP predictor (J. Process Control) | 2021 | MPC + Kalman | COP adaptatif f(T_ext, charge) → 20% savings, 12% energie |
| Krutzfeldt et al. (Energy and Buildings) | 2021 | MILP | Co-optimisation design + operation, -45% investissement |
| Digital twin + MILP (Applied Energy) | 2024 | MILP + digital twin | Scheduling large-scale HP avec degradation performance |

### Gap identifie dans la litterature

Peu de papiers combinent **simultanement** :
1. Dispatch ASHP+GSHP dans un seul MILP
2. Prix dynamiques spot (pas juste ToU)
3. COP variable f(T_ext, T_sol, T_ballon) avec raffinement iteratif
4. Soft constraints (slack + penalite)
5. Blocs glissants avec lookahead + valeur terminale

L'extension de notre optimizer a deux PACs couplees serait une **contribution technique originale**.

## Implications

- **Faisable** avec notre stack actuelle (ompr/HiGHS gere nativement les MILP mixtes binaire+continu)
- **Pas besoin de deux solveurs separes** — un seul MILP est la bonne approche car les PACs sont couplees par le ballon
- **Differenciateur supplementaire** pour Wise : aucune librairie open-source ne fait du dispatch ASHP+GSHP avec COP iteratif + tarifs dynamiques
- **Prochaine etape** : specifier l'extension (`/speckit-specify`) quand un cas client le justifie

## References

- `R/optimizer_milp.R:127` -- `solve_block()` actuel (MILP PAC + batterie)
- `R/R6_optimizer.R:35` -- boucle de raffinement COP iteratif
- `R/R6_thermal_model.R` -- modele thermique du ballon (a etendre pour deux sources)
- `docs/knowledge/optimizer-custom-novelty.md` -- positionnement de notre optimizer
- `docs/knowledge/optimizer-landscape-pac.md` -- evaluation des alternatives
- IEEE 2019 MILP Dual Source HP : https://ieeexplore.ieee.org/document/8820495/
- D'Ettorre et al. 2019 MPC hybrid HP : https://doi.org/10.1016/j.applthermaleng.2019.114422
- Wang et al. 2022 coupled ASHP+GSHP : https://doi.org/10.1016/j.renene.2022.11.031
- Adaptive COP MPC 2021 : https://doi.org/10.1016/j.jprocont.2021.01.003
