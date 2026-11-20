# Reddit Media Pocket — prototype iPhone

Application SwiftUI en français et en anglais, destinée à LiveContainer (iOS 26+). Le bouton de source ouvre une grille de choix : `u/` (profil Reddit), `r/` (subreddit), `RG` (compte RedGifs), `♥` (sauvegardés Reddit), `x/` (albums et vidéos d'un profil X-Fetish), `tw` (médias publics d'un compte X), `tt` (médias publics d'un compte TikTok), `ts` (TikTok du compte connecté, avec trois cibles différenciées : toutes les publications enregistrées, un dossier de favoris (collection) de son choix, ou un compte TikTok précis) et `ig` (médias publics d'un compte Instagram). On saisit le nom correspondant, sauf pour `♥` qui sélectionne automatiquement le compte Reddit connecté et `ts` qui utilise la session TikTok des Réglages. Le bouton télécharger lance la récupération des médias. Les flux publics restent accessibles sans compte, sans API JSON Reddit.

## Liens et sélections

Dans tous les modes sauf `♥`, une **adresse collée** est reconnue et prend la priorité sur le nom :

| Forme collée | Effet |
|---|---|
| `https://www.reddit.com/r/<sub>/` | même effet que saisir `r/<sub>` |
| `https://www.reddit.com/r/<sub>/comments/<id>/…` ou `https://redd.it/<id>` | seuls ces posts sont lus, sans parcourir de flux |
| `https://www.redgifs.com/watch/<id>` ou `/ifr/<id>` | un GIF unique |
| `rg/#<tag>`, `https://www.redgifs.com/niches/<tag>` | un tag RedGifs, parcouru page par page |
| `https://x-fetish.tube/video/<id>/…` ou `/albums/<id>/…` | seuls ces médias X-Fetish sont téléchargés |
| `https://x.com/<compte>` | même effet que `tw/<compte>` |
| `https://www.instagram.com/<compte>` | même effet que `ig/<compte>` |

Plusieurs adresses de posts Reddit peuvent être collées ensemble (retours à la ligne, virgules ou espaces) : elles partagent la collection stable `reddit/posts`, et les adresses sont mémorisées pour la relance. Une adresse de post X isolée (`x.com/<compte>/status/<id>`) est refusée avec un message explicite : X n'expose pas cette lecture sans parcourir le compte. Une publication Instagram isolée (`instagram.com/p/<code>`, `/reel/` ou `/tv/`) est refusée avec un message explicite : colle l'adresse du profil.

## Filtres de téléchargement

Le bouton **Filtres** (trois lignes, dans la barre) décide de ce qui est **téléchargé**, par collection : types de médias (images / vidéos / GIF), date de publication minimale, taille minimale, mots-clés exigés ou exclus dans le titre. Un filtre actif se repère à son icône pleine. Les filtres sont mémorisés pour la source concernée et ne s'appliquent jamais à une autre.

Un média écarté par un filtre n'est pas téléchargé mais reste « vu » : il ne sera pas réévalué au lancement suivant. C'est volontaire — sans cela, un filtre exigeant ferait relire tout le flux à chaque exécution.

## Espace disque

**Réglages → Stockage → Espace disque maximal** propose une limite de 5 à 100 Go, ou aucune. Le plafond porte sur la collection en cours et est vérifié avant chaque page : quand il est atteint, le parcours s'arrête proprement et les médias déjà téléchargés restent en place.

## Galerie : recherche et tri

Au-dessus de la grille, la recherche porte sur le nom des fichiers, l'auteur et le lien du post (lus depuis les métadonnées des téléchargements). Le menu voisin propose un tri (plus récent, plus ancien, plus lourd, plus léger, nom) et un filtre rapide images / vidéos. Ces réglages ne changent que l'affichage : ils ne modifient jamais ce qui est téléchargé.

Chaque pastille de collection affiche `+N` lorsque le dernier parcours y a ajouté N médias.

## État réel

Le code et le workflow sont disponibles dans ce dépôt. GitHub Actions compile et publie une IPA à chaque push sur main. Consulter le résultat du dernier workflow avant de télécharger une release. Les essais dans LiveContainer sur iPhone restent à effectuer. Un appel public au RSS de `u/reddit` a répondu HTTP 200 le 5 septembre 2026. Ce résultat ne garantit pas l'accès depuis un autre réseau ou pour un autre profil.

Ce prototype ne promet pas de télécharger tous les posts. Le flux peut tronquer l'historique, refuser la pagination ou refuser l'accès. L'application s'arrête si une page se répète, si le curseur n'est pas reconnu ou après 100 pages. Les miniatures ne sont pas utilisées à la place des originaux.

Chaque exécution relit le flux depuis le début, page par page, jusqu'à rencontrer une page entièrement déjà connue : c'est là que les nouveaux posts s'arrêtent. Si une session précédente a été interrompue au milieu de cette lecture, le point d'arrivée est mémorisé et l'exécution suivante saute directement dessus au lieu de conclure à tort qu'elle a tout vu. Ce point est effacé dès que le parcours rejoint l'historique, ou conservé si les 100 pages ont été consommées sans l'atteindre.

Les profils (`u/pseudo`, flux `submitted`), les subreddits (`r/sub`, tri Nouveaux / Chauds / Top du mois) et les comptes RedGifs (`RG/pseudo` ou URL `redgifs.com/users/pseudo`, tri Nouveaux via `order=new`, 80 par page, 100 pages max côté API) sont pris en charge. Le Top utilise le filtre serveur `t=month`. Les dossiers des subreddits sont préfixés `r.` (ex. `r.pics`), ceux des comptes RedGifs `redgifs.` (ex. `redgifs.upset_trash_3094`) et les clés `rg/pseudo` pour ne jamais entrer en collision avec un profil du même nom. Les archives existantes (pseudo nu) restent lues comme des profils.

Les tags RedGifs utilisent la même pagination sous `redgifs.tag.<tag>` (clé `rg/#<tag>`), et un GIF unique sous `redgifs.gif.<id>` (clé `rg/gif/<id>`) : aucun parcours n'est nécessaire pour un GIF seul. Les trois formes restent des collections distinctes.

