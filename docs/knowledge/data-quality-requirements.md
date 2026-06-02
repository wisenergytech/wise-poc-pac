# Exigences qualite donnees energie — Wise Energy

*Version 1.0 — 2026-06-02*
*Base sur les lecons apprises du site K-0001 Profondeville*

## Objectif

Ce document definit les exigences minimales de qualite des donnees energetiques que Wise Energy doit recevoir d'un partenaire (installateur, operateur, fabricant de controleur) pour pouvoir executer une optimisation fiable du pilotage PAC.

**Sans ces donnees, nous ne pouvons pas garantir la fiabilite des resultats chiffres (EUR economises, kWh decales, CO2 evite).**

---

## 1. Schema electrique du site

Avant toute analyse de donnees, nous avons besoin d'un **schema unifilaire simplifie** montrant :

- [ ] Point de raccordement reseau (compteur ORES / gestionnaire de reseau)
- [ ] Emplacement de chaque compteur electrique (ce qu'il mesure, ce qu'il ne mesure pas)
- [ ] Circuit d'alimentation de chaque PAC (monophase / triphase, en amont ou en aval du compteur reseau)
- [ ] Point de raccordement de l'installation PV (en amont ou en aval du compteur, avant ou apres la chaufferie)
- [ ] Perimetres de mesure : quel compteur voit quelles charges

**Pourquoi** : sans ce schema, il est impossible de savoir si un compteur mesure la PAC seule, la chaufferie entiere, ou tout le batiment. Nous avons perdu plusieurs semaines sur Profondeville a cause d'une ambiguite sur le perimetre du compteur ORES.

---

## 2. Dictionnaire de donnees

Pour chaque colonne/variable transmise dans le systeme de monitoring (BigQuery, API, CSV), nous avons besoin de :

| Information | Exemple | Pourquoi |
|-------------|---------|----------|
| **Nom de la colonne** | `EM_PAC_301_ENER_P_IMP_T12_PERIOD` | Identification unique |
| **Grandeur physique** | Energie electrique active importee | Distinguer energie, puissance, index, temperature, debit... |
| **Unite** | **Wh** (pas kWh, pas W, pas "kW") | Une erreur d'unite = resultats faux d'un facteur 1000 |
| **Type de valeur** | Index cumulatif / delta par periode / instantane | Un index cumulatif se traite differemment d'un delta |
| **Pas de temps** | 5 min | Pour convertir puissance ↔ energie |
| **Perimetre de mesure** | Compresseur PAC 3.01 uniquement | Distinguer compresseur, auxiliaires, circuit de commande |
| **Timezone** | UTC / Europe/Brussels | Un decalage de 2h fausse toute correlation |

**Pourquoi** : sur Profondeville, `EM_PAC_301_ENER_P_IMP_PERIOD` etait decrite comme "the power" mais le nom suggere "energy per period". L'ambiguite nous a fait interpreter des Watts comme des kWh, produisant un bilan energetique aberrant (48x le reel).

---

## 3. Donnees requises par equipement

### 3a. Par pompe a chaleur

| Donnee | Unite | Pas de temps | Priorite | Commentaire |
|--------|-------|-------------|----------|-------------|
| **Energie electrique consommee** | kWh ou Wh (preciser) | <= 15 min | Obligatoire | Index cumulatif prefere (robuste aux trous). Si delta par periode, preciser la duree exacte de la periode. |
| **Puissance electrique active** | kW ou W (preciser) | <= 15 min | Recommande | Pour verification croisee : E = P × dt |
| **Courant par phase** | A | <= 15 min | Recommande | Pour verification V × I × PF = P |
| **Tension par phase** | V | <= 15 min | Optionnel | Verification croisee |
| **Facteur de puissance** | sans unite (0-1) | <= 15 min | Optionnel | Verification croisee |
| **Statut on/off** | boolean | <= 5 min | Recommande | Pour identifier les periodes de fonctionnement |
| **Temperature source (evaporateur)** | °C | <= 15 min | Obligatoire | T_ext pour ASHP, T_sol pour GSHP — necessaire pour le COP |
| **Temperature sortie (condenseur)** | °C | <= 15 min | Recommande | Pour estimer le COP reel |
| **COP mesure** | sans unite | <= 15 min | Ideal | Si le controleur le calcule — sinon on l'estime |

**Point critique** : s'assurer que le compteur electrique mesure bien le **compresseur** (la charge principale), pas seulement le circuit de commande/auxiliaires. Verification simple : le courant doit etre de l'ordre de **10-50 A** pour une PAC de 5-50 kW, pas 0.1 A.

### 3b. Ballon thermique

