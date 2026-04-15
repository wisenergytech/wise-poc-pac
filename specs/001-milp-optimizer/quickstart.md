# Quickstart: MILP Optimizer Mode

**Feature**: 001-milp-optimizer

## Prerequis

```bash
# Installer les packages d'optimisation
Rscript -e 'renv::install(c("ompr", "ompr.roi", "ROI.plugin.glpk")); renv::snapshot()'
```

## Utilisation

1. Lancer l'app : `make dev`
2. Dans le sidebar, section **Optimisation** :
   - Selectionner **Approche** : `Optimiseur`
   - Les options rule-based (Smart, Injection, etc.) disparaissent
3. Configurer les parametres habituels (PAC, ballon, PV, contrat)
4. Cliquer **Lancer la simulation**
5. L'optimiseur resout jour par jour avec barre de progression
6. Les resultats s'affichent dans les memes graphiques et KPIs que les modes rule-based

## Comparaison avec Rule-based

Pour comparer :
1. Lancer en mode **Optimiseur**, noter les KPIs
2. Basculer vers **Rule-based** > **Smart**, relancer
3. Comparer les resultats dans les memes graphiques

## Troubleshooting

- **"Optimisation infaisable"** : les contraintes sont trop serrees (ex: T tolerance trop petite pour la demande ECS). Augmenter la tolerance.
- **Simulation lente** : reduire le nombre de jours ou desactiver la batterie (moins de variables).