Albums X-Fetish (`x/`) : saisir le nom dans l'adresse du profil après `/models/`, par exemple `itwasalwaysmysolesvip` pour `https://x-fetish.tube/models/itwasalwaysmysolesvip/` (l'adresse du profil peut aussi être collée telle quelle), ou coller une ou plusieurs adresses de vidéo `/video/<id>/…` ou d'album `/albums/<id>/…`, séparées par des retours à la ligne, des virgules ou des espaces. Un sélecteur **Images / Vidéos / Les deux** apparaît sous le champ de saisie ; il est mémorisé et vaut « Images » par défaut. Une collection distincte `x/nom` est créée dans le dossier `x.nom`, quel que soit le sélecteur. Une sélection d'adresses seules (sans profil) ne parcourt pas le catalogue : seules ces vidéos et albums sont téléchargés, dans la collection stable `x/videos` (ou `x/albums` pour des albums seuls), et les adresses collées sont mémorisées pour la relance.

Vidéos X-Fetish : la liste est collectée avant les transferts, sur 100 pages maximum par lancement. Un parcours incomplet mémorise la page suivante après traitement du lot : le prochain lancement peut donc atteindre la page 101 et les suivantes. Une interruption garde le début du lot ; les fichiers déjà enregistrés sont ignorés à la reprise. Après la fin de la liste, le parcours suivant revient à la page 1 pour chercher les nouveautés. Chaque emplacement libre résout sa page vidéo en URL signée fraîche, puis échange `get_file` en IPv4 contre une URL de stockage. Le `Referer` reste la page vidéo et le jeton n'est jamais journalisé. Un HTTP 403 provoque une seule relecture de la page et un nouvel essai propre en connexion unique ; si ce second essai échoue, la vidéo est ignorée et le parcours continue avec les suivantes. Seul un HTTP 429 arrête le parcours, sans supprimer les fichiers terminés. Un hôte de stockage inattendu bascule en connexion unique au lieu d'être rejeté. Les noms et le dédoublonnage par identifiant de la version Swift restent inchangés.

**Réglages → X-Fetish → Morceaux par vidéo** : choisir **8, 16, 24 ou 32**, **24 par défaut**, avec **6 téléchargements simultanés par défaut** pour X-Fetish. Le choix est mémorisé et fixé au début du parcours ; une ancienne valeur de morceaux non proposée revient à 24. Les préférences valides déjà enregistrées restent inchangées. Une sonde `Range: bytes=0-0` vérifie le support des plages HTTP. Un MP4 de plus de 4 Mio et d'au plus 2 Gio est découpé en plages parallèles, écrites directement aux bons offsets dans un `.part` créé exclusivement. Chaque réponse doit être HTTP 206, porter le bon `Content-Range` et contenir exactement les octets attendus. Le fichier n'est publié qu'après fermeture de tous les morceaux. Un serveur sans plages, une taille inconnue, un fichier hors de ces bornes ou une plage défaillante provoque un repli complet en connexion unique. Un arrêt ou un refus 403/429 ne déclenche jamais ce repli. Les autres morceaux sont annulés et le `.part` est nettoyé avant la suite.

Ce réglage ne concerne ni les images X-Fetish ni les pistes DASH de Reddit. Les médias simultanés et les morceaux par vidéo se multiplient : les valeurs par défaut, 6 vidéos × 24 morceaux, peuvent ouvrir 144 connexions de stockage, et 6 × 32 jusqu'à 192. Plus de morceaux peut augmenter les refus 403/429 ; réduire les morceaux ou les médias simultanés si nécessaire. Le transport conserve l'User-Agent Safari iPhone et la politique réseau de la version Swift ; il ne remplace pas celle-ci par la pile Node.js Windows.

## Médias d'un compte X (`tw`)

La fenêtre des sauvegardés reste dédiée à Reddit, avec ses vues feed/liste et le téléchargement des sauvegardés. Le feed web X a été retiré.

X n'expose aucun accès anonyme aux médias : l'API officielle répond HTTP 401 sans compte, et les miroirs publics type Nitter ne répondent plus. Cette source exige donc une session X, obtenue dans Réglages → Se connecter à X. Cette fenêtre ouvre directement le formulaire `https://x.com/i/flow/login` ; utiliser ses identifiants X. Le mode accueil et son bouton de bascule ont été retirés. Le bouton Recharger reste disponible. Elle est distincte de la session Reddit : une déconnexion X n'efface pas la session Reddit, et inversement. Le stockage WebKit de X est persistant et isolé de celui de Reddit : la connexion peut être retrouvée après un redémarrage, jusqu’à expiration des cookies ou déconnexion explicite. Les cookies de X sont donc conservés localement sur l’appareil. Le cookie `auth_token` permet de détecter la connexion ; les appels GraphQL requièrent aussi `ct0` (CSRF), qui peut être émis ultérieurement par X.

Saisir le pseudo seul (`nasa`), avec `@` (`@nasa`), avec le préfixe `tw/`, ou coller l'adresse du profil (`x.com/nasa`). La collection `tw/pseudo` est créée dans le dossier `tw.nasa`, distinct de `x.nasa` (X-Fetish) et d'un profil Reddit au même pseudo.

L'application parcourt le fil `/media` du compte, page par page, du plus récent au plus ancien, 100 pages au plus par exécution. Chaque média est pris dans la meilleure qualité que X publie pour lui :

- Images : `?name=orig`, l'original téléversé, et non une vignette.
- Vidéos : la variante `video/mp4` de plus haut débit. Le flux `application/x-mpegURL` qu publie aussi X n'est pas retenu, car il n'est pas téléchargeable tel quel.
- GIF animés : un GIF X est un MP4 ; le fichier enregistré porte donc l'extension `.mp4`.

Un compte protégé, introuvable ou sans aucun média ne produit aucun fichier. Un média publié uniquement en flux HLS est ignoré plutôt que compté comme échec.

Un parcours X incomplet conserve le curseur de la dernière page entièrement traitée, y compris après une erreur temporaire ou le plafond de 100 pages. Relancer reprend les pages restantes. Une fois la fin atteinte, le curseur est effacé et le lancement suivant repart du début pour chercher les nouvelles publications ; les publications arrivées pendant la reprise seront prises à ce moment-là. Le curseur est associé à l’identifiant du compte X résolu et supprimé avec la collection. Les clés `xm-<id>` et `xmv-<id>` inscrites dans les noms de fichiers évitent de retélécharger les médias présents.

