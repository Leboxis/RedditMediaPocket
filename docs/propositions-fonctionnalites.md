# Propositions — fonctionnalités et prise en charge

Complément à [propositions-reddit-et-flux.md](propositions-reddit-et-flux.md), qui traite des
défauts du flux Reddit existant. Ici : ce que l'app **ne sait pas encore faire**, classé par
valeur pour un usage réel.

Effort : **S** < 1 jour, **M** 1–3 jours, **L** > 3 jours.

---

## 1. Prise en charge des sources

### 1.1 Coller un lien unique, toutes sources (P1)

**Constat.** La fonctionnalité existe déjà pour X-Fetish seulement : `/video/<id>/` et
`/albums/<id>/` sont reconnus ([XFetishAlbums.swift](../Sources/MediaCore/XFetishAlbums.swift),
`parseVideoRef` / `parseAlbumRef`). Ailleurs, c'est l'échec ou le silence :

| Lien collé | Aujourd'hui |
|---|---|
| `reddit.com/r/pics/comments/abc123/titre/` | échoue (`MediaExtractor.username` refuse `/`) |
| `redgifs.com/watch/xyz` | échoue (seul `redgifs.com/users/<pseudo>` est reconnu) |
| `x.com/nasa/status/123` | échoue (seul un profil est reconnu) |

