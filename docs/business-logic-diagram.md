# PAC Optimizer — Diagramme de logique metier

## 1. Pipeline global de simulation

```mermaid
flowchart TB
    subgraph ENTREES["DONNEES D'ENTREE"]
        CSV[CSV utilisateur<br/>ou donnees demo]
        BELPEX[Prix Belpex<br/>CSV locaux + API ENTSO-E]
        PARAMS[Parametres utilisateur<br/>PAC, ballon, PV, contrat]
    end

    subgraph PREPARATION["PREPARATION DES DONNEES"]
        LOAD[Charger / generer<br/>donnees quart-horaires]
        JOIN[Joindre prix Belpex<br/>par heure arrondie]
        PREP[prepare_df<br/>Calibrer pertes thermiques<br/>Estimer conso hors PAC<br/>Appliquer tarification]
    end

    subgraph SIMULATION["BOUCLE DE SIMULATION"]
        LOOP[Pour chaque quart d heure i = 2..N]
        COP[Calculer COP<br/>f T exterieure]
        SURPLUS[Calculer surplus PV<br/>= PV - conso base]
        HORIZON[Simuler horizon 4h<br/>Estimer qt avant T min]
        DECIDE{Fonction decider<br/>selon le mode}
        THERM[Modele thermique<br/>T t+1 = T t + delta]
        BATT[Bilan batterie<br/>charge / decharge]
        GRID[Bilan reseau<br/>offtake / intake]
    end

    subgraph SORTIES["RESULTATS"]
        KPI[KPIs<br/>Autoconso, injection evitee<br/>soutirage evite, economie]
        VISU[Visualisations<br/>Heatmap, load shifting<br/>waterfall, comparaison]
        EXPORT[Export CSV<br/>donnees simulees]
    end

    CSV --> LOAD
    BELPEX --> JOIN
    PARAMS --> PREP
    LOAD --> JOIN --> PREP
    PREP --> LOOP
    LOOP --> COP --> SURPLUS --> HORIZON --> DECIDE
    DECIDE --> THERM --> BATT --> GRID
    GRID --> LOOP
    GRID --> KPI --> VISU
    GRID --> EXPORT
```

## 2. Garde-fous communs a tous les modes

```mermaid
flowchart TD
    START([Chaque quart d heure]) --> TMIN{T ballon < T min ?}
    TMIN -->|Oui| URGENCE[PAC ON<br/>urgence confort]
    TMIN -->|Non| TMAX{T ballon >= T max ?}
    TMAX -->|Oui| PLEIN[PAC OFF<br/>ballon plein]
    TMAX -->|Non| CALC[Calculer<br/>surplus PV, COP, horizon<br/>qt avant T min]
    CALC --> MODE{Mode ?}
    MODE --> INJECTION[Mode Injection]
    MODE --> COST[Mode Cout]
    MODE --> HYBRID[Mode Hybrid]
    MODE --> SMART[Mode Smart]

    style URGENCE fill:#f87171,color:#fff
    style PLEIN fill:#94a3b8,color:#fff
    style INJECTION fill:#f97316,color:#fff
    style COST fill:#22d3ee,color:#000
    style HYBRID fill:#a78bfa,color:#fff
    style SMART fill:#34d399,color:#000
```

## 3. Mode INJECTION