Le parcours s'appuie sur l'API GraphQL interne de x.com, dont les `queryId` sont publiés par le bundle web et changent quand X met à jour son interface. Ils sont regroupés dans `XTwitterAPI.Query`. Un `queryId` périmé se manifeste par le message « Fil des médias X illisible ou tronqué », jamais par un « aucun média » silencieux. À vérifier sur iPhone : connexion X, fermeture complète puis relance de l’application (session conservée), déconnexion X (session effacée sans affecter Reddit), un profil avec image, une vidéo et un GIF, puis une relance qui ne doit rien retélécharger. Si `auth_token` apparaît avant `ct0`, la connexion doit être détectée mais l’accès API doit rester en attente de CSRF.

Images : l'application parcourt les pages d'albums publics et les images originales de chaque album, y compris celles derrière « Show More ». Elle ne prend pas les photos de profil, miniatures ni albums privés.

Vidéos : l'application parcourt les pages `/models/<nom>/videos/` puis ouvre chaque page `/video/<id>/`, dont le script du lecteur publie la route signée `get_file` (le jeton `v-acctoken` est lié à l'adresse IP et expire vite : une vidéo déjà enregistrée n'est plus re-ouverte). Les pages `/video/` et les médias `get_file` passent par l'IPv4 forcé, comme `get_image`, car le stockage `storage*.x-fetish.tube` est IPv4-only. Le même dossier `x.nom` accueille les deux types ; les clés `xf-<album>-<image>` et `xfv-<video>` permettent de ne jamais retélécharger un fichier déjà présent, quel que soit le sélecteur utilisé. Relancer vérifie les anciens albums et les anciennes vidéos. L'accès dépend de la disponibilité des pages publiques du site.

Jusqu'à combien de posts ? Plafond théorique : 100 pages × ~25 posts par page RSS ≈ 2500 posts parcourus. En pratique, le RSS anonyme tronque bien avant : page qui se répète, curseur refusé ou HTTP 429 arrêtent le parcours, souvent après quelques centaines de posts. Le compteur « repérés » (nouveaux fichiers reçus / repérés pendant le parcours) progresse à chaque page mais ne constitue pas un total exhaustif de l'historique.

Sauvegardés (`♥`) : le compte connecté est sélectionné automatiquement, sans saisie de pseudo. La saisie précédente de profil ou de subreddit est ignorée dans ce mode. Exige une session active (Réglages → Se connecter à Reddit) et les flux RSS privés activés dans Reddit. Le bouton « Flux privés » de la fenêtre de connexion ouvre ces préférences. À chaque lancement, l’app lit le lien privé des sauvegardés dans `https://old.reddit.com/prefs/feeds/` avec les cookies du compte connecté, en déduit le pseudo pour choisir le dossier du compte, puis conserve les paramètres d’authentification `feed` et `user` sur chaque page. Le lien reste en mémoire pour ce parcours, sans cache RSS ni stockage du jeton. Les redirections HTTPS du flux privé entre `old.reddit.com`, `www.reddit.com` et `reddit.com` sont suivies uniquement vers un chemin de sauvegardés du même compte, avec conservation du jeton et de la pagination. Les autres destinations sont refusées. Un lien absent ou un refus HTTP produit un message explicite, sans nouvelle tentative automatique. Même plafond de 100 pages, sans exhaustivité garantie ; les commentaires sauvegardés n’interrompent plus la pagination. Les dossiers sont préfixés `saved.` (ex. `saved.leboxis`).

## Médias d'un compte Instagram (`ig`)

Saisir le pseudo seul (`nasa`), avec `@`, avec le préfixe `ig/`, ou coller l'adresse du profil (`instagram.com/nasa`). Une publication isolée (`instagram.com/p/<code>`, `/reel/` ou `/tv/`) est refusée avec un message explicite. La collection `ig/pseudo` est créée dans le dossier `ig.pseudo`, distinct de `tk.pseudo` (TikTok), `tw.pseudo` (X) et d'un profil Reddit au même pseudo.

Cette source est anonyme : aucune session Instagram n'est exigée ni demandée. L'API anonyme historique (`users/web_profile_info`, puis `feed/user/<id>`) est fermée par Instagram, qui répond 404 à tout client non connecté : le parcours lit la page publique du profil, y prend les jetons d'API (`lsd`, `fb_dtsg`), puis interroge le point GraphQL paginé du site (`graphql/query`, requête `PolarisProfilePostsTabContentQuery_connection`), 12 publications par page, 100 pages au plus par exécution. Quand Instagram oppose son quota anonyme, le rendu SEO de la page (agent Googlebot) sert de repli : les douze dernières publications, images seules, sans pagination. Les carrousels sont pris en entier : chaque image et vidéo de la publication est téléchargée. Les clés `igm-<média>` et `igv-<média>` inscrites dans les noms de fichiers évitent de retélécharger les médias présents, même si les URL du CDN changent entre les formats de réponse.

Fin octobre 2026, Instagram a renommé cette requête (anciennement `PolarisProfilePostsQuery` sur `api/graphql`), changé son `doc_id` et rendu obligatoires plusieurs variables Relay : les clients qui envoyaient l'ancienne forme recevaient `missing_required_variable_value`, donc plus aucune vidéo, et retombaient sur le repli SEO, images seules. Le `doc_id` et la liste des variables Relay ne sont donc plus écrits en dur : ils sont lus dans les paquets JavaScript servis avec la page du profil, comme le fait le navigateur. Si la requête reste introuvable dans ces paquets, le journal le dit et le parcours garde ses valeurs par défaut au lieu d'échouer.

Instagram peut opposer son mur de connexion à tout moment (compte privé, fermeture du profil, vérification exigée) : le parcours s'arrête alors proprement, les médias déjà téléchargés restent en place, et le message explique la cause. Un compte introuvable produit un message explicite plutôt qu'un « aucun média » silencieux. Deux pages sans nouveauté suffisent à considérer le compte rattrapé.

## Flux `.rss` Reddit : repli sur `old.reddit.com`

