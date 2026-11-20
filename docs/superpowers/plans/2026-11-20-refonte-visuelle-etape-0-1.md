# Refonte visuelle — étape 0 et 1 : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Poser le thème et l'interrupteur, puis livrer le nouvel écran principal, sans rien casser de l'existant.

**Architecture:** Un fichier `Theme.swift` porte tous les jetons des deux révisions et se lit depuis l'environnement. `ContentView` conserve l'état ; seule sa mise en page bifurque sur `uiRevision`. Le mode 1 doit rester indiscernable de l'app actuelle.

**Tech Stack:** SwiftUI, iOS 26, XcodeGen, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-20-refonte-visuelle-design.md`

## Global Constraints

- Bilingue : tout texte visible passe par `L("fr", "en")`. Aucune chaîne en dur.
- Aucune couleur hexadécimale hors de `Theme.swift`.
- `accessibilityReduceMotion` respecté : chaque ressort a un équivalent fondu de 0,15 s.
- Mode 1 = app actuelle à l'identique : codes `u/`, `r/`, `RG`, libellés longs, logo teinté orange quand la tuile est active, rayons 9/10/12/14, détent 420 pt.
- `Downloader.swift` ne reçoit aucune modification visuelle.
- Aucun test unitaire ne couvre `App/` : la vérification automatique est la compilation CI (`swift test` reste vert, puis `xcodebuild`).

## Review Focus

1. **Basculement sans relance.** Une lecture statique de `UserDefaults` depuis une vue ne repeindrait rien. Le thème doit venir de l'environnement, lu une seule fois à la racine.
2. **Texte à taille d'accessibilité.** La pilule « Télécharger » reste-t-elle lisible en AX5 sans troncature absurde ?
3. **Mode sombre.** Un fond noir pur avec une surface `#1C1C1E` doit garder un contraste suffisant sur les textes secondaires.
4. **Réduire les animations.** Aucun ressort ne doit subsister quand l'option est active.
5. **Feuilles perdues à l'extraction.** Déplacer la mise en page dans un fichier ne doit laisser aucun `.sheet` orphelin derrière.

---

### Task 1: Extraire la mise en page actuelle sans rien changer

Préalable à toute bifurcation : isoler la mise en page pour que deux variantes puissent coexister. Aucun test unitaire possible ; le critère est « l'écran est identique ».

**Files:**
- Modify: `App/RedditMediaPocketApp.swift` (contenu de `ContentView.body`, lignes ~60-160)

**Interfaces:**
- Consumes: rien.
- Produces: `private var classicMainScreen: some View` dans `ContentView`, contenant exactement le `VStack` actuel et ses modificateurs visuels ; `body` devient `NavigationStack { classicMainScreen }` plus les modificateurs de feuilles et d'alertes, qui restent attachés au même niveau.

- [ ] **Step 1:** Déplacer le `VStack` actuel et ses modificateurs (padding, toolbar, safeAreaInset) dans `private var classicMainScreen: some View`, sans changer un seul littéral.
- [ ] **Step 2:** Laisser dans `body` le `NavigationStack`, la liste des `.sheet`, `.confirmationDialog`, `.alert`, `.tint`, `.errorAlert` — inchangés et dans le même ordre.
- [ ] **Step 3:** Vérifier qu'aucun `.sheet` ne reste sur `classicMainScreen` (les feuilles appartiennent à `body`).
- [ ] **Step 4:** Pousser et attendre la CI verte (`gh run watch`).
- [ ] **Step 5:** Commit.

```bash
git commit -m "refactor: extraire la mise en page de l'ecran principal (aucun changement visuel)"
```

---

### Task 2: `Theme.swift`, jetons des deux révisions et injection

**Files:**
- Create: `App/Theme.swift`
- Modify: `App/RedditMediaPocketApp.swift` (racine `WindowGroup`)

**Interfaces:**
- Produces:
  - `struct Theme` avec les propriétés `background`, `surface`, `separator`, `accent`, `primaryText`, `secondaryText` (toutes `Color`), `cornerField`, `cornerCard`, `cornerSheet` (`CGFloat`), `sheetDetent` (`PresentationDetent`), `usesFloatingToolbar` (`Bool`).
  - `static let classic` et `static let modern` (`Theme`).
  - `static func resolved(revision: Int) -> Theme` — `revision >= 2 ? .modern : .classic`.
  - `enum ThemeKey: EnvironmentKey` et l'extension `EnvironmentValues.theme`.

- [ ] **Step 1:** Créer `App/Theme.swift` avec les deux jeux de jetons, valeurs du tableau de la spec.
- [ ] **Step 2:** `static func resolved(revision:)` renvoie `.classic` pour toute valeur autre que 2.
- [ ] **Step 3:** À la racine, `@AppStorage("uiRevision") private var uiRevision = 2`, puis `.environment(\.theme, Theme.resolved(revision: uiRevision))`.
- [ ] **Step 4:** Pousser, CI verte.
- [ ] **Step 5:** Commit.

```bash
git commit -m "feat: jetons de theme des deux revisions, injectes par l'environnement"
```

---

### Task 3: Interrupteur dans Réglages → Apparence

