# Business Logic — Global

<!--
  Aggregated transversal business rules that apply across multiple features.
  Updated by Speckit when a feature introduces rules that go beyond its own scope.
  Feature-specific rules remain in specs/<feature>/business-logic.md.
-->

## Transversal Rules

### Guard anti-regression — le dual ne doit jamais degrader le cout [spec:009]

Quand un solveur plus complexe est utilise (ex: dual), son cout net est compare au meilleur resultat du solveur de reference. Si le solveur complexe est plus cher, le systeme revient automatiquement au resultat de reference.

Source complete : `specs/009-dual-pac-optimizer/business-logic.md` (BL-007)

### Retrocompatibilite obligatoire des solveurs existants [spec:009]

Tout nouveau solveur ou mode de simulation ne doit pas modifier le comportement des solveurs existants (MILP, LP, QP). Les scenarios mono-PAC produisent des resultats identiques avant et apres l'ajout d'un nouveau solveur.

Source complete : `specs/009-dual-pac-optimizer/business-logic.md` (BL-001, BL-012)

### Couplage thermique — un seul ballon par installation [spec:009]

Plusieurs sources de chaleur (PAC multiples) alimentent toujours le meme ballon thermique. Les architectures a ballons separes ne sont pas prises en charge dans ce POC.

Source complete : `specs/009-dual-pac-optimizer/business-logic.md` (Invariants)