Depuis novembre 2026, `www.reddit.com` ne sert plus ces flux : `/r/<sub>/.rss`, `/r/<sub>/new.rss` et `/user/<nom>/submitted.rss` répondent un document Atom **« Not Found »** émis par `rss.reddit.com` (HTTP 404), alors que la page d'accueil du site répond toujours 200 et que le `429` de quota, lui, reste possible. Un `404` sur une adresse `.rss` déclenche donc un **unique** nouvel essai sur `old.reddit.com` — même chemin, mêmes paramètres, jeton privé des sauvegardés compris. Le journal indique les deux tentatives et laquelle a servi :

```text
Flux Reddit refusé (HTTP 404) sur /r/pics/new.rss — nouvel essai sur old.reddit.com/r/pics/new.rss.
Repli old.reddit.com : flux servi (N octets).
```

Le repli ne s'applique ni à un hôte tiers, ni à une adresse qui n'est pas un flux `.rss`, et il ne boucle jamais : une adresse déjà sur `old.reddit.com` n'en a pas. Si le repli est refusé à son tour, le parcours s'arrête avec l'erreur d'origine.

## Médias TikTok (`tt`), vidéos isolées et sauvegardés du compte (`ts`)

### Marche à suivre

1. **Réglages → Se connecter à TikTok.** La fenêtre intégrée ouvre `https://www.tiktok.com/` ; utiliser ses identifiants TikTok. Les boutons « Continuer avec Google / Facebook / Apple » sont acceptés. La session est conservée dans un stockage WebKit propre à TikTok, distinct de ceux de Reddit et de X : une déconnexion TikTok n'efface ni l'une ni l'autre, et inversement. Comme elle est persistante, la connexion est retrouvée après un redémarrage, jusqu'à expiration des cookies ou déconnexion explicite.
2. **Bouton de source → `tt`** pour les médias publics d'un compte ou une vidéo isolée, **`ts`** pour ton propre compte.
3. **`tt`** : saisir le pseudo (`nasa`), avec `@`, avec le préfixe `tt/`, ou coller `tiktok.com/@nasa`. Une **vidéo isolée** est acceptée telle quelle : coller `tiktok.com/@pseudo/video/…` (ou `…/photo/…`, ou un lien court `vm.tiktok.com/…`) ne télécharge que cette vidéo. **`ts`** : un sélecteur propose trois cibles — **toutes les publications enregistrées**, **un dossier de favoris** de ton choix, ou **un compte précis**.
4. **Lancer.** Le parcours crée la collection `tt/pseudo` (dossier `tk.pseudo`), `ts/pseudo` (dossier `ts.pseudo`) ou, pour une vidéo isolée, `ttv/<identifiant>` (dossier `ttv.<identifiant>`) — la relance du même lien ne retélécharge rien.
5. **Vérifier dans le journal** (bouton `doc.text.magnifyingglass`) les lignes `TikTok :` : elles disent quelle voie a servi, combien de publications ont été lues, et pourquoi un média a été écarté.

Les deux modes exigent une session TikTok : un profil public comme les sauvegardés sont lus avec les cookies de la session, et un parcours lancé sans connexion s'arrête sur un message explicite plutôt que de rendre zéro média. La connexion se fait une fois, dans les Réglages.

### Ce que fait le parcours