```mermaid
flowchart TD
    INJ_START([Mode Injection]) --> FULL{Surplus PV >= conso PAC ?}

    FULL -->|Oui| TCONSIGNE{T < consigne ?}
    TCONSIGNE -->|Oui| PV_ON[PAC ON<br/>surplus PV gratuit]
    TCONSIGNE -->|Non| BESOIN{Besoin chaleur<br/>dans horizon ?}
    BESOIN -->|Oui| PRECH[PAC ON<br/>pre-chauffage PV]
    BESOIN -->|Non| SUFF[PAC OFF<br/>ballon suffisant]

    FULL -->|Non| URG2{Qt avant T min <= 2 ?}
    URG2 -->|Oui| ANTIC[PAC ON<br/>anticipation confort]
    URG2 -->|Non| FUTUR{Surplus PV futur<br/>dans horizon ?}
    FUTUR -->|Oui et ballon tient| ATTENTE[PAC OFF<br/>attente surplus futur]
    FUTUR -->|Non| URG4{Qt avant T min <= 4<br/>ET T < T min + 2 ?}
    URG4 -->|Oui| ANTIC2[PAC ON<br/>anticipation confort]
    URG4 -->|Non| OFF[PAC OFF<br/>pas de surplus]

    style PV_ON fill:#34d399,color:#000
    style PRECH fill:#34d399,color:#000
    style ANTIC fill:#f97316,color:#fff
    style ANTIC2 fill:#f97316,color:#fff
    style SUFF fill:#94a3b8,color:#fff
    style ATTENTE fill:#94a3b8,color:#fff
    style OFF fill:#94a3b8,color:#fff
```

## 4. Mode COUT

```mermaid
flowchart TD
    COST_START([Mode Cout]) --> COUT_CALC[Calculer cout marginal<br/>EUR/kWh thermique<br/>maintenant vs horizon]

    COUT_CALC --> NEG{Prix injection < 0 ?}
    NEG -->|Oui et surplus| EVITER[PAC ON<br/>eviter injection negative]

    NEG -->|Non| NEED{Besoin chaleur ?<br/>T < consigne OU<br/>T min dans horizon}
    NEED -->|Non| BSUFF[PAC OFF<br/>ballon suffisant]

    NEED -->|Oui| CHEAP{Prix offtake < 50%<br/>de la mediane future ?}
    CHEAP -->|Oui et T < consigne| SOUT[PAC ON<br/>soutirage pas cher]

    CHEAP -->|Non| OPT{Cout/kWh th now<br/>dans les 30% les<br/>moins chers du futur ?}
    OPT -->|Oui| COPT[PAC ON<br/>cout optimal]

    OPT -->|Non| LATER{Moments moins chers<br/>a venir et ballon tient ?}
    LATER -->|Oui| ATT[PAC OFF<br/>attente moins cher]
    LATER -->|Non| URG{Qt avant T min <= 2 ?}
    URG -->|Oui| ANTC[PAC ON<br/>anticipation confort]
    URG -->|Non| RENT[PAC OFF<br/>pas rentable]

    style EVITER fill:#f87171,color:#fff
    style SOUT fill:#22d3ee,color:#000
    style COPT fill:#22d3ee,color:#000
    style ANTC fill:#f97316,color:#fff
    style BSUFF fill:#94a3b8,color:#fff
    style ATT fill:#94a3b8,color:#fff
    style RENT fill:#94a3b8,color:#fff
```

## 5. Mode SMART (valeur nette)

