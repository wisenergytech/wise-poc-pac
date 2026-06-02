# Flows — Index global

Ce fichier reference tous les flux documentés dans le projet, par spec source. Les flux purement internes a une feature sont référencés ici avec un lien vers leur `flows.md` source. Les flux qui interagissent avec plusieurs features ont leur propre fichier dans ce repertoire.

**Derniere mise a jour**: 2026-06-02

---

## Tableau des flux

| Flux | Spec source | Type | Fichier |
|------|-------------|------|---------|
| Configuration et activation de PAC 2 | [spec:009] | interne | [specs/009-dual-pac-optimizer/flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-1) |
| Simulation et dispatch dual ASHP+GSHP | [spec:009] | interne | [specs/009-dual-pac-optimizer/flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-2) |
| Lissage inverter — validation contrainte de rampe | [spec:009] | interne | [specs/009-dual-pac-optimizer/flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-3) |
| Affichage ventilation PAC 1 / PAC 2 | [spec:009] | interne | [specs/009-dual-pac-optimizer/flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-4) |
| Chemin d'erreur — bloc infaisable (dual) | [spec:009] | interne | [specs/009-dual-pac-optimizer/flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-5) |
| Import CSV et pre-suggestion du mapping | [spec:010] | cross-spec (pipeline donnees) | [csv-import-mapping.md](./csv-import-mapping.md) |
| Retrocompatibilite — CSV format natif | [spec:010] | interne | [specs/010-csv-column-mapping/flows.md](../../specs/010-csv-column-mapping/flows.md#flow-2) |
| Configuration PAC et activation mode dual via mapping | [spec:010] | cross-spec (lie a spec:009) | [specs/010-csv-column-mapping/flows.md](../../specs/010-csv-column-mapping/flows.md#flow-3) |
| Explorateur de donnees avec colonnes reelles | [spec:010] | interne | [specs/010-csv-column-mapping/flows.md](../../specs/010-csv-column-mapping/flows.md#flow-4) |
| Chemin d'erreur — champ requis non mappe | [spec:010] | interne | [specs/010-csv-column-mapping/flows.md](../../specs/010-csv-column-mapping/flows.md#flow-5) |

---

## Legende

- **interne** : flux contenu dans le perimetre d'une seule feature
- **cross-spec** : flux qui interagit avec des composants d'autres features ou qui structure un comportement transversal