- **Résolution du compte.** Pour `tt`, le `secUid` est lu dans le JSON d'hydratation de la page profil. Pour `ts`, le compte connecté est demandé au site lui-même : c'est la seule source fiable, le premier lien `/@` d'une page de fil désignant un créateur voisin et non le propriétaire.
- **Pagination.** La route `api/post/item_list` exige une signature que seul le JavaScript de TikTok produit. Le parcours tente d'abord un appel « desktop » ; au premier refus, une WebView cachée branchée sur la session charge la page et laisse le site signer lui-même ses requêtes, dont les réponses sont capturées.
- **Qualité.** Chaque vidéo est prise dans la variante de plus haute définition listée dans `bitrateInfo` (la définition prime sur le débit : un 1080p à débit plus bas reste plus fin qu'un 720p). Les diaporamas sont pris image par image.
- **Miroirs et replis.** Chaque entrée de `urlList` est un miroir CDN du même média (`v16-`, `v19-`…) : un nœud qui refuse n'empêche pas le transfert. Si tous refusent, le média est redemandé depuis la page, puis par une navigation WebKit conduite par le navigateur lui-même.

### Points d'entrée utilisés

Tous les appels passent par une page `tiktok.com` chargée dans la session : les cookies, le `msToken` et la signature sont ceux du vrai client.

| Point d'entrée | Rôle |
|---|---|
| `GET https://www.tiktok.com/@<pseudo>` | page d'un profil ; son JSON `__UNIVERSAL_DATA_FOR_REHYDRATION__` donne le `secUid` et la première page de publications |
| `GET https://www.tiktok.com/passport/web/account/info/?aid=1988` | **identité du compte connecté** : `username` et `sec_uid`. Répond `user_id: "0"` hors session |
| `GET https://www.tiktok.com/api/user/collection_list/` | dossiers de favoris du compte (`collectionId`, nom, total), paginés par `cursor` |
| `GET https://www.tiktok.com/api/collection/item_list/?aid=1988&collectionId=…&count=30&cursor=…&sourceType=113` | publications d'un dossier. **Cinq paramètres seulement** (voir plus bas) |
| `GET https://www.tiktok.com/api/user/collect/item_list/` | toutes les publications enregistrées du compte |
| `GET https://www.tiktok.com/api/post/item_list/` | publications d'un profil (essai « desktop » avant la WebView) |

### Deux pièges à ne pas réintroduire

- **`api/collection/item_list` refuse le contexte complet.** `collection_list` accepte les ~25 paramètres de contexte web (région, fuseau, `device_id`, `browser_version`…) ; `api/collection/item_list` les accepte aussi mais répond `{"itemList":[]}` — un dossier rempli renvoyait 235 octets et zéro publication. La forme de référence, celle de yt-dlp, n'en porte que cinq : `aid`, `collectionId`, `count`, `cursor`, `sourceType`. L'application envoie la forme complète d'abord, puis retente avec la forme minimale si la page revient vide, et journalise le corps reçu pour trancher.
- **L'identifiant d'un dossier se lit dans ses deux formes.** Un nœud `collection_list` peut porter `collectionId` en nombre et un `id` en texte : lire les chaînes avant les nombres laisse gagner un faux identifiant. Chaque clé est donc lue en chaîne *et* en nombre avant de passer à la suivante.

### Routes mortes

Ces adresses ne doivent pas être réintroduites : elles répondent une redirection ou une page d'erreur, jamais un média ni un fil.

| Route | Réponse constatée |
|---|---|
| `tiktok.com/saved`, `/favorites`, `/bookmarks`, `/collections` | `302` vers `/404?fromUrl=…` |
| `www.tiktok.com/aweme/v1/play/` | `302` vers `/404`, donc du HTML |

Les URL de média servies par `www.tiktok.com` lui-même sont écartées à la lecture, comme le fait yt-dlp. Les conserver ne produisait qu'un essai mort par média, et l'erreur `invalid` qui en résultait court-circuitait le repli WebView.

### Signature des appels

Le SDK que le site charge publie son point d'entrée sous `self.byted_acrawler` (snake_case) ; la graphie historique `bytedAcrawler` n'existe plus. `frontierSign(url)` est le seul point d'entrée exporté — `sign` n'existe pas — et rend les paramètres attendus par les routes paginées (`X-Bogus`, `X-Gnarly`, `X-Mssdk-Info`), reportés tels quels sur l'URL. Le nom du signataire est cherché sous plusieurs graphies pour survivre à un changement de génération ; s'il reste introuvable, le journal le dit explicitement au lieu de laisser croire à une session expirée.

### Limites

Un compte privé, un profil sans média ou une vérification (captcha) exigée par TikTok arrêtent proprement le parcours avec un message explicite. Les URL de médias expirent après quelques heures : une session fraîche les régénère. Aucun contournement de captcha n'est implémenté.

## Journal des échecs et nouvel essai

Un média inaccessible pendant un parcours était compté « ignoré » puis oublié : marqué vu, il n'était jamais réévalué. Le bouton **triangle d'avertissement** (barre d'outils) ouvre désormais le journal des échecs : chaque média en échec y reste inscrit, avec sa collection, le nom de fichier prévu et la cause, jusqu'à réparation ou effacement. Le badge du bouton montre le nombre d'échecs en attente.

Le bouton **Réessayer** redemande l'adresse directe du média avec ses en-têtes d'origine (Referer, UA navigateur), vers le même dossier et le même nom de fichier ; **Tout réessayer** traite la liste entière. Une réussite retire l'entrée, un nouvel échec rafraîchit sa date et son message. Un média sans adresse directe (GIF RedGifs, vidéo DASH Reddit) reste dans le journal avec la consigne de relancer sa collection. Le journal est borné à 500 entrées et survit aux relances de l'app.

## Test de santé des sources

Réglages → Diagnostic → Test de santé des sources interroge chaque source configurée avec une requête légère et dit ce qui marche : flux public Reddit, jeton temporaire RedGifs, sessions Reddit / X / TikTok, API web Instagram, site X-Fetish. Un refus affiche le message exact du serveur au lieu d'un « aucun média » silencieux ; une session absente est signalée comme telle, sans erreur. Les sondes sont anonymes : aucun identifiant n'est envoyé.

## Optimisations de la galerie et des aperçus

- Les aperçus des profils suivis sont réutilisés en mémoire (budget de cache : 32 Mio, 100 entrées ; les images de plus de 4 Mio ne sont pas conservées). Le système peut libérer ce cache ; il est vidé au changement de session et ne persiste pas après fermeture.
- La galerie lit les fichiers en arrière-plan, avec une seule lecture des attributs par fichier. Une lecture annulée ou dépassée ne remplace pas la collection courante. Un indicateur apparaît pendant le premier chargement.
- Le téléchargement reste organisé page par page : préparation des noms, dédoublonnage et migration des anciens fichiers dans `prepareDownloads`, puis transferts via `ConcurrentDownloads`. Les règles de pagination et les limites réseau sont conservées.

Vérification sur iPhone : rouvrir un profil pour vérifier les aperçus, changer rapidement de collection, puis télécharger et supprimer des médias pendant les rafraîchissements de la galerie. Vérifier aussi arrêt/reprise, noms identiques et anciens fichiers nommés par empreinte. Les tests `CollectionFilesTests` couvrent le filtrage, la taille totale, les dossiers absents et l'annulation.

## Créer le dépôt et lancer la compilation

Dans Suivis, toucher le cercle à côté d’un utilisateur affiche une coche verte « Déjà téléchargé » ; toucher à nouveau retire la marque. Ce repère manuel est enregistré localement dans les préférences de l’app et reste présent après fermeture et relancement. Il est associé au pseudo sans distinction de majuscules, partagé entre les sessions Reddit sur cette installation et indépendant des fichiers de la galerie. Il ne change pas automatiquement lors d’un téléchargement ou d’une suppression de fichiers.

À vérifier sur iPhone : cocher deux comptes, en décocher un, fermer complètement puis relancer l’app et rouvrir Suivis ; seule la coche conservée doit apparaître. Vérifier aussi que la coche ne déclenche ni l’ouverture du profil ni un téléchargement.

Nom proposé : `Leboxis/RedditMediaPocket`.

Depuis un ordinateur équipé de Git et GitHub CLI, après `gh auth login`, lancer dans ce dossier :

```bash
git init -b main
git add .
git commit -m "Add anonymous RSS iPhone downloader prototype"
gh repo create Leboxis/RedditMediaPocket --public --source=. --remote=origin --push
```

Cette commande crée un dépôt **public** : le code et les releases deviennent publics, ce qui permet à LiveContainer de télécharger l'IPA sans authentification GitHub. Aucun média téléchargé n'est envoyé à GitHub. Une autre possibilité est de créer le dépôt avec un README depuis GitHub et de communiquer son URL pour y transférer le projet.

Le premier push sur `main` lance `.github/workflows/build.yml` :

1. Tests Swift des parseurs et tests Python du générateur JSON.
2. Génération du projet avec XcodeGen et compilation iPhone Release sans signature.
3. Création de `Payload/RedditMediaPocket.app` puis de l'IPA.
4. Génération d'un `apps.json` avec la vraie taille, la version et l'URL de l'IPA.
5. Publication d'une release `v0.1.<numéro du run>` contenant IPA, JSON et icône.

Le workflow utilise le `GITHUB_TOKEN` automatique avec `contents: write`. Aucun certificat Apple ni secret personnel n'est requis pour cette IPA invitée non signée. LiveContainer doit déjà être correctement installé et configuré. L'installation d'une IPA non signée dans iOS directement n'est pas prise en charge. Les politiques du compte GitHub peuvent limiter Actions ou la création des releases.

## Ajouter la source LiveContainer

**Après la première release réussie seulement**, ajouter cette URL dans Sources → `+` :

```text
https://github.com/Leboxis/RedditMediaPocket/releases/latest/download/apps.json
```

Si le dépôt porte un autre nom, adapter cette URL ; le workflow utilise automatiquement le nom réel du dépôt pour les liens du JSON. À chaque push sur `main`, une nouvelle release est publiée. Rafraîchir la source dans LiveContainer puis installer la version proposée. Le bundle ID reste stable pour les mises à jour. Vérifier sur l'iPhone que LiveContainer conserve bien le conteneur de données.

## Médias et limites

| Média | Prototype |
|---|---|
| Images liées directement sur i.redd.it / i.imgur.com | JPG, PNG, GIF, WebP, téléchargement de l'original |
| MP4 direct sur ces mêmes hôtes | Téléchargement direct |
| Vidéo v.redd.it | Manifest DASH, meilleure résolution exposée, assemblage audio si présent |
| RedGIFs `/watch/` ou `/ifr/` | API RedGIFs avec jeton temporaire anonyme ; pas de compte |
| Comptes RedGifs (`RG/pseudo`) | Liste `users/<pseudo>/search` (vérifié : 158 médias sur `upset_trash_3094`), HD puis SD par média |
| Comptes X (`tw/pseudo`) | Fil `/media` authentifié : images en `name=orig`, vidéos et GIF en plus haut débit MP4 |
| Galerie Reddit | Non prise en charge ; indiquée dans le journal |
| Autres hébergeurs / galeries Imgur | Non pris en charge |
| Privé, supprimé, accès soumis à connexion | Non accessible |

RedGIFs utilise son propre service API ; aucune API Reddit n'est utilisée. X n'a aucun accès anonyme et passe par son API GraphQL interne, qui exige une session : cette source n'est donc pas comparable aux autres, qui restent sans compte. Les structures distantes peuvent changer. Les manifests DASH segmentés sans fichier complet par représentation ne sont pas pris en charge. Un média supprimé ou inaccessible (ex. HTTP 404) est ignoré et compté « inaccessible » sans arrêter le parcours ; si le fichier HD RedGIFs est inaccessible, la variante SD exposée est essayée avant de le compter ainsi, et un HTTP 410 du service RedGIFs signifie que le contenu a été retiré de leur côté (aucun repli possible). Aucune vidéo muette n'est enregistrée silencieusement à la place d'une vidéo dont la piste audio a échoué. Seules les erreurs de flux RSS, l'annulation et un HTTP 429 arrêtent la session et restent visibles.

## Comportement réseau et stockage

- De 1 à 16 médias simultanés (10 par défaut pour toutes les sources), remplacement immédiat de chaque transfert terminé. Aucun délai de départ n’est appliqué par service. Les transferts peuvent se chevaucher. Aucun débit ne garantit l’accès.
- Pas de cookies persistants, compte, proxy, rotation d'identité ou tentative de contournement.
- Un HTTP 429 arrête la session entière, flux RSS comme média, et annule les transferts en vol. L’alerte indique uniquement la cause (service et code HTTP) et le nombre total de médias conservés dans la collection. Les limites annoncées par le serveur sont mémorisées, mais une relance manuelle efface ces limites et le cache RSS puis retente le réseau ; un refus réel du serveur peut donc se reproduire.
- Les curseurs des nouveautés et de l’historique restent distincts. Seule une page complètement traitée est validée ; une page interrompue est reprise et les fichiers complets déjà présents sont ignorés. L’ancien historique est reconstruit une fois par collection pour récupérer les posts marqués à tort comme terminés par les versions précédentes.
- Les médias sont dans `Documents/<pseudo>/`, accessibles via le bouton de partage. LiveContainer peut également exposer les documents de l'app invitée. Aucun post texte n'est enregistré.
- Garder l'application au premier plan. Le prototype n'implémente pas de service de téléchargement en arrière-plan.
- Vérifier l'espace libre et télécharger les médias que l'on a le droit de conserver.

## Développement et validation

Dans Suivis, toucher un compte ouvre ses posts avec les images et les miniatures RSS disponibles. Toucher une image ou le bouton de lecture d’une vidéo ouvre l’original dans la visionneuse. Les vidéos Reddit utilisent l’assemblage audio/vidéo existant ; RedGIFs utilise la résolution existante. Le média est récupéré dans un fichier temporaire supprimé à la fermeture de la visionneuse, sans ajout à la collection. Les miniatures servent uniquement à l’affichage et ne remplacent jamais les originaux téléchargés. Les galeries et hébergeurs non pris en charge peuvent afficher une miniature « Aperçu uniquement ». Une miniature absente n’empêche pas d’ouvrir un original pris en charge. L’aperçu liste la première page RSS disponible.

Sur macOS avec Xcode :

```bash
swift test
python3 -m unittest discover -s scripts -p 'test_*.py'
brew install xcodegen
python3 scripts/make_icon.py
xcodegen generate
open RedditMediaPocket.xcodeproj
```

Les tests Swift vérifient le RSS Atom, le rejet d'une page de blocage, les liens originaux, la déduplication, les noms d'utilisateur, et les pistes DASH avec/sans audio. Les tests Python vérifient le JSON de source, la taille réelle, les URLs versionnées et le rejet d'une archive invalide. Ils ne prouvent pas la compatibilité actuelle des hébergeurs.

Avant de qualifier une release de fonctionnelle sur iPhone : compiler avec succès, installer dans LiveContainer, essayer un profil avec image, une vidéo avec audio et un lien RedGIFs, interrompre/reprendre, puis tester une seconde release pour la conservation des fichiers. Aucun accès anonyme exhaustif n'est garanti.

## Galerie et téléchargements simultanés

Interface compacte : sélecteur `u/`, `r/`, `RG`, `♥` ou `x/`, nom (ou « Sauvegardés du compte connecté » pour le cœur), bouton démarrer/arrêter, compteur et grille de trois colonnes. Les fichiers déjà présents dans Documents sont chargés au lancement, tous profils confondus. Les images sont réduites pour les miniatures et les vidéos utilisent une image extraite localement. Toucher une miniature ouvre la prévisualisation native avec zoom ou lecture et partage. Aucun téléchargement réseau de miniature.

La limite choisie, de 1 à 16 médias, couvre la résolution, le transfert et l’assemblage. Sans préférence enregistrée, toutes les sources utilisent 10 emplacements. Un emplacement se remplit dès sa libération. Les étapes audio et vidéo d’un même média restent séquentielles. Un jeton RedGIFs partagé évite les authentifications anonymes concurrentes. L’arrêt, une erreur ou un HTTP 429 annule les autres transferts. Les fichiers complets restent conservés.

Les tests de concurrence vérifient le plafond de trois, le remplacement avant la fin du transfert le plus lent, l’annulation après erreur et le bouton arrêter.

## Export et navigation

Le bouton de partage en haut à droite exporte tous les médias actuellement téléchargés via la feuille de partage iOS. Il partage les fichiers originaux par URL sans charger toute la galerie en mémoire. Les destinations proposées et leurs limites dépendent d’iOS et des apps installées.

La visionneuse reçoit un instantané de la galerie et ouvre le média touché ; balayer à gauche/droite passe aux éléments suivants/précédents, images et vidéos mélangées. Le partage intégré suit le média affiché. Les téléchargements arrivant pendant la consultation apparaissent après réouverture de la visionneuse.

Les hôtes Reddit et redd.it partagent un délai, tout comme les hôtes API/CDN RedGIFs. Tant qu’un délai est en cours, les nouvelles requêtes vers ce service sont évitées localement. La session s’arrête au premier refus HTTP 429, quel que soit le service : aucun parcours partiel « à reprendre » n’est proposé, et le bandeau de services en pause a été supprimé. Relancer repart immédiatement et retoque le serveur. Les anciens délais globaux sont respectés jusqu’à leur expiration car leur source n’était pas enregistrée. Aucun réglage ne garantit l’absence de limitation serveur.

## Qualité et investigation du débit

La meilleure qualité signifie la meilleure variante exposée par le chemin public pris en charge, pas le fichier source privé de l’auteur. Les images sont copiées telles quelles ; aucune réduction n’est appliquée au fichier enregistré. Seules les miniatures de galerie sont réduites en mémoire. Les suffixes Imgur de miniature sur identifiants historiques de 5/7 caractères sont retirés ; les autres liens restent inchangés. Reddit preview.redd.it n’est jamais utilisé comme original.

Pour DASH, la priorité est hauteur, largeur, fréquence d’images puis débit ; les attributs hérités de l’AdaptationSet sont lus. La piste audio au débit maximal est choisie. AVAssetExportPresetPassthrough conserve les pistes sans recompression. Si le manifest nécessite SegmentTemplate/SegmentList, cette version échoue explicitement plutôt que choisir discrètement une piste inférieure. RedGIFs prend HD quand cette URL existe ; SD seulement si le serveur n’expose pas HD. Une erreur HD ne déclenche pas de repli SD. Les fichiers anciens ne sont pas requalifiés ou remplacés automatiquement.

Investigation : aucune cadence sûre officielle trouvée pour le RSS anonyme et les CDN utilisés. Le quota Reddit Data API de 100 requêtes/minute concerne les clients OAuth et ne doit pas être transposé au RSS de cette app. Augmenter le nombre de connexions provoque davantage de 429 ; aucune accélération chiffrée n’est revendiquée. Mesure relevée sur `www.reddit.com/r/…/new.rss` : un 429 y est renvoyé avec `x-ratelimit-used`, `x-ratelimit-remaining: 0.0` et `x-ratelimit-reset`, mais sans `Retry-After`. C’est la raison du repli sur `x-ratelimit-reset`.

L’amélioration mise en œuvre vise les requêtes évitables : 16 pages RSS maximum réutilisables pendant 120 secondes, en mémoire seulement, limitées à 2 Mo chacune. Cela sert aux arrêts/reprises proches et peut retarder l’apparition d’un nouveau post de deux minutes. Les fichiers complets sont toujours ignorés à la reprise. Les en-têtes X-Ratelimit-Remaining/Reset ne ralentissent plus les requêtes : seuls les refus réels limitent, et un quota annoncé sans refus reste sans effet. Les délais de base et le plafond de trois transferts restent inchangés.

Références consultées :
- Reddit : https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki
- Apple : https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough
- Sélection des formats RedGIFs dans yt-dlp : https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/redgifs.py
- Modèle d’images et miniatures Imgur : https://api.imgur.com/models/image
- TikTok, formats et filtrage des URL mortes dans yt-dlp : https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/tiktok.py
- TikTok, `collection_list`, signature et défi JavaScript dans gallery-dl : https://github.com/mikf/gallery-dl/blob/master/gallery_dl/extractor/tiktok.py
- Formats TikTok cassés servis par `www.tiktok.com` : https://github.com/yt-dlp/yt-dlp/issues/11034

## Réglage de la concurrence

La roue dentée ouvre le réglage de 1 à 16 médias simultanés (10 par défaut pour toutes les sources). Un choix explicite reste mémorisé et prioritaire pour toutes les sources. Chaque session fixe sa limite au démarrage ; un changement pendant les transferts s’applique au prochain lancement. Le compteur affiche la limite effective. Choisir 1 ou 2 peut réduire la fréquence des 429, sans garantie. La source `tw` utilise en revanche la session WebKit de X, décrite plus haut.

## Connexion Reddit locale

Réglages → Se connecter à Reddit. Saisir ses identifiants directement sur le site Reddit dans la fenêtre intégrée, puis Terminé. WebKit conserve la session dans son stockage local à l’app. Aucun mot de passe n’est lu par le code Swift, aucun cookie n’est envoyé à GitHub et aucun formulaire natif ne collecte les identifiants. La connexion par fournisseurs externes n’est pas intégrée ; utiliser l’identifiant Reddit.

Les requêtes HTTPS reddit.com peuvent recevoir les cookies correspondants à leur domaine, chemin et expiration. Les cookies ne sont jamais appliqués à redd.it, RedGIFs ou Imgur. Chaque redirection reconstruit les cookies pour sa destination et retire l’autorisation lors d’un changement d’hôte. Les navigations principales de la fenêtre de connexion sont limitées à HTTPS reddit.com et ses sous-domaines.

Déconnexion supprime les cookies et autres données WebKit de l’app. Le changement de session invalide le cache RSS. Connexion et déconnexion sont désactivées pendant les téléchargements pour éviter un changement de compte en cours de transfert. Une déconnexion n’efface pas les pauses enregistrées, mais le démarrage d’une session les efface toujours. La présence de reddit_session affiche « Session détectée », sans prétendre avoir vérifié le compte côté serveur. En cas de session expirée, rouvrir Reddit depuis les réglages.

Cette fonction reste à valider dans LiveContainer avec une connexion réelle sur l’iPhone. Elle ne garantit ni l’acceptation du RSS authentifié, ni la suppression des blocages et quotas. L’app continue de lire le RSS sans API JSON Reddit. La session sert aussi à lire l’onglet Sauvegardés (`♥`) du compte.

## Transferts immédiats et état de session

Les pauses artificielles de départ ont été supprimées, ainsi que le lissage du débit inféré des quotas encore disponibles. Aucun Task.sleep n’est utilisé par la couche réseau. Les tâches démarrent dès qu’un emplacement est libre. Seul un refus HTTP 429 arrête la session ; l’app applique alors le délai annoncé par le serveur, ou aucun délai si le serveur n’en annonce pas.

Le compteur affiche les médias en cours de transfert réseau, et non la totalité des tâches de résolution/assemblage ni chaque morceau HTTP d'une vidéo X-Fetish. Le nombre choisi est un maximum de médias traités simultanément ; il peut être inférieur pendant la découverte RSS, les résolutions, l’assemblage ou à la fin d’une page.

L’état de session est visible dans les réglages et la connexion ; le bandeau est retiré de la galerie. Il reflète la présence du cookie attendu, sans prétendre confirmer la validité du compte côté serveur.

## Interface et indicateurs

La galerie affiche des compteurs de largeur égale et centrés : fichiers locaux tous profils confondus, somme des tailles des fichiers terminés, puis nouveaux fichiers reçus / repérés pendant le parcours en cours. Le dénominateur progresse à chaque page ; les fichiers déjà présents sont exclus de ce dénominateur. Il ne constitue pas un maximum exhaustif de l’historique Reddit. Les téléchargements échoués ou limités restent dans le total repéré.

En mode `x/`, une barre d'avancement linéaire s'affiche sous les compteurs pendant le téléchargement. Elle porte sur l'unité connue : un album, ou la liste des vidéos collectées sur au plus 100 pages, pas sur un historique exhaustif du profil. Les octets reçus de tous les morceaux d'une vidéo sont additionnés, avec une mise à jour au plus toutes les 300 ms par vidéo, puis ajoutés à l'avancement des fichiers terminés. Une relecture du jeton ou un repli complet peut faire repartir la vidéo concernée de zéro.

La connexion est présentée en plein écran. Une seule barre supérieure affiche reddit.com et une croix. La vue Web est contrainte au guide UIKit du clavier, et le déplacement automatique de l’ensemble par SwiftUI est désactivé pour cet écran.

Quick Look est remplacé par une visionneuse plein écran : fond noir, titre tronqué au milieu et centré entre commandes de même largeur, index centré, croix et partage. Les vidéos utilisent AVPlayer et s’arrêtent quand on quitte leur page. Les images disposent d’un zoom par pincement/double toucher. Seuls les médias voisins sont préparés ; les images d’affichage sont limitées à 4096 pixels, sans modifier les originaux téléchargés ou partagés. Les GIF sont affichés dans une vue Web locale non persistante sans JavaScript.

À vérifier sur iPhone : connexion avec clavier visible, balayage des images et vidéos, fermeture du lecteur, zoom et partage. La compilation CI ne remplace pas ces essais d’interface.

## Galerie compacte et zones tactiles

Les compteurs sont regroupés sur une ligne de texte sans panneau de fond. La ligne de transfert, son spinner et son espace réservé sont supprimés. Les erreurs apparaissent dans une alerte ponctuelle, sans duplication dans la ligne d’état au-dessus des médias. Un échec de téléchargement indique seulement sa cause et le nombre total de médias conservés dans la collection. Les erreurs des aperçus, de la connexion et de kDrive sont également présentées dans des alertes natives.

Chaque bouton de galerie définit une zone tactile rectangulaire et les overlays décoratifs ne participent pas au hit-testing. Le découpage visuel seul de scaledToFill ne suffisait pas à borner la zone tactile. Vérifier sur iPhone les touchers près du bord supérieur d’une vidéo et du bord inférieur de la carte qui la précède.


## Langues et informations des médias

Au premier lancement, la langue principale de l’appareil sélectionne le français si elle est française, sinon l’anglais. Le choix est mémorisé et modifiable dans Réglages → Langue, lorsque les téléchargements sont arrêtés. Les commandes, confirmations, libellés d’accessibilité et erreurs de l’app sont bilingues ; le site Reddit conserve sa propre langue.

Une pastille de 7 points près du titre Pocket est verte pendant un parcours de téléchargement (recherche, transfert et assemblage compris), rouge au repos, après arrêt ou erreur. VoiceOver annonce son état. Les collections de sauvegardés portent uniquement le libellé « Saved » ; leurs identifiants et dossiers restent distincts pour chaque compte.

Un appui long sur une vignette propose Informations du média. La fiche présente le nom complet copiable, le poids, le format, la résolution, la durée vidéo, la fréquence d’images, le débit estimé et les dates de téléchargement/publication. Les caractéristiques sont lues dans le fichier local, sans requête réseau. Les dates sont enregistrées avec les nouveaux téléchargements dans un sous-dossier caché `.metadata`, exclu de la galerie et du partage. Elles suivent le renommage hérité et la suppression du média. Les anciennes dates non enregistrées ou absentes du flux affichent « Indisponible » ; la date de modification du post ne remplace pas sa date de publication.

Vérification sur iPhone : premier lancement en fr-FR, fr-CA et en-US, changement manuel de langue, appui long sur image/vidéo et ancien fichier, nom long et grande taille de texte, état de la pastille au démarrage/arrêt/erreur et passage en arrière-plan.