**Proposition.** Généraliser le modèle de `XFetishAlbums.Target` : une « cible de sélection »
par source, acceptée par `FeedSource.parse`, qui court-circuite le parcours du catalogue et
télécharge uniquement les médias désignés. L'infrastructure existe déjà côté X-Fetish
(`runXFetishSelected`, [Downloader.swift:988](../App/Downloader.swift#L988)) : c'est un
portage, pas une invention.

**Effort** M — **Valeur** très haute. C'est la fonctionnalité qui change l'usage : on partage
un lien vers l'app au lieu de recopier un pseudo.

### 1.2 RedGifs : au-delà des comptes

**Constat.** Seul `users/<pseudo>/search` est implémenté
([RedgifsAPI.swift:40](../Sources/MediaCore/RedgifsAPI.swift#L40)). Pas de tags, pas de
recherche, pas de tendances.

**Proposition.** Trois ajouts, dans cet ordre de valeur :
1. **Un GIF unique** (`redgifs.com/watch/<id>`) — déjà résolu par `downloadRedgifs(id:)`,
   il ne manque que l'analyse de l'entrée.
2. **Un tag** (`rg/#tag` ou `redgifs.com/niches/<tag>`) : l'API expose une recherche par
   tag, la pagination est identique. Réutilise `runRedgifsUser` presque tel quel.
3. **Recherche libre** : plus fragile, l'API de recherche a changé plusieurs fois.

**Effort** S pour 1 et 2 — **Valeur** haute.

### 1.3 X : likes et signets

**Constat.** Seul le fil `/media` est lu (`XTwitterAPI.Query.userMedia`,
[XTwitterAPI.swift:46](../Sources/MediaCore/XTwitterAPI.swift#L46)). Or les likes et les
signets sont précisément ce que les gens veulent archiver — on a déjà trié soi-même.

**Proposition.** Deux opérations GraphQL supplémentaires (`Likes`, `Bookmarks`), même
mécanique de curseur, même extraction de médias. Le risque est connu et déjà assumé par
l'app : les `queryId` changent, et un `queryId` périmé produit déjà un message explicite
plutôt qu'un « aucun média » silencieux.

**Effort** M — **Valeur** très haute pour cette source.

### 1.4 Reddit : multis et posts isolés

- **Multis** `r/a+b+c` : rejeté par la regex `^[A-Za-z0-9_]{2,21}$`
  ([Feed.swift:103](../Sources/MediaCore/Feed.swift#L103)). Un dossier `r.a+b+c` trié
  alphabetiquement resterait stable. **Effort** S.
- **Post isolé** : couvert par 1.1.

### 1.5 Mode « lien » explicite dans le sélecteur

Aujourd'hui le sélecteur cycle `u/ → r/ → RG → ♥ → x/ → tw`
([SourceKind.swift](../Sources/MediaCore/SourceKind.swift)) et déduit la source du texte.
Avec 1.1, un septième état « lien » rendrait le comportement prévisible : on colle, l'app
détecte l'hôte et choisit. À faire **après** 1.1, sinon on empile deux mécanismes.

---

## 2. Filtres de téléchargement

### 2.1 Filtrer ce qu'on télécharge, pas seulement où

**Constat.** Le seul filtre est le type X-Fetish (Images / Vidéos / Les deux,
[Downloader.swift:188](../App/Downloader.swift#L188)). Pour toutes les autres sources, tout
ce qui est reconnu est téléchargé.

**Proposition.** Un panneau de filtres par collection, appliqué dans `prepareDownloads`
avant la mise en file :

| Filtre | Intérêt réel |
|---|---|
| Type (image / vidéo / GIF) | éviter 2000 images pour 40 vidéos |
| Date de publication minimale | archiver « depuis que je suis la source » |
| Taille minimale | écarter les vignettes et les posts texte |
| Mots-clés inclus / exclus dans le titre | le cas d'usage le plus demandé |
| Résolution minimale (vidéo) | après parsing DASH, avant transfert |

**Effort** M — **Valeur** très haute. C'est probablement la fonctionnalité la plus utile de
tout ce document pour un usage suivi.

**Piège à éviter.** Un filtre refusé ne doit **pas** marquer le post comme vu, sinon il ne
sera jamais réévalué. Il faut un troisième état : « vu et écarté par filtre », distinct de
« vu et téléchargé ».

### 2.2 Quota d'espace disque

**Proposition.** Un plafond par collection ou global (`Réglages → Stockage`), avec arrêt
propre quand il est atteint. Les téléchargements sont souvent lancés puis oubliés ; sur un
iPhone, 40 Go de vidéos est un vrai risque.

**Effort** S — **Valeur** haute.

---

## 3. Galerie et navigation

### 3.1 Recherche, tri et filtres dans la galerie

**Constat.** `gallerySection` est un `LazyVGrid` sur `model.files` sans aucun tri ni filtre
([RedditMediaPocketApp.swift:322-343](../App/RedditMediaPocketApp.swift#L322-L343)). L'ordre
est celui des dates de création, en flux. Sur une collection de plusieurs milliers de
fichiers, on ne retrouve rien.

**Proposition.** Une barre de recherche (nom de fichier, auteur via `.metadata`), un tri
(date, taille, type, nom) et des filtres rapides (images / vidéos / favoris).

**Effort** M — **Valeur** haute dès que les collections grossissent.

### 3.2 Sélection multiple

Aujourd'hui chaque vignette n'offre qu'un menu contextuel individuel. Pouvoir sélectionner
50 médias pour les supprimer, les partager ou les envoyer vers kDrive en une fois.

**Effort** M — **Valeur** moyenne-haute.

### 3.3 Favoris locaux

Un cœur par média, indépendant du téléchargement. Permet de retrouver ce qu'on aime dans
une archive de milliers de fichiers, sans dépendre de Reddit.

**Effort** S — **Valeur** moyenne.

---

## 4. Suivi et automatisation

### 4.1 « Nouveaux depuis le dernier passage »

**Constat.** `UserCollection.lastRun` existe déjà et est mis à jour à chaque parcours
([Downloader.swift:850](../App/Downloader.swift#L850)), mais n'est **affiché nulle part**.
`scanIncomplete` est la seule information de parcours remontée.

**Proposition.** Sur chaque chip de collection : le nombre de médias ajoutés au dernier
passage, et depuis quand on n'a pas relancé. Coût quasi nul, l'état est déjà là.

**Effort** S — **Valeur** haute.

### 4.2 File d'attente multi-sources

Aujourd'hui `start()` traite une source à la fois ; relancer dix collections demande dix
manipulations. Une file (« tout mettre à jour ») avec progression globale.

**Effort** M — **Valeur** haute pour un usage régulier.

### 4.3 Relance planifiée en arrière-plan

**Constat.** Le README l'assume : « Garder l'application au premier plan. Le prototype
n'implémente pas de service de téléchargement en arrière-plan. »
`LegacyBackgroundCleanup` utilise une `URLSession` d'arrière-plan, mais uniquement pour du
nettoyage.

**Proposition.** `BGTaskScheduler` pour déclencher un parcours court (`BGProcessingTask`,
opportuniste). Limites réelles d'iOS : déclenchement non garanti, durée bornée, et
LiveContainer peut ne pas transmettre les tâches. **À traiter comme un bonus, jamais comme
une garantie** — et à annoncer comme tel.

**Effort** L — **Valeur** moyenne, **risque** élevé.

### 4.4 Rafraîchissement par glissement

Tirer la galerie vers le bas pour relancer la collection active. Trivial, très attendu.

**Effort** S — **Valeur** moyenne.

---

## 5. Robustesse et exploitation

### 5.1 Pause au lieu d'arrêt

`stop()` annule tout. Une pause qui laisse la page en cours se terminer et reprend au même
curseur serait plus douce. Le modèle de reprise (page validée seulement si complète,
[FeedTraversal.swift:35-37](../Sources/MediaCore/FeedTraversal.swift#L35-L37)) le permet
déjà ; c'est surtout un état d'interface à ajouter.

**Effort** S — **Valeur** moyenne.

### 5.2 Détection des doublons entre collections

Un même média peut être téléchargé dans `u/alice` et dans `r/pics` sans que l'app le sache :
`seenMedia` est local à un parcours ([Downloader.swift:766](../App/Downloader.swift#L766)).
Un index par empreinte de fichier ou par clé de média permettrait de signaler « déjà présent
dans `r.pics` » et, au choix, de ne pas le retélécharger.

**Effort** M — **Valeur** moyenne, mais croît avec le nombre de sources.

### 5.3 Import/export de la configuration

Collections, tris, filtres, réglages. Utile pour passer d'un appareil à l'autre, ou pour
récupérer après une réinstallation — sans quoi tout est à ressaisir. Les fichiers, eux,
survivent dans le conteneur.

**Effort** S — **Valeur** moyenne.

### 5.4 Statistiques par collection

Taille totale, nombre de médias, dernière exécution, nombre d'échecs. Sert aussi à décider
quoi supprimer. Les données existent (`CollectionFiles.scan`), il manque l'écran.

**Effort** S — **Valeur** moyenne.

---

## 6. Ce que je ne recommande pas

Pour rester honnête sur le périmètre — l'app est un outil personnel, pas un produit :

- **YouTube, Vimeo, Streamable, HLS.** Hors du modèle « lien direct » de l'app, et
  juridiquement plus exposé. À refuser explicitement plutôt qu'à moitié supporter.
- **Gfycat.** Service fermé en 2023. Inutile d'écrire un extracteur.
- **Upload kDrive automatique après chaque téléchargement** (plutôt que manuel). Séduisant,
  mais multiplie les points de panne pour un bénéfice limité : garder le bouton manuel.
- **Widget, complications, Live Activities.** Peu de valeur pour un outil qu'on ouvre
  délibérément.
- **Une couche d'abstraction « fournisseur de source ».** Six sources, six flux, chacune
  avec ses particularités (dossier, clé, reprise). `FeedSource` et le `switch` de
  `Downloader` sont verbeux mais lisibles ; les généraliser maintenant rendrait le code plus
  difficile à suivre pour un gain théorique.

---

## Synthèse

| # | Proposition | Effort | Valeur |
|---|---|---|---|
| 1.1 | Coller un lien unique, toutes sources | M | **très haute** |
| 2.1 | Filtres de téléchargement | M | **très haute** |
| 1.3 | X : likes et signets | M | très haute |
| 1.2 | RedGifs : GIF unique, tags | S | haute |
| 4.1 | « Nouveaux depuis le dernier passage » | S | haute |
| 3.1 | Recherche / tri dans la galerie | M | haute |
| 4.2 | File d'attente multi-sources | M | haute |
| 2.2 | Quota d'espace disque | S | haute |
| 5.2 | Doublons entre collections | M | moyenne |
| 3.2 | Sélection multiple | M | moyenne |
| 1.4 | Multis Reddit | S | moyenne |
| 5.1 | Pause | S | moyenne |
| 5.3 | Import/export config | S | moyenne |
| 5.4 | Statistiques par collection | S | moyenne |
| 3.3 | Favoris locaux | S | moyenne |
| 4.4 | Rafraîchissement par glissement | S | moyenne |
| 1.5 | Mode « lien » explicite | S | faible (dépend de 1.1) |
| 4.3 | Relance planifiée | L | moyenne, risquée |

## Ordre recommandé

**Semaine 1 — le geste qui change l'usage.** `1.1` (lien unique) puis `1.2.1` et `1.2.2`
(GIF et tag RedGifs). À eux trois, ils couvrent « je partage un lien, l'app le prend ».

**Semaine 2 — contrôler ce qu'on télécharge.** `2.1` (filtres) et `2.2` (quota). C'est ce
qui rend une archive tenable sur la durée, et ce qui évite 40 Go de vidéos par accident.

**Semaine 3 — retrouver ce qu'on a.** `3.1` (recherche/tri) et `4.1` (nouveautés).
Le reste se glisse au fil de l'eau.

`4.3` (arrière-plan) est à traiter en dernier, et seulement si le besoin est réel : iOS ne
garantit rien, et une promesse non tenue est pire que l'absence de fonctionnalité.