```mermaid
flowchart TD
    SMART_START([Mode Smart]) --> COUT_NOW[Calculer cout chauffer<br/>MAINTENANT<br/>EUR/kWh thermique]
    COUT_NOW --> COUT_FUT[Calculer cout median<br/>chauffer PLUS TARD<br/>sur horizon 4h]

    COUT_FUT --> SNEG{Prix injection < 0<br/>et surplus ?}
    SNEG -->|Oui| SEVIT[PAC ON<br/>eviter injection negative]

    SNEG -->|Non| SNEED{Besoin chaleur ?<br/>T < consigne OU<br/>T min dans horizon}
    SNEED -->|Non| SOK[PAC OFF<br/>ballon OK]

    SNEED -->|Oui| SFULL{Surplus PV total ?}
    SFULL -->|Oui| SCOMP{Cout now < 1.5x<br/>cout futur ?}
    SCOMP -->|Oui| SGRAT[PAC ON<br/>surplus gratuit]
    SCOMP -->|Non| SRENT[PAC OFF<br/>injection plus rentable]

    SFULL -->|Non| SFAV{Cout now < 0.7x<br/>cout moyen futur ?}
    SFAV -->|Oui et T < consigne| SPRIX[PAC ON<br/>prix favorable]

    SFAV -->|Non| SURG{Qt avant T min <= 2 ?}
    SURG -->|Oui| SURGON[PAC ON<br/>urgence]
    SURG -->|Non| SFUTUR{Surplus PV futur<br/>et ballon tient ?}
    SFUTUR -->|Oui| SATT[PAC OFF<br/>attente surplus]
    SFUTUR -->|Non| SURG4{T min dans 4 qt<br/>et T < T min + 2 ?}
    SURG4 -->|Oui| SANTP[PAC ON<br/>anticipation]
    SURG4 -->|Non| SWAIT[PAC OFF<br/>attente]

    style SEVIT fill:#f87171,color:#fff
    style SGRAT fill:#34d399,color:#000
    style SPRIX fill:#34d399,color:#000
    style SURGON fill:#f97316,color:#fff
    style SANTP fill:#f97316,color:#fff
    style SOK fill:#94a3b8,color:#fff
    style SRENT fill:#94a3b8,color:#fff
    style SATT fill:#94a3b8,color:#fff
    style SWAIT fill:#94a3b8,color:#fff
```

## 6. Mode HYBRID

```mermaid
flowchart TD
    HYB_START([Mode Hybrid]) --> HNEG{Prix injection < 0<br/>et surplus ?}
    HNEG -->|Oui| HEVIT[PAC ON<br/>eviter injection negative]

    HNEG -->|Non| HNEED{Besoin chaleur ?}
    HNEED -->|Non| HBSUFF[PAC OFF<br/>ballon suffisant]

    HNEED -->|Oui| HCALC[Calculer score injection 0..1<br/>Calculer score cout 0..1<br/>Score final = poids x cout<br/>+ 1 - poids x injection]
    HCALC --> HSCORE{Score >= 0.5<br/>et T < T max ?}
    HSCORE -->|Oui| HON[PAC ON<br/>hybrid on]
    HSCORE -->|Non| HURG{Qt avant T min <= 2 ?}
    HURG -->|Oui| HANT[PAC ON<br/>anticipation confort]
    HURG -->|Non| HOFF[PAC OFF<br/>hybrid off]

    style HEVIT fill:#f87171,color:#fff
    style HON fill:#a78bfa,color:#fff
    style HANT fill:#f97316,color:#fff
    style HBSUFF fill:#94a3b8,color:#fff
    style HOFF fill:#94a3b8,color:#fff
```

## 7. Mode AUTO-ADAPTATIF

```mermaid
flowchart TD
    AUTO_START([Mode Auto-adaptatif]) --> CANDS[Lancer 6 candidats en parallele<br/>smart, injection, cost<br/>hybrid 0.3, hybrid 0.5, hybrid 0.7]
    CANDS --> SIM[Chaque candidat simule<br/>toute la periode<br/>avec sa propre logique]
    SIM --> EVAL[Chaque jour :<br/>comparer les couts reels cumules<br/>sur la fenetre glissante N jours]
    EVAL --> SELECT[Selectionner le candidat<br/>avec le cout reel le plus bas]
    SELECT --> ASSEMBLE[Assembler le resultat :<br/>a chaque qt, prendre les valeurs<br/>du candidat selectionne ce jour]

    style CANDS fill:#1a1d27,color:#e2e8f0,stroke:#34d399
    style SELECT fill:#34d399,color:#000
```

## 8. Modele thermique du ballon

