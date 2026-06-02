# Flow: Import CSV et pre-suggestion du mapping

**Source spec**: [spec:010] `specs/010-csv-column-mapping/`
**Composants impliques**: mod_sidebar, fct_csv_mapping.R, R6_data_generator, DualOptimizer (spec:009)
**Created**: 2026-06-02

Ce flux est marque cross-spec car il constitue le point d'entree de toutes les donnees CSV dans l'application. Il conditionne le comportement du pipeline de simulation (spec:009 DualOptimizer inclus) selon le contenu du mapping.

## Flux principal

```mermaid
sequenceDiagram
    actor User
    participant UI as Shiny UI (mod_sidebar)
    participant Server as Server (R session)
    participant Matcher as fct_csv_mapping.R
    participant DataGen as R6_data_generator
    participant Optimizer as Optimizer (mono ou dual)

    User->>UI: Upload CSV
    UI->>Server: input$csv_file declenche observeEvent
    Server->>Server: Lit les noms de colonnes (readr, n_max=0)
    Server->>Matcher: suggest_column_mapping(col_names)
    Matcher-->>Server: Pre-suggestions (champ -> colonne source)

    alt Format natif detecte
        Server-->>UI: Mapping complet automatique
    else Format non-standard
        Server->>UI: updateSelectInput() — panneau de mapping
        UI-->>User: Selecteurs pre-remplis
        User->>UI: Confirme ou ajuste
    end

    User->>UI: Lance simulation
    Server->>Server: Validation mapping (timestamp + champ energetique)

    alt Mapping invalide
        Server-->>UI: Erreur — simulation bloquee
    else Mapping valide
        Server->>DataGen: Renommage interne colonnes -> noms internes
        DataGen->>Optimizer: Donnees au format interne standard

        alt PAC 2 mappee (spec:009)
            Optimizer->>Optimizer: DualOptimizer (pac2_active=TRUE)
        else PAC 2 non mappee
            Optimizer->>Optimizer: MILPOptimizer mono-PAC
        end

        Optimizer-->>UI: Resultats simulation
        UI-->>User: KPIs + explorateur avec colonnes reelles
    end
```

## Liens vers specs

- Detail complet du mapping : `specs/010-csv-column-mapping/flows.md`
- Simulation duale (apres mapping PAC 2) : `specs/009-dual-pac-optimizer/flows.md`
- Regles metier du mapping : `specs/010-csv-column-mapping/business-logic.md`
