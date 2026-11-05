# Propositions — Reddit et le flux

État des lieux établi sur `main` @ `59c4ada`. Aucune de ces propositions n'est implémentée.
Effort : **S** < 1 jour, **M** 1–3 jours, **L** > 3 jours.

---

## Groupe A — Corrections de justesse (à faire en premier)

### A1. Le tri `hot` / `top` rate des médias de façon permanente

**Constat.** `FeedTraversal.run` termine la phase « nouveautés » dès qu'une page ne contient
aucun post inconnu ([FeedTraversal.swift:63-67](../Sources/MediaCore/FeedTraversal.swift#L63-L67)) :
« historique déjà connu atteint ». Ce raisonnement suppose un flux **chronologique**. Il est
valable pour `new`, faux pour `hot` et `top`, dont l'ordre dépend des votes et se réordonne
entre deux lancements.

Conséquence exacte : sur `hot`, si la page 1 est entièrement connue mais qu'un média nouveau
est en page 2 ce jour-là, le parcours s'arrête, `frontier` est remis à `nil`
([:76](../Sources/MediaCore/FeedTraversal.swift#L76)) puis `needsHistory` vaut `false`
([:80](../Sources/MediaCore/FeedTraversal.swift#L80)) : **le run suivant ne fera pas non plus
la phase historique**. Le média reste invisible jusqu'à ce qu'il remonte en page 1.

**Proposition.** Rendre la phase « nouveautés » conditionnelle au tri : elle ne s'applique
qu'à `new`. Pour `hot` et `top`, faire un balayage borné depuis la tête à chaque lancement,
en s'appuyant sur `visited` + les noms de fichiers pour éviter tout retéléchargement.
Le coût est d'un run de pages en plus, sans téléchargement supplémentaire.

**Effort** S — **Risque** faible, c'est un changement de condition dans `FeedTraversal`.

### A2. Une limite 429 tue la session entière au lieu d'attendre

**Constat.** `Network.check` convertit tout 429 en `NetworkError.limited`
([Network.swift:92-108](../App/Network.swift#L92-L108)) et `RetryPolicy` exclut explicitement
de le réessayer ([RetryPolicy.swift:6](../Sources/MediaCore/RetryPolicy.swift#L6)). Reddit
répond souvent 429 sur le RSS avec `x-ratelimit-reset` à quelques secondes seulement.

**Proposition.** Attendre le délai annoncé quand il est court (≤ 46 s, sous la limite d'une
tâche utilisateur) et **réessayer la page**, en gardant la session vivante. Au-delà du seuil,
comportement actuel. Le délai est déjà calculé correctement dans `RatePolicy.retryDate`
([RatePolicy.swift:23-32](../Sources/MediaCore/RatePolicy.swift#L23-L32)) : il n'est simplement
jamais utilisé pour attendre.

**Effort** S — **Risque** faible. À faire dériver du réglage de concurrence pour rester cohérent.

### A3. « Historique complet » est conclu sur un signal ambigu

**Constat.** Dans la phase historique, `guard let last = posts.last?.id, validCursor(last), last != after`
remet `cursor = nil` et retourne `true`, c'est-à-dire « terminé »
([FeedTraversal.swift:104-109](../Sources/MediaCore/FeedTraversal.swift#L104-L109)). Un curseur
invalide ou inchangé y est traité exactement comme une vraie fin de flux, et cela efface le
point de reprise : le prochain run croira l'historique épuisé.

À nuancer par rapport à ma première lecture : une page de blocage Reddit n'a pas de `<feed>`,
donc `FeedParser` lève `FeedError.invalidFeed` ([:215](../Sources/MediaCore/Feed.swift#L215))
et l'erreur est visible — ce cas n'est **pas** silencieux. Le risque réel est plus étroit :
un flux Atom valide mais tronqué ou vide, et surtout un `last == after` en boucle, concluent
à la complétude sans que rien ne le signale.

**Proposition.** Journaliser et remonter lequel des trois signaux a mis fin au parcours
(page vide, curseur invalide, curseur inchangé), et ne lever `scanIncomplete` que pour les
deux derniers. Le log actuel les distingue déjà partiellement : c'est l'interface qui ne dit rien.

**Effort** S — **Risque** faible.

### A4. Résolution des galeries sans borne de concurrence

**Constat.** `prepareDownloads` crée **une tâche par post galerie** dans un
`withThrowingTaskGroup` ([Downloader.swift:1452-1468](../App/Downloader.swift#L1452-L1468)),
sans plafond. Une page de 100 posts majoritairement galeries lance ~100 requêtes simultanées
vers `www.reddit.com`, alors que le réglage affiché est 3 (ou 6). C'est le chemin le plus
susceptible de déclencher le 429 de A2.

**Proposition.** Borner ce groupe au `sessionLimit` effectif, comme `previewMediaList` le fait
déjà correctement ([Downloader.swift:646-663](../App/Downloader.swift#L646-L663)).

**Effort** S — **Risque** faible, le code existe déjà à côté.

---

## Groupe B — Couverture Reddit

### B1. Les albums Imgur ne sont pas pris en charge

**Constat.** `MediaExtractor.extract` n'accepte qu'un hôte exact `i.imgur.com` avec une
extension de fichier ([Feed.swift:278-280](../Sources/MediaCore/Feed.swift#L278-L280)).
`imgur.com/a/<id>` et `imgur.com/gallery/<id>` tombent donc dans « Aperçu uniquement »,
alors que ce sont les liens externes les plus fréquents du Reddit archivé.

**Proposition.** Ajouter un `ImgurAlbum` dans `MediaCore`, sur le modèle de `GalleryFeed` :
détecter `/a/` et `/gallery/`, résoudre la liste ordonnée, puis passer chaque image dans
`QualityPolicy.originalImageURL` (qui gère déjà le dénudage des suffixes de vignette).
Deux voies possibles pour la résolution : l'API Imgur anonyme avec un `client_id` public
(lecture seule, pas de compte), ou le HTML de la page. L'API est plus stable, le HTML n'ajoute
aucun identifiant à gérer. **Recommandation : API d'abord, HTML en repli.**

**Effort** M — **Risque** moyen (l'API Imgur anonyme a un quota généreux mais réel).

### B2. Les crossposts ne sont suivis que s'ils sont des galeries

**Constat.** `crosspost_parent_list` n'est lu que dans `GalleryFeed.parse`, et seulement pour
retrouver un `gallery_data` ([GalleryFeed.swift:61-62](../Sources/MediaCore/GalleryFeed.swift#L61-L62)).
Un crosspost dont le parent est une image directe, une vidéo `v.redd.it` ou un GIF n'est pas suivi.

**Proposition.** Extraire une fonction « média effectif du post » qui consulte d'abord
`crosspost_parent_list` (dernier parent valide), puis le post lui-même. Utilisée à la fois par
`MediaExtractor` et par la galerie.

**Effort** S — **Risque** faible, et cela dédoublonne une logique déjà dupliquée.

### B3. Aucune gestion NSFW / `over18`

**Constat.** Zéro occurrence de `over18`, `nsfw` ou `quarantine` dans le code.
Un subreddit marqué NSFW, ou simplement un profil qui en publie, renvoie selon les cas une
page de garde ou un flux vide ; l'app le présente comme `FeedError.invalidFeed`
(« Reddit peut refuser cet accès anonyme »), ce qui est trompeur.

**Proposition.** Quand une session Reddit est active, joindre le cookie `over18=1` aux
requêtes `*.reddit.com` — `RedditCookiePolicy` filtre déjà par hôte, il suffit d'ajouter ce
cookie à l'en-tête construit dans `Network.request` ([Network.swift:71](../App/Network.swift#L71)).
Sans session, détecter la page de garde et afficher un message dédié « contenu réservé aux
adultes, connecte-toi ».

**Effort** S — **Risque** faible.

### B4. Lire les listes en JSON plutôt qu'en RSS

**Constat.** Le RSS ne donne ni `media_metadata`, ni `gallery_data`, ni `crosspost_parent_list`,
ni `over_18`, ni `is_video`. D'où la requête supplémentaire **par post galerie** vers
`comments/<id>.json` ([GalleryFeed.swift:36-42](../Sources/MediaCore/GalleryFeed.swift#L36-L42)),
et d'où l'impossibilité de traiter B1, B2 et B3 proprement. L'app sait déjà lire ce JSON :
c'est exactement ce que fait `GalleryFeed.parse`.

**Proposition.** Ajouter un `ListingFeed` qui lit `https://www.reddit.com/r/<sub>/new.json?limit=100&after=…`
avec le même curseur, et retombe sur le RSS en cas d'échec. Bénéfices : plus une seule requête
supplémentaire par galerie, `is_video`, `over_18`, crosspost et galerie disponibles d'emblée,
curseur `after` explicite dans le JSON. La politique de cookies est inchangée.

**Effort** M — **Risque** moyen : Reddit peut limiter `.json` plus durement que `.rss` selon
l'UA et le réseau. À valider par un test réel avant de basculer ; le repli RSS rend le
changement réversible.

### B5. Les sauvegardés dépendent d'un réglage Reddit obscur

**Constat.** L'onglet `♥` exige d'activer les « flux RSS privés » dans les préférences Reddit
([SavedFeed.swift:8](../Sources/MediaCore/SavedFeed.swift#L8), README l.49). C'est un prérequis
que la plupart des comptes n'ont jamais touché, et la cause d'échec la plus fréquente de cette
source.

**Proposition.** Puisque l'app envoie déjà les cookies du compte vers `www.reddit.com`, tenter
d'abord `https://www.reddit.com/saved.json?limit=100` avec la session, et ne conserver le lien
RSS privé qu'en repli. Supprime le prérequis et aligne la source sur les autres.

**Effort** S — **Risque** faible, avec repli sur l'existant.

### B6. Tris et formes de sources manquants

**Constat.** `subredditSorts = ["new", "hot", "top"]` avec `t=month` **forcé**
([Feed.swift:54](../Sources/MediaCore/Feed.swift#L54), [:179-180](../Sources/MediaCore/Feed.swift#L179-L180)).
Pas de `rising`, pas de `top` sur l'heure/la semaine/l'année/tout. Les multis `r/a+b` sont
rejetés par la regex `^[A-Za-z0-9_]{2,21}$` ([:103](../Sources/MediaCore/Feed.swift#L103)).

**Proposition.** Trois ajouts indépendants et peu coûteux :
1. `rising` comme quatrième tri ;
2. fenêtre de `top` exposée dans le sélecteur (`hour`, `day`, `week`, `month`, `year`, `all`) ;
3. `r/a+b+c` accepté, avec un dossier dérivé des noms triés (`r.a+b+c` reste stable).

**Effort** S — **Risque** faible.

---

## Groupe C — Le flux et sa reprise

### C1. Le plafond de 100 pages n'est pas réglable

**Constat.** `maximumPages: Int = 100` est une constante de la signature
([FeedTraversal.swift:20](../Sources/MediaCore/FeedTraversal.swift#L20)), utilisée par les
quatre sources. README l.47 assume le plafond théorique de ~2500 posts.

**Proposition.** Exposer le budget de pages dans les Réglages (25 / 50 / 100 / illimité),
mémorisé et figé au démarrage comme les autres réglages de session.

**Effort** S — **Risque** faible.

### C2. La progression ne montre pas où l'on en est

**Constat.** L'interface n'expose que `count/discovered` ([RedditMediaPocketApp.swift:251](../App/RedditMediaPocketApp.swift#L251))
et une barre réservée à X-Fetish et X ([:262](../App/RedditMediaPocketApp.swift#L262)).
Sur un subreddit volumineux, rien n'indique qu'on est page 84/100.

**Proposition.** Ajouter la page courante au texte d'état, et afficher la bannière
`scanIncomplete` avec le nombre de pages consommées. Un bouton « Continuer » directement dans
la bannière éviterait de re-saisir la source.

**Effort** S — **Risque** nul.

### C3. L'historique des posts vus est stocké dans `UserDefaults`

**Constat.** `visitedPosts.<collection>` contient jusqu'à 10 000 identifiants sérialisés en
propriété-liste ([Downloader.swift:1272](../App/Downloader.swift#L1272)). À 10 000 entrées,
on avoisine 150 Ko relus et réécrits à chaque page.

**Proposition.** Déplacer cet état dans un fichier par collection
(`Documents/.state/<collection>.json`), écrit en une fois par page. Bénéfices : plus de
saturation de `UserDefaults`, historique extensible au-delà de 10 000, et suppression
cohérente avec le dossier.

**Effort** M — **Risque** moyen : nécessite une migration des clés existantes, à ne pas
rater sous peine de tout retélécharger.

### C4. Deux migrations effacent silencieusement la reprise

**Constat.** `resumePolicyVersion` ([:758-765](../App/Downloader.swift#L758-L765)) et
`galleryResolutionVersion` ([:798-804](../App/Downloader.swift#L798-L804)) effacent curseur,
frontière et historique. C'était justifié lors de leur introduction, mais le mécanisme reste
en place et une future version pourrait le redéclencher sans que l'utilisateur comprenne
pourquoi son parcours repart de zéro.

**Proposition.** Ne conserver que la version courante, journaliser le déclenchement, et
prévoir un indicateur explicite « historique réinitialisé pour revérifier les médias » dans le
statut plutôt que seulement dans le log.

**Effort** S — **Risque** faible.

### C5. L'aperçu ne pagine pas

**Constat.** `previewSavedPosts` et `previewPosts` lisent une seule page
([Downloader.swift:576-590](../App/Downloader.swift#L576-L590)). Les fenêtres Sauvegardés et
Suivis montrent donc ~25 posts et rien de plus, alors que le téléchargement, lui, parcourt
100 pages.

**Proposition.** Charger la page suivante en bas de liste, sur le même curseur que le
téléchargement. Le cache d'aperçu est déjà borné (32 Mio / 100 entrées), l'impact est faible.

**Effort** M — **Risque** faible.

---

## Synthèse

| # | Proposition | Effort | Gain |
|---|---|---|---|
| A1 | `hot`/`top` ratent des médias | S | **Correction de perte de données** |
| A2 | Attendre le 429 court au lieu d'abandonner | S | Fiabilité |
| A3 | Signaler les fins de parcours ambiguës | S | Diagnostic |
| A4 | Borner la résolution des galeries | S | Moins de 429 |
| B1 | Albums Imgur | M | **Couverture** |
| B2 | Crossposts hors galerie | S | Couverture |
| B3 | `over18` et message NSFW | S | Couverture |
| B4 | Listes en JSON | M | **Structurel** |
| B5 | Sauvegardés sans flux RSS privés | S | Supprime un prérequis |
| B6 | Tris + multis | S | Confort |
| C1 | Plafond de pages réglable | S | Confort |
| C2 | Progression page X/N | S | Visibilité |
| C3 | État hors `UserDefaults` | M | Robustesse |
| C4 | Migrations tracées | S | Diagnostic |
| C5 | Aperçu paginé | M | Cohérence |

## Ordre recommandé

**Lot 1 — justesse (A1, A2, A3, A4).** Un seul thème, quatre fichiers touchés
(`FeedTraversal`, `Network`, `RatePolicy`, `Downloader`), et A1 corrige une perte réelle de
médias sur deux des trois tris. C'est le lot qui change le plus avec le moins de risque.

**Lot 2 — couverture sans refonte (B1, B2, B3, B5, B6).** Que des ajouts localisés, chacun
indépendant, testable séparément.

**Lot 3 — structurel (B4, puis C3).** B4 ouvre la voie à beaucoup de choses mais demande une
validation réelle du comportement `.json` sur le réseau de l'utilisateur avant de basculer.
À ne pas tenter avant que le lot 1 soit validé sur iPhone.

C1, C2, C4 et C5 sont des améliorations d'interface et de diagnostic, à glisser au fil de l'eau.
