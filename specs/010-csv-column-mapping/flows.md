# Flows: CSV Column Mapping dynamique

**Feature Branch**: `010-csv-column-mapping`
**Created**: 2026-06-02

## Flow 1: Import CSV et pre-suggestion du mapping (US1 + US2 — P1)

L'utilisateur importe un CSV aux noms de colonnes non-standard. Le systeme detecte les colonnes, applique le matching par mots-cles, pre-remplit les selecteurs, et l'utilisateur confirme ou ajuste avant de lancer la simulation.

```mermaid
sequenceDiagram
    actor User
    participant UI as Shiny UI (mod_sidebar)
    participant Server as Server (R session)
    participant Matcher as fct_csv_mapping.R
    participant DataGen as R6_data_generator

    User->>UI: Upload CSV (fichier non-standard)
    UI->>Server: input$csv_file declenche observeEvent
    Server->>Server: Lit les noms de colonnes (readr, n_max=0)
    Server->>Matcher: suggest_column_mapping(col_names)
    Matcher-->>Server: Liste de pre-suggestions (champ -> colonne)

    alt Format natif detecte (BL-004)
        Server-->>UI: Mapping marque complet — panneau reduit
    else Format non-standard
        Server->>UI: updateSelectInput() pour chaque champ
        UI-->>User: Panneau de mapping affiche (selecteurs pre-remplis)
        User->>UI: Confirme ou ajuste les selecteurs
    end

    User->>UI: Lance simulation
    UI->>Server: Mapping soumis
    Server->>Server: Validation (BL-005) : timestamp present ? champs numeriques valides ?

    alt Champ requis manquant ou non numerique
        Server-->>UI: Message d'erreur explicite — simulation bloquee
    else Mapping valide
        Server->>DataGen: Applique renommage interne (BL-006)
        DataGen-->>UI: Donnees preparees avec noms internes
        UI-->>User: Simulation lancee — resultats identiques au format natif
    end
```

## Flow 2: Retrocompatibilite — CSV au format natif (US1 scenario 2 — P1)

Un utilisateur qui importe un CSV dont les colonnes correspondent exactement au format attendu ne voit aucune difference de comportement par rapport a l'existant.

```mermaid
flowchart TD
    A([Utilisateur importe un CSV]) --> B{Colonnes = format natif ?\ntimestamp, pv_kwh, offtake_kwh,\nfeedin_kwh ou intake_kwh}
    B -- Oui --> C[Mapping marque automatiquement complet\naucune intervention requise]
    C --> D([Simulation disponible immediatement\ncomportement identique a l existant])
    B -- Non --> E[Selecteurs de mapping affiches\navec pre-suggestions calculees]
    E --> F[Utilisateur ajuste si necessaire]
    F --> G([Simulation apres validation du mapping])
```

## Flow 3: Configuration PAC et activation du mode dual (US3 — P2)

Quand l'utilisateur mappe une colonne sur PAC 2, les controles de configuration deviennent disponibles et le mode dual s'active automatiquement.

```mermaid
flowchart TD
    A([CSV importe — mapping en cours]) --> B{Colonne mappee\nsur PAC 2 ?}
    B -- Non --> C[Controles PAC 2 desactives\nmode mono-PAC actif]
    B -- Oui --> D[Controles PAC 2 actives :\ntype ASHP/GSHP\nmode on/off ou inverter\npuissance kWth\nCOP nominal]
    D --> E[pac2_active = TRUE\nDualOptimizer selectionne automatiquement]
    C --> F([Simulation mono-PAC])
    E --> G([Simulation duale via DualOptimizer\ncf. flows spec 009])

    H([Changement de CSV]) --> I[Mapping reinitialise\nPAC 2 deselectionne\nmode retourne mono-PAC]
```

## Flow 4: Explorateur de donnees avec colonnes reelles (US4 — P2)

Apres import d'un CSV, l'explorateur propose les colonnes reelles du fichier dans ses dropdowns, en complement des variables simulees.

```mermaid
flowchart TD
    A([Simulation terminee avec CSV importe]) --> B[mod_comparaison recoit :\nvars_csv = colonnes numeriques du CSV\nvars_sim = colonnes generees par la simulation]
    B --> C[Fusion vars_csv + vars_sim\npour les dropdowns de l explorateur]
    C --> D([Utilisateur voit toutes les series\ndisponibles dans les selecteurs])

    E([Mode Demo actif]) --> F[Dropdowns = variables hardcodees\ncomportement inchange BL-009]
```

## Flow 5: Chemin d'erreur — champ requis non mappe (Edge case)

Quand l'utilisateur tente de lancer la simulation sans avoir mappe le timestamp ou un champ energetique, le systeme bloque et guide l'utilisateur.

```mermaid
flowchart TD
    A([Utilisateur clique Lancer simulation]) --> B{Timestamp mappe ?}
    B -- Non --> E[Erreur : champ timestamp manquant\nsimulation bloquee]
    B -- Oui --> C{Au moins un champ\nenergetique mappe ?}
    C -- Non --> F[Erreur : aucun champ energetique\npv_kwh ou offtake_kwh requis]
    C -- Oui --> D{Colonnes numeriques\nsont bien numeriques ?}
    D -- Non --> G[Erreur : colonne X contient\ndes valeurs non numeriques]
    D -- Oui --> H([Mapping valide — simulation autorisee])
    E --> I([Panneau mapping reste ouvert\nmessage guide l utilisateur])
    F --> I
    G --> I
```