**Files:**
- Modify: `App/RedditMediaPocketApp.swift` (`DownloadSettings`)

**Interfaces:**
- Consumes: `@AppStorage("uiRevision")`.
- Produces: une `Section` « Apparence » en tête des réglages, avec un `Toggle` lié à `uiRevision` par une valeur dérivée (`uiRevision == 2`).

- [ ] **Step 1:** Ajouter la section en tête de la `List` des réglages, titre `L("Apparence", "Appearance")`.
- [ ] **Step 2:** `Toggle(L("Nouvelle interface", "New interface"), isOn: Binding(get: { uiRevision == 2 }, set: { uiRevision = $0 ? 2 : 1 }))`.
- [ ] **Step 3:** Sous-titre `L("Revenir à l'ancien affichage à tout moment.", "Switch back to the previous look at any time.")`.
- [ ] **Step 4:** Pousser, CI verte, et vérifier sur appareil que basculer repeint l'app **sans relance**.
- [ ] **Step 5:** Commit.

```bash
git commit -m "feat: interrupteur d'apparence dans les reglages"
```

---

### Task 4: Composeur moderne et pilule d'action

**Files:**
- Modify: `App/RedditMediaPocketApp.swift` (`classicMainScreen` → nouvelle `modernMainScreen`)

**Interfaces:**
- Consumes: `@Environment(\.theme)`, `model.running`, `cannotStart`, `start()`.
- Produces: `private var modernMainScreen: some View` et `private var modernComposer: some View`.

- [ ] **Step 1:** `modernComposer` : une carte de surface, rayon `theme.cornerCard`, contenant le bouton source, le champ et la pilule d'action sur une ligne ; le champ perd son fond propre.
- [ ] **Step 2:** La pilule porte un libellé : `L("Télécharger", "Download")` ou `L("Arrêter", "Stop")`, en `headline`, `lineLimit(1)`, `minimumScaleFactor(0.8)`, fond `theme.accent`, hauteur 44.
- [ ] **Step 3:** `body` choisit : `theme.usesFloatingToolbar ? modernMainScreen : classicMainScreen`. En mode 1, rien ne change.
- [ ] **Step 4:** En `reduceMotion`, aucune animation ; sinon ressort 0,28/0,86 sur le changement d'état de la pilule.
- [ ] **Step 5:** Pousser, CI verte, essai sur appareil dans les deux modes, en clair et en sombre.
- [ ] **Step 6:** Commit.

```bash
git commit -m "feat: composeur moderne et pilule d'action de l'ecran principal"
```

---

### Task 5: Tuiles de source — libellés courts, logos à pleine intensité

C'est la demande explicite du commanditaire, et la grille elle-même ne bouge pas.

**Files:**
- Modify: `App/RedditMediaPocketApp.swift` (`SourceGridCard`, `SourceSelection`)

**Interfaces:**
- Consumes: `@Environment(\.theme)`.
- Produces: `static func shortLabel(_ kind: SourceKind) -> String` dans `SourceSelection`, et `static func tileShowsCode(_ theme: Theme) -> Bool` renvoyant `true` en mode classique.

- [ ] **Step 1:** `shortLabel` : `Reddit`, `Subreddit`, `Sauvegardés`/`Saved`, `RedGifs`, `X-Fetish`, `X`, `TikTok`, `TikTok sauvegardés`/`TikTok saved`, `Instagram`.
- [ ] **Step 2:** En mode 2, la carte affiche le logo (teinte `theme.primaryText`, **jamais** l'accent) puis `shortLabel` en `caption` ; le `Text(face)` disparaît et `spoken` part en `accessibilityLabel` — déjà porté par la carte.
- [ ] **Step 3:** En mode 2, la sélection se marque par la surface, un contour `theme.accent` de 1,5 pt et une échelle de 1,03 ; **la teinte du logo ne change pas**.
- [ ] **Step 4:** En mode 1, tout reste identique à aujourd'hui : `Text(face)`, `Text(spoken)`, logo teinté orange quand actif.
- [ ] **Step 5:** Pousser, CI verte, vérifier sur appareil les deux modes.
- [ ] **Step 6:** Commit.

```bash
git commit -m "feat: tuiles de source epurees, logos a pleine intensite en mode moderne"
```

---

### Task 6: Passe de vérification des deux modes

**Files:** aucun (vérification seule).

- [ ] **Step 1:** Sur appareil, mode 2 : lancer un parcours TikTok `ts`, vérifier la pilule « Arrêter » et l'absence de régression de téléchargement.
- [ ] **Step 2:** Basculer en mode 1 : vérifier codes `u/`, libellés longs, logo orange sur tuile active, détent 420.
- [ ] **Step 3:** Activer Réduire les animations : aucune animation résiduelle.
- [ ] **Step 4:** Régler la taille de texte au maximum : la pilule reste lisible.
- [ ] **Step 5:** Consigner dans la release ce qui a été vu et ce qui reste à voir.

## Hors périmètre de ce plan

Feuille de sources (étape 2), galerie et barre d'outils (étape 3), écrans secondaires (étape 4). Ils feront l'objet de plans séparés, une fois l'interrupteur prouvé sur appareil.
