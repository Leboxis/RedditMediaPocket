# Refonte totale du frontend — diagnostic + directions

Date : 2026-11-20
Statut : **proposé — en attente du choix d'une direction** (rien n'est codé avant ce choix)

## Contexte du projet

- **App** : Reddit Media Pocket — prototype iPhone iOS 26+ (LiveContainer), SwiftUI, bilingue FR/EN via `L()`.
- **Type de produit** : outil d'archivage utilitaire — télécharger en masse les médias de sources Reddit / RedGifs / X-Fetish / X / TikTok / Instagram.
- **Cible** : power users, usage en mobilité, une main sur le téléphone.
- **Action principale (job n°1)** : « archiver les médias d'une source en un appui » — coller un nom ou un lien, appuyer, suivre, retrouver.
- **Contraintes** : iOS 26+, SwiftUI (NavigationStack / TabView / Observation), light **et** dark obligatoires, aucune charte imposée (l'orange actuel est une identité, pas une contrainte), CI = seul juge de compilation (`swift test` + build IPA sur push main).
- **Historique** : la « refonte visuelle » du 2026-11-20 (`Theme.swift` à deux révisions, inspiration Instagram) a été **revertie** (e68aa9f). Cette démarche ne la reprend pas : pas de double interface, pas de relooking de l'existant — réinvention de zéro, le design actuel n'est qu'un diagnostic.

## 1. Diagnostic de l'app actuelle

### 1.1 Inventaire fonctionnel — le passe-partout (rien ne disparaît)

Toutes les features ci-dessous restent **atteignables** après la réinvention ; la logique métier (`Downloader`, sessions, `MediaCore`, persistance) est branchée sur les nouvelles vues telles quelles.

| Zone | Features à conserver |
|---|---|
| Commande | choix de la source parmi 9 (`u/`, `r/`, `RG`, `♥`, `x/`, `tw`, `tt`, `ts`, `ig`) ; saisie nom **ou lien collé** (détection auto des URL) ; lancer / arrêter ; options selon la source (tri subreddit, type média X-Fetish, cible sauvegardés TikTok) ; indices « session requise » |
| Suivi | pastilles de collections avec badge `+N`, reprendre, supprimer ; métriques (nb médias, taille, découverts) ; barre de progression ; statut ; bannière « archive incomplète » |
| Bibliothèque | galerie : recherche, tri, filtre rapide images/vidéos ; grille de vignettes ; sélection multiple (tout cocher, enregistrer dans Photos, supprimer le lot) ; menu contextuel (sélectionner, infos, supprimer) ; aperçu plein écran (pager, zoom, vidéo, GIF) ; fiche info ; export (share sheet) |
| Navigation secondaire | réglages ; posts sauvegardés Reddit (feed/liste + téléchargement) ; comptes suivis ; filtres de téléchargement ; journaux (logs + échecs) ; test de santé des sources ; upload kDrive (bannière, action par collection, sélecteur de dossier, flux d'upload) ; picker des sauvegardés TikTok |
| Réglages | langue FR/EN ; téléchargements simultanés ; morceaux par vidéo X-Fetish ; connexions Reddit / X / TikTok / Instagram (fenêtre WebView + déconnexion) ; kDrive (jeton, dossier) ; quota d'espace disque ; « tout supprimer » (destructif, confirmé) |

### 1.2 Échecs UX constatés, classés par priorité

| Priorité | Problème constaté | Pourquoi ça coince |
|---|---|---|
| P1 | **Mono-écran empilé** : 8 rangées (saisie, options, indice, collections, métriques, progression, statut, bannière) avant la galerie | L'outil (la commande) masque le résultat (les médias) ; aucune hiérarchie entre « agir » et « voir » |
| P1 | **Toolbar à 8 items** (4 leading + 4 trailing), kDrive relégué dans « … » | Trop d'actions de même niveau ; l'upload cloud, pourtant central pour l'archivage, est caché |
| P1 | **Zéro design system** : `.orange` littéral partout, `cornerRadius` 9/10/14 éparpillés, espacements magiques (3, 6, 7, 8, 10, 11, 13…), dark mode = gris système inversé | Aucun token ; chaque écran réinvente ses valeurs ; dark mode pas pensé, juste hérité |
| P2 | **Aucune architecture d'information** : réglages, sauvegardés, suivis, filtres, logs, échecs, diagnostic — tout part en sheet depuis le seul écran | L'app n'a pas de « chez soi » ; on ne sait jamais où l'on est ni où revenir |
| P2 | **États pauvres** : loading = `ProgressView` + texte, erreur = `.alert` générique « Pocket », vide = icône + phrase | Pas de skeleton (>1 s), pas de retry inline, pas de toast de succès |
| P3 | **Sources cryptiques** : `u/`, `r/`, `RG`, `♥`, `ts` exposés tels quels | L'utilisateur doit apprendre un alphabet interne |
| P3 | Métriques affichées par `opacity(0/1)` ; pastille d'état sur le bouton de téléchargement (point coloré seul) | L'information dépend de la couleur seule et apparaît/disparaît sans transition sémantique |

### 1.3 Tableau de réinvention (Problème → Décision → Pourquoi)

| Problème constaté | Décision de réinvention | Pourquoi |
|---|---|---|
| Outil et contenu mélangés sur un seul écran | Séparer « commander » et « consulter » en onglets dédiés | Une action primaire par écran ; la galerie cesse d'être sous la commande |
| Toolbar saturée | TabView ≤ 5 onglets (icône + libellé) ; actions contextuelles dans les écrans ou menus | Navigation prévisible, geste système préservé |
| Valeurs magiques partout | Design system à tokens (couleurs sémantiques Asset Catalog Any+Dark, échelle d'espacement 4 pt, rayons S/M/L, élévations, timings) ; zéro littéral dans les vues | Maintenable, testable en light/dark, conforme au garde-fou anti-filler |
| Abréviations de sources | Noms complets + icône SF Symbols cohérents (« Profil Reddit », « Subreddit »…) | Lisible au premier abord, VoiceOver propre |
| États texte/alert | Skeleton > 1 s, états vide utiles avec action, erreur + retry, toast de succès, undo sur le destructif | Checklist « tous les états » |
| Point coloré seul pour l'état | Statut toujours accompagné d'icône + texte | Accessibilité : jamais la couleur seule |

## 2. Règles non négociables appliquées à la réinvention

Tokens obligatoires partout (zéro `Color(red:)` / `cornerRadius(14)` dans les vues) · SF Symbols uniquement, poids de trait cohérent · cibles ≥ 44 pt avec `contentShape` · une action primaire par écran · contrastes ≥ 4,5:1 (3:1 grands titres) testés en light **et** dark · Dynamic Type (wrap, jamais de troncature silencieuse) · springs `bounce 0,1–0,2`, sorties plus rapides que les entrées, jamais de `scale(0)`, `scaleEffect(0.97)` au toucher, animations interruptibles, `@Environment(\.accessibilityReduceMotion)` respecté · haptique seulement sur confirmation/destructif/succès · `NavigationStack` avec retour prévisible, sheets fermables · formulaires : label visible, validation au blur, erreur sous le champ avec cause + solution · iOS 26 (NavigationStack, Observation) · previews light + dark + texte XXL · **toute feature du §1.1 reste atteignable** · tout nouveau texte passe par `L()` (FR/EN).

## 3. Trois directions de réinvention

### Direction A — « Console d'archive » (ton : technique / austère, dark-first)

**Concept.** L'app comme une console d'archivage sobre : fond profond, un seul accent orange, chiffres monospaced, état du transfert toujours visible.

- **Palette / tokens clés** : `surface` noir profond (Any #F5F5F4 → Dark #0B0B0C, jamais d'inversion), `surfaceElevated` pour cartes/sheets, `onSurface` blanc cassé, `onSurfaceMuted` gris désaturé, `accent` = orange (identité conservée), `error` rouge système. Contrastes testés séparément en light/dark.
- **Tokens** : espacement en pas de 4 (4/8/12/16/24/32) ; rayons S=8, M=12, L=20 ; élévation unique (ombre douce niveau sheet uniquement) ; timings : micro-UI < 250 ms, sheets 250–400 ms, spring `duration 0.4, bounce 0.15`.
- **Navigation** : `TabView` 4 onglets — **Nouveau** (la commande), **Bibliothèque** (galerie plein cadre), **Activité** (progression, logs, journal des échecs), **Réglages** (connexions, kDrive, stockage, langue, diagnostic). Onglet actif en accent, icône + libellé.
- **Signature visuelle** : la **console de transfert** — bandeau fixe en haut de l'onglet Nouveau avec métriques monospaced (`12 médias · 1,4 Go · 37 repérés`) et fine barre de progression ; la galerie en plein cadre (grille 3 colonnes, gaps 2 pt, zéro carte autour des vignettes).
- **Écran-matrice croqué** (onglet Nouveau) :

```swift
// Croquis — tokens supposés : DS.accent, DS.surface, DS.space(_:), DS.radiusM…
struct NewDownloadScreen: View {
    @StateObject private var model = Downloader()
    var body: some View {
        NavigationStack {
            VStack(spacing: DS.space(4)) {
                SourceGridCompact(selection: $model.sourceKind)   // 9 cartes, noms complets + SF Symbols
                TextField("Nom ou lien collé", text: $model.username)
                    .textFieldStyle(.console)                        // fond surfaceElevated, rayon M
                Button { model.start() } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(DS.accent, in: RoundedRectangle(cornerRadius: DS.radiusM))
                        .foregroundStyle(DS.onAccent)
                }
                TransferConsole(metrics: model.metrics)            // chiffres monospaced + fine ProgressView
            }
            .padding(DS.space(4))
            .background(DS.surface)
        }
    }
}
```

### Direction B — « Bibliothèque éditoriale » (ton : éditorial, light-first)

**Concept.** L'app comme une bibliothèque personnelle : les collections sont des « rayons » (grandes cartes avec couverture), la galerie est un mur ; typographie forte, espaces généreux, une idée par écran.

- **Palette / tokens clés** : `paper` #FAFAF7 (light) / #141414 (dark), `ink` quasi-noir / blanc cassé, `accent` orange brûlé, cartes `surface` avec ombre douce unique. Tokens sémantiques uniquement, variantes Any + Dark dans l'Asset Catalog.
- **Tokens** : espacement 4/8/16/24/40 ; rayons S=8, M=14, L=24 ; typo : titres `system(.title2, weight: .bold)`, corps `system(.body)`, labels `system(.caption, weight: .medium)` — jamais de taille fixe bloquante.
- **Navigation** : `TabView` 3 onglets — **Collections** (accueil = les rayons), **Télécharger** (la commande, en sheet pleine hauteur depuis un bouton fixe), **Réglages**. Sauvegardés Reddit, suivis, activité, filtres vivent en feuilles depuis la barre d'une collection.
- **Signature visuelle** : la **carte-rayon** — couverture (dernière miniature de la collection), nom en titre, compteurs (`128 médias · 3,2 Go · +12`), chevron ; toucher ouvre le détail de la collection (galerie + reprendre / exporter / kDrive / supprimer).
- **Écran-matrice croqué** (onglet Collections) :

```swift
// Croquis — tokens supposés : DS.paper, DS.ink, DS.accent, DS.space(_:), DS.radiusL…
struct CollectionsHome: View {
    @StateObject private var model = Downloader()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: DS.space(4)) {
                    ForEach(model.collections) { collection in
                        NavigationLink(value: collection) {
                            HStack(spacing: DS.space(4)) {
                                CoverThumb(url: collection.lastMediaURL)       // rayon DS.radiusL
                                VStack(alignment: .leading, spacing: DS.space(1)) {
                                    Text(collection.displayName).font(.title3.weight(.bold)).foregroundStyle(DS.ink)
                                    Text("\(collection.count) médias · \(collection.size)")
                                        .font(.caption).foregroundStyle(DS.inkMuted)
                                }
                                Spacer()
                                if collection.freshCount > 0 { Badge("+\(collection.freshCount)") }
                                Image(systemName: "chevron.right").foregroundStyle(DS.inkMuted)
                            }
                            .padding(DS.space(4))
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusL))
                        }
                    }
                }
                .padding(DS.space(4))
            }
            .background(DS.paper)
            .navigationTitle("Bibliothèque")
        }
    }
}
```

### Direction C — « Hub de commandes » (ton : utilitaire clair, l'action d'abord)

**Concept.** Un seul geste : coller, appuyer. L'accueil est une grande zone de commande centrée ; la bibliothèque devient un onglet plein écran à part.

- **Palette / tokens clés** : fond système groupé (light) / fond sombre natif (dark), `accent` orange plein pour le seul bouton principal, `surface` secondaire pour champs et cartes ; paire approuvée accent/texte-blanc ≥ 4,5:1.
- **Tokens** : espacement 4/8/12/16/24/32 ; rayons S=8, M=12, L=20 (bouton principal en capsule) ; élévation : ombre niveau sheet seulement ; timings : micro-UI < 250 ms, spring `duration 0.45, bounce 0.12`, sortie ≈ 60 % de l'entrée.
- **Navigation** : `TabView` 4 onglets — **Télécharger** (commande centrée : chips de source lisibles, champ large, bouton principal XXL), **Bibliothèque** (recherche/tri/filtre + grille), **Activité** (progression, logs, échecs, uploads kDrive), **Réglages** (langue, connexions, kDrive, stockage, diagnostic, tout supprimer).
- **Signature visuelle** : le **bouton-anneau** — bouton principal circulaire 64 pt avec icône `arrow.down`, entouré d'un anneau de progression quand un transfert tourne ; état lisible sans couleur (icône + libellé « En cours · 12/37 »).
- **Écran-matrice croqué** (onglet Télécharger) :

```swift
// Croquis — tokens supposés : DS.background, DS.accent, DS.onAccent, DS.space(_:), DS.radiusM…
struct DownloadHub: View {
    @StateObject private var model = Downloader()
    var body: some View {
        NavigationStack {
            VStack(spacing: DS.space(6)) {
                SourceChips(selection: $model.sourceKind)              // noms complets : Profil Reddit, Subreddit…
                TextField("Nom ou lien collé", text: $model.username)
                    .padding(DS.space(4))
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radiusM))
                Button { model.running ? model.stop() : model.start() } label: {
                    ZStack {
                        Circle().stroke(DS.accent.opacity(0.25), lineWidth: 4)
                        ProgressRing(fraction: model.progress).stroke(DS.accent, lineWidth: 4)
                        Image(systemName: model.running ? "stop.fill" : "arrow.down")
                            .font(.system(size: 26, weight: .semibold)).foregroundStyle(DS.onAccent)
                    }
                    .frame(width: 64, height: 64)
                    .background(DS.accent, in: Circle())
                    .scaleEffect(model.pressed ? 0.97 : 1)             // feedback < 100 ms
                }
                .accessibilityLabel(model.running ? "Arrêter — \(model.count)/\(model.discovered)" : "Télécharger")
                Text(model.status).font(.caption).foregroundStyle(DS.onSurfaceMuted)
            }
            .padding(DS.space(4))
            .background(DS.background)
        }
    }
}
```

## 4. Méthode après le choix

1. **Design system d'abord** : tokens (couleurs Asset Catalog Any+Dark, typo système, espacement 4 pt, rayons, élévations, timings) dans un fichier dédié — zéro valeur magique ensuite.
2. **Écran-matrice validé**, porteur de la signature, avec previews light + dark + Dynamic Type XXL.
3. **Écran par écran**, chacun livré avec la checklist cochée (contrastes light/dark, cibles ≥ 44 pt, une action primaire, labels/erreurs/undo, tokens uniquement, SF Symbols, animations cohérentes et réduites en Reduce Motion, états loading/vide/erreur/succès, navigation prévisible, **toutes les features du §1.1 atteignables**).
4. Vérification : `swift test` + build CI sur chaque push.

**Prochaine étape : choisir A, B ou C.** Ensuite, plus aucune déviation de la direction choisie.

## 5. Livré — direction A « Console d'archive » (2026-11-20)

Choix retenu : **A**. Implémentation en commits sur `main`, CI verte à chaque push (build IPA + release publiées) :

- `759e1da` — ce document (diagnostic + directions).
- `b832761` + `05ca3c6` — design system `DS` (10 couleurs Asset Catalog Any+Dark, espacement 4 pt, rayons S/M/L, élévation, ressorts) + shell `TabView` 4 onglets (Nouveau / Bibliothèque / Activité / Réglages) + écran-matrice **Nouveau** (commande plein largeur + console de transfert : métriques monospaced, progression, statut, bannière archive incomplète).
- `4985f63` — onglet **Bibliothèque** réinventé : galerie plein cadre (gouttière `DS.gridGap`, zéro carte), skeleton au chargement, états vide/recherche en `ContentUnavailableView` avec action « Choisir une source », barre de sélection en carte `surfaceElevated`.
- `eaf13d3` — feuilles du flux Nouveau en tokens (filtres de téléchargement, picker sauvegardés TikTok).
- `bc18d54` — token-ification `DS` de toutes les vues restantes (sauvegardés, suivis, logs, journal des échecs, diagnostics, kDrive, lecteurs média plein écran).

Checklist par écran livré : contrastes ≥ 4,5:1 light **et** dark (paires `onSurface`/`onSurfaceMuted`/`onAccent` calculées) · cibles ≥ 44 pt (`contentShape` sur lignes et icônes de menu) · une action primaire par écran (bouton Télécharger plein largeur) · labels visibles, erreurs sous le champ, destructif rouge + confirmation · tokens uniquement (les seules couleurs littérales restantes sont les teintes de marque des lignes de connexion X/TikTok/Instagram) · SF Symbols partout · springs `DS.spring`/`DS.micro`, `scaleEffect(0.97)` au toucher, `accessibilityReduceMotion` respecté · états loading (skeleton) / vide (action) / erreur (alert + retry) présents · TabView 4 onglets icône+libellé, sheets fermables · **toutes les features du §1.1 atteignables** (commande 9 sources, liens collés, options par source, collections +N, métriques/progression/statut/bannière, galerie recherche/tri/filtre/sélection multiple/aperçu/infos/export, sauvegardés Reddit, comptes suivis, filtres, logs, échecs, diagnostic, kDrive, connexions 4 services, quota disque, tout supprimer) · previews light + dark + accessibility XXL sur les écrans-matrices.