```mermaid
flowchart LR
    subgraph APPORT["APPORT THERMIQUE"]
        PAC[PAC ON x COP x P elec]
    end

    subgraph PERTES["PERTES"]
        STAT[Pertes statiques<br/>k x T ballon - T ambiante]
        ECS[Soutirage ECS<br/>douches, vaisselle]
    end

    subgraph BALLON["BALLON"]
        T["T(t+1) = T(t) +<br/>(apport - pertes - ECS)<br/>/ capacite thermique"]
        CAP["Capacite = volume x 0.001163<br/>kWh/L/degre"]
    end

    PAC --> T
    STAT --> T
    ECS --> T
    CAP --> T

    style PAC fill:#34d399,color:#000
    style STAT fill:#f87171,color:#fff
    style ECS fill:#f97316,color:#fff
    style T fill:#22d3ee,color:#000
```

## 9. Bilan electrique et cascade de priorite

```mermaid
flowchart TD
    PV[Production PV] --> MAISON[Consommation maison<br/>prioritaire]
    MAISON --> SURPLUS{Surplus ?}

    SURPLUS -->|Oui| PAC_D{PAC decidee ON ?}
    PAC_D -->|Oui| PAC_CONSO[PAC consomme<br/>le surplus]
    PAC_D -->|Non| SURPLUS2{Reste du surplus}

    PAC_CONSO --> SURPLUS2
    SURPLUS2 --> BATT_C{Batterie active<br/>et SoC < max ?}
    BATT_C -->|Oui| CHARGE[Batterie charge<br/>x rendement]
    BATT_C -->|Non| INJECT[Injection reseau]
    CHARGE --> INJECT2{Reste ?}
    INJECT2 -->|Oui| INJECT

    SURPLUS -->|Non deficit| BATT_D{Batterie active<br/>et SoC > min ?}
    BATT_D -->|Oui| DECHARGE[Batterie decharge<br/>x rendement]
    BATT_D -->|Non| SOUTIR[Soutirage reseau]
    DECHARGE --> DEF2{Reste deficit ?}
    DEF2 -->|Oui| SOUTIR

    style PV fill:#fbbf24,color:#000
    style PAC_CONSO fill:#34d399,color:#000
    style CHARGE fill:#a78bfa,color:#fff
    style INJECT fill:#f97316,color:#fff
    style SOUTIR fill:#f87171,color:#fff
    style DECHARGE fill:#818cf8,color:#fff
```

## 10. Pipeline des prix Belpex

```mermaid
flowchart LR
    subgraph LOCAL["CSV LOCAUX"]
        CSV24[belpex_2024.csv]
        CSV25[belpex_2025.csv]
    end

    subgraph API["API ENTSO-E"]
        REQ[GET web-api.tp.entsoe.eu<br/>documentType=A44<br/>domain=10YBE----------2]
        XML[Parser XML<br/>TimeSeries > Period > Point]
    end

    subgraph TRAITEMENT["TRAITEMENT"]
        MERGE[Combiner + deduplicer]
        TZ[Convertir UTC > Brussels]
        FLOOR[floor_date par heure]
        JOIN_QT[Joindre aux<br/>quarts d heure]
        UNIT[EUR/MWh > EUR/kWh]
    end

    CSV24 --> MERGE
    CSV25 --> MERGE
    REQ --> XML --> MERGE
    MERGE --> TZ --> FLOOR --> JOIN_QT --> UNIT

    style CSV24 fill:#1a1d27,color:#e2e8f0,stroke:#22d3ee
    style CSV25 fill:#1a1d27,color:#e2e8f0,stroke:#22d3ee
    style REQ fill:#1a1d27,color:#e2e8f0,stroke:#a78bfa
    style UNIT fill:#34d399,color:#000
```

## Legende des couleurs

| Couleur | Signification |
|---------|--------------|
| Vert | PAC ON sur surplus PV (gratuit) ou decision favorable |
| Orange | PAC ON par anticipation/urgence (soutirage reseau) |
| Rouge | PAC ON forcee (urgence confort) ou perte |
| Cyan | Decision basee sur le cout |
| Violet | Mode hybrid |
| Gris | PAC OFF |