| Donnee | Unite | Pas de temps | Priorite | Commentaire |
|--------|-------|-------------|----------|-------------|
| **Temperature haut de ballon** | °C | <= 15 min | Obligatoire | Temperature de depart reseau |
| **Temperature bas de ballon** | °C | <= 15 min | Recommande | Pour estimer la stratification |
| **Volume du ballon** | Litres | Fixe | Obligatoire | Pour calculer la capacite thermique |

### 3c. Compteur reseau (ORES / GRD)

| Donnee | Unite | Pas de temps | Priorite | Commentaire |
|--------|-------|-------------|----------|-------------|
| **Index soutirage** | kWh (cumulatif) | <= 15 min | Obligatoire | Consommation depuis le reseau |
| **Index injection** | kWh (cumulatif) | <= 15 min | Obligatoire | Injection PV vers le reseau |
| **Perimetre exact** | — | Fixe | Obligatoire | Quelles charges sont en aval de ce compteur ? La PAC en fait-elle partie ? |

### 3d. Installation PV

| Donnee | Unite | Pas de temps | Priorite | Commentaire |
|--------|-------|-------------|----------|-------------|
| **Production PV** | kWh ou Wh | <= 15 min | Obligatoire | Index cumulatif ou delta |
| **Puissance crete installee** | kWc | Fixe | Obligatoire | Pour le scaling |
| **Point de raccordement** | — | Fixe | Obligatoire | En amont ou aval du compteur reseau ? Avant ou apres la chaufferie ? |

**Point critique** : si le compteur PV est celui de l'onduleur, verifier qu'il est synchronise temporellement avec les autres compteurs. Sur Profondeville, le compteur onduleur (FusionSolar) est desynchronise avec ORES — inutilisable pour le bilan.

---

## 4. Exigences de qualite

### 4a. Synchronisation temporelle

- [ ] **Tous les compteurs doivent etre sur la meme base de temps** (UTC ou heure locale, mais identique)
- [ ] **Preciser explicitement la timezone** de chaque source
- [ ] Si les compteurs ont des pas de temps differents (ex: 5 min vs 15 min), le preciser
- [ ] Pas de decalage variable entre sources (ex: fenetre d'agregation differente selon le jour)

**Pourquoi** : un decalage de 5 min entre le compteur PV et le compteur reseau rend le calcul d'autoconsommation impossible (valeurs negatives).

### 4b. Continuite des donnees

- [ ] **Pas de trous > 1h** sans signalement
- [ ] Si un compteur est installe en cours de periode, preciser la date exacte de debut des donnees
- [ ] Les resets d'index doivent etre documentes (un index qui passe de 100 000 a 0 = reset, pas une consommation negative)

### 4c. Verification croisee

Avant livraison, le partenaire devrait verifier :

- [ ] **Bilan nocturne** : la nuit (pas de PV), soutirage reseau ≈ somme des consos PAC + auxiliaires. Si ratio > 2x ou < 0.5x, il y a un probleme de perimetre ou d'unite.
- [ ] **Coherence P-E** : energie par periode ≈ puissance × duree_periode. Si ecart > 10%, l'unite est probablement fausse.
- [ ] **Coherence V-I-P** : puissance ≈ V × I × PF × √3 (triphase). Si le courant est < 1 A et la puissance declaree > 1 kW, le compteur ne mesure pas le compresseur.
- [ ] **Ordre de grandeur** : une PAC de 40 kWth / COP 4 consomme ~10 kW elec = ~40 A sous 230V triphase. Si le compteur montre 0.1 A, il mesure le controleur, pas le compresseur.

---

## 5. Format de livraison

| Critere | Exigence |
|---------|----------|
| **Format** | CSV (UTF-8, separateur virgule) ou acces BigQuery/API |
| **Pas de temps** | 15 min (ideal) ou 5 min (acceptable, sera agree a 15 min) |
| **Horodatage** | Colonne `timestamp` en ISO 8601 (`YYYY-MM-DD HH:MM:SS`) avec timezone explicite |
| **Valeurs manquantes** | `NA` ou cellule vide (pas 0 — 0 est une mesure valide) |
| **Unites** | Documentees dans un dictionnaire joint (cf. section 2) |
| **Periode minimale** | 30 jours pour un POC, 1 an pour une analyse saisonniere |

---

## 6. Checklist de reception

A chaque reception de donnees, Wise verifie :

- [ ] Dictionnaire de donnees recu et complet
- [ ] Schema electrique recu
- [ ] Timezone identifiee et coherente entre sources
- [ ] Bilan nocturne coherent (soutirage ≈ conso PAC)
- [ ] Coherence V × I × PF ≈ P declaree
- [ ] Pas de trous > 1h non documentes
- [ ] Unites verifiees par cross-check (pas fiees aux noms de colonnes)

**Si un de ces points echoue, signaler au partenaire AVANT de commencer l'analyse.**
