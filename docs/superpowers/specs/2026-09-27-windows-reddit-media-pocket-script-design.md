# Script Python Windows — Reddit Media Pocket

## Objectif

Porter sur Windows le pipeline de téléchargement de médias de l'app iOS RedditMediaPocket, sous forme d'un script Python en ligne de commande, avec une journalisation exhaustive permettant de diagnostiquer n'importe quel échec.

Le script reprend les décisions de nommage, de pagination, de qualité et de politique réseau de `Sources/MediaCore` et de la couche `App/`, afin qu'une collection téléchargée sous Windows soit compatible avec celle produite par l'app.

## Contraintes

- Python 3.10 ou plus récent, installation sur une machine sans environnement de développement.
- Aucune dépendance externe : bibliothèque standard uniquement. Aucun `pip install`.
- ffmpeg facultatif : détecté s'il est présent dans le `PATH`, sinon les vidéos v.redd.it sont conservées sans piste audio avec un avertissement journalisé.
- Utilisateur non développeur : une seule commande, aucun serveur à lancer, aucun fichier de configuration à remplir.

## Emplacement

`scripts/reddit_media_pocket.py` — un seul fichier. Décision arbitrée pour la portabilité (copie, exécution immédiate) et parce que tout le diagnostic se lit dans un seul artefact.

Le script vit à plat dans `scripts/`, aux côtés des utilitaires Python déjà présents, et son fichier de test est `scripts/test_reddit_media_pocket.py`. Il est donc couvert par la commande de test existante du dépôt, `python -m unittest discover -s scripts -p 'test_*.py'`, sans configuration supplémentaire.

## Interface en ligne de commande

```
python reddit_media_pocket.py <source> [options]
```

Source, une seule par exécution :

| Forme | Flux |
|---|---|
| `u/<pseudo>` | Posts soumis du profil |
| `r/<subreddit>` | Subreddit, tri `new` (défaut), `hot` ou `top` avec `t=month` |
| `saved` | Sauvegardés du compte connecté |

Options :

| Option | Effet |
|---|---|
| `--sort new\|hot\|top` | Tri pour `r/`, ignoré ailleurs |
| `--out CHEMIN` | Dossier de sortie, défaut `Documents/<dossier>/` |
| `--concurrent N` | Médias simultanés, 1 à 6, défaut 3 |
| `--max-pages N` | Plafond de pages, défaut 100 |
| `--limit N` | Arrêt après N médias téléchargés, pour un essai court |
| `--max-errors N` | Arrêt après N échecs non transitoires, défaut 0 (illimité) |
| `--resume` | Reprend depuis le point d'arrêt mémorisé |
| `--dry-run` | Dresse la liste des médias sans écrire de fichier |
| `--verbose` | DEBUG en console en plus du fichier |
| `--log-dir CHEMIN` | Dossier des journaux, défaut `logs/` à côté du script |
| `--cookies CHEMIN` | `cookies.txt` Netscape, ou fichier contenant la valeur brute de `reddit_session` |
| `--log-level N` | 10=DEBUG, 20=INFO, 30=WARNING |

Le compte est déduit de la session : OAuth en priorité, sinon du nom d'utilisateur présent dans le lien privé lu sur `old.reddit.com/prefs/feeds/`. L'utilisateur ne saisit jamais de pseudo pour `saved`.

## Modes d'authentification

### Flux publics

Aucun compte, aucun cookie. `https://www.reddit.com/user/<u>/submitted.rss?limit=100&after=<curseur>` et `https://www.reddit.com/r/<sub>/<tri>.rss?limit=100&after=<curseur>`, avec `t=month` en premier paramètre pour `top`.

### Flux sauvegardés — OAuth

Flux « installed app », identique à celui de gallery-dl, parce qu'il évite toute manipulation de cookie.

1. Premier lancement : absence de jeton dans `%LOCALAPPDATA%\RedditMediaPocket\token.json`.
2. Ouverture du navigateur sur
   `https://www.reddit.com/api/v1/authorize?client_id=6N9uN0krSDE-ig&response_type=code&state=<aléatoire>&redirect_uri=http%3A//localhost%3A6414/&duration=permanent&scope=read%20history`
3. Serveur HTTP local sur le port 6414, actif le temps de l'échange, qui intercepte `?code=` et `?state=`.
4. Vérification du `state` reçu contre celui émis : un écart fait échouer l'échange.
5. Échange du code contre un jeton sur `https://www.reddit.com/api/v1/access_token`, en `POST`, authentification Basic sur le `client_id` avec un secret vide.
6. `refresh_token` conservé en clair dans le fichier local, comme le ferait n'importe quel client OAuth installed. Aucune donnée de session Reddit n'est écrite ailleurs.
7. Lecture des sauvegardés sur `https://oauth.reddit.com/user/<moi>/saved?limit=100&after=<curseur>`, en JSON.

Les lancements suivants réutilisent le jeton et le rafraîchissent silencieusement à l'expiration. `duration=permanent` rend le `refresh_token` durable, `state` protège l'échange contre une réponse forgée.

### Flux sauvegardés — repli par cookies

Si l'OAuth échoue ou si `--cookies` est fourni, le script lit le HTML de `https://old.reddit.com/prefs/feeds/` avec les cookies du compte, en déduit le pseudo, puis reconstruit le lien privé exactement comme `SavedFeed` de l'app :

- Le lien est retenu seulement si le schéma est `https`, si l'hôte vaut `reddit.com`, `www.reddit.com` ou `old.reddit.com`, si l'URL ne porte ni identifiants ni port, et si la requête contient exactement un paramètre `user` valide et un paramètre `feed` non vide.
- Le chemin doit se normaliser en `saved.rss` ou `user/<propriétaire>/saved.rss`. Le cas `saved/.rss` est refusé.
- La requête est réduite à `feed` et `user`.
- `limit` et `after` sont ajoutés à la pagination, et le jeton ne part jamais vers un autre hôte.
- Une redirection n'est suivie que vers un chemin de sauvegardés du même compte ; sinon elle est annulée. Le changement d'hôte retire l'autorisation.

Formats acceptés pour `--cookies` :

- `cookies.txt` au format Netscape, filtré par domaine, chemin et expiration, comme `RedditCookiePolicy`.
- Un fichier contenant la valeur brute du cookie `reddit_session`, avec ou sans préfixe `reddit_session=`.

Aucun cookie n'est appliqué à `redd.it`, RedGIFs ni Imgur. Le journal masque toute valeur de cookie.

## Médias pris en charge

| Type | Source | Traitement |
|---|---|---|
| Image directe | `i.redd.it`, `i.imgur.com` | Original, jamais la miniature |
| Vidéo directe | `i.redd.it`, `i.imgur.com` en `.mp4` | Téléchargement direct |
| Vidéo Reddit | `v.redd.it` | Manifest DASH puis assemblage |
| RedGIFs | `redgifs.com/watch/<id>`, `/ifr/<id>` | API RedGIFs, HD puis SD |
| Galerie | lien `/gallery/<id>` | JSON du post, ordre du carrousel |
| Autre hébergeur | — | Signalé dans le journal, non repris |

### Dénudage Imgur

Sur `i.imgur.com`, pour une image dont l'identifiant est composé de 5 ou 7 caractères alphanumériques suivis d'un suffixe `s`, `b`, `t`, `m`, `l` ou `h`, ce dernier caractère est retiré pour obtenir l'original. Les autres liens restent inchangés. `preview.redd.it` n'est jamais utilisé comme original.

### Vidéo Reddit

1. Identifiant = premier composant du chemin, canonisé en `https://v.redd.it/<id>`.
2. Manifest `https://v.redd.it/<id>/DASHPlaylist.mpd`.
3. Le parseur refuse un manifest segmenté, donc porteur de `SegmentTemplate` ou `SegmentList`, au lieu de choisir discrètement une piste inférieure. Un échec explicite vaut mieux qu'une vidéo muette.
4. Piste vidéo retenue : hauteur, puis largeur, puis fréquence d'images, puis débit. Piste audio : débit maximal.
5. Les deux hôtes de piste doivent être `v.redd.it`, sans quoi le manifest est refusé.
6. Sans audio, la vidéo est conservée telle quelle. Avec audio, les deux flux sont téléchargés puis assemblés par `ffmpeg -c copy` si ffmpeg est présent. Sans ffmpeg, la vidéo seule est conservée, un avertissement est journalisé et le média n'est pas compté comme réussi au sens strict : il est compté comme video_seule.

### RedGIFs

1. Identifiant en minuscules.
2. `GET https://api.redgifs.com/v2/auth/temporary` pour un jeton anonyme, conservé 30 minutes et partagé par tous les téléchargements.
3. `GET https://api.redgifs.com/v2/gifs/<id>?views=yes` avec `Authorization: Bearer`, `Referer: https://www.redgifs.com/`, `Origin: https://www.redgifs.com` et `x-customheader: https://www.redgifs.com/watch/<id>`.
4. Candidats dans l'ordre : HD puis SD, filtrés sur l'hôte `redgifs.com`.
5. Un 404, 410 ou 403 passe au candidat suivant. Un 429, une annulation ou une erreur transitoire interrompt immédiatement.
6. Un jeton expiré provoque un seul rafraîchissement puis un nouvel essai.

### Galerie

Le lien `/gallery/<id>` n'est retenu que pour un post sans média direct. Le JSON `https://www.reddit.com/comments/<id>.json?raw_json=1&limit=1` fournit l'ordre `gallery_data.items` et les sources `media_metadata`, y compris les crossposts. Chaque image est reconstruite en `https://i.redd.it/<stem>.<ext>` à partir de son type MIME, et chaque vidéo passe par le pipeline v.redd.it.

## Pagination

Les règles de `FeedTraversal` sont conservées telles quelles :

- Curseur `after` = identifiant du dernier élément de la page. Il doit commencer par `t3_`, ou `t1_` pour les commentaires du flux sauvegardé.
- Plafond de 100 pages. L'atteinte du plafond sans rejoindre l'historique est signalée comme parcours incomplet, à reprendre.
- Arrêt sur page répétée, page vide, curseur refusé, ou `last == after`.
- Une page n'est enregistrée comme traitée qu'après le sort de tous ses médias. Une page interrompue est reprise, et les fichiers complets déjà présents sont ignorés.
- Historique persistant, borné à 10 000 identifiants, dans un fichier JSON local par collection.
- Un point d'arrivée mémorisé permet au lancement suivant de sauter la phase nouveautés. Il est effacé dès que le parcours rejoint l'historique, conservé si les 100 pages sont consommées sans l'atteindre.

## Nommage et stockage

Identique à `FilenamePolicy` et `CollectionFiles`.

- Racine de sortie par défaut : `Documents/`, ou `--out`.
- Dossiers : `<pseudo>` pour un profil, `r.<sub>` pour un subreddit, `saved.<pseudo>` pour les sauvegardés. Les points sont interdits dans les pseudos et les noms de subreddit, donc aucune collision.
- Nom : `<titre> - <id>.<ext>`, le titre étant normalisé en NFC, les caractères de contrôle convertis en espace, les caractères `< > : " / \ | ? *` convertis en `-`, les espaces compactés, puis le nom tronqué à 180 octets UTF-8 sans couper un caractère. Repli sur `post` si le titre se vide.
- Pour une galerie de plusieurs médias, la position 1-based s'insère dans le nom.
- Conflit de nom : suffixe `-2`, `-3`, etc., comparaison en minuscules.
- Extension déduite de l'URL pour un média direct, `mp4` pour v.redd.it et RedGIFs.
- Métadonnées : `<dossier>/.metadata/<fichier>.json` avec date de téléchargement, date de publication, auteur et lien du post. Date de création et de modification du fichier alignées sur la date de publication.

## Réseau

- Agent utilisateur `RedditMediaPocket/0.1 (Windows; RSS reader)`.
- HTTPS uniquement. Une URL non HTTPS, ou une redirection vers une URL non HTTPS, est refusée.
- Délai par requête 60 s, délai par ressource 1800 s, six connexions par hôte au maximum.
- Un 429 interrompt la session entière, flux et médias confondus, et annule les transferts en vol. Les pages non terminées ne sont pas enregistrées.
- Date de reprise : `Retry-After` en premier, date HTTP comprise, puis `x-ratelimit-reset` en secondes. Aucun en-tête, aucune pause mémorisée. Un 429 de Reddit arrive avec `x-ratelimit-used`, `x-ratelimit-remaining: 0.0` et `x-ratelimit-reset`, sans `Retry-After`.
- Un quota annoncé sur une réponse réussie n'a aucun effet : seuls les refus réels limitent.
- Erreurs transitoires : délai dépassé, connexion perdue, absence de réseau, hôte introuvable, résolution DNS, connexion sécurisée, 408 et 5xx. Elles sont retentées trois fois au maximum, avec pauses de 2 s puis 4 s.
- Un média inaccessible, en 403, 404 ou 410, est compté et la page continue.
- Trois médias simultanés par défaut, remplissage immédiat d'un emplacement libéré. Un changement de réglage ne s'applique qu'au lancement suivant.
- Aucun cookie persistant, aucun proxy, aucune rotation d'identité, aucune tentative de contournement.

## Journalisation

Objectif : un échec doit pouvoir être compris depuis le seul fichier de journal, sans relancer le script.

- Bibliothèque `logging`. Console en INFO, fichier en DEBUG. Un fichier par exécution, horodaté, dans `logs/`, de sorte qu'aucune exécution n'écrase le journal de la précédente.
- Chaque journal porte l'heure au millième, le niveau, le module, la ligne et le message.
- `logging.raiseExceptions` reste actif : une erreur de journalisation ne doit pas passer inaperçue.

### Contenu obligatoire du journal

Requêtes : méthode, URL complète, en-têtes de requête pertinents, cookies masqués, code de réponse, durée, taille reçue, contenu déclaré.

En-têtes de réponse journalisés dès qu'ils sont présents : `content-type`, `content-length`, `content-range`, `retry-after`, `x-ratelimit-used`, `x-ratelimit-remaining`, `x-ratelimit-reset`, `location`.

Décisions : pistes DASH retenues avec hauteur, largeur, fréquence et débit de chaque option écartée ; candidats RedGIFs essayés dans l'ordre avec le code de refus de chacun ; raison de chaque média ignoré, qu'il soit déjà téléchargé, dupliqué dans le parcours, en galerie non prise en charge, sur un hébergeur non pris en charge, inaccessible, ou limité ; curseur courant et raison d'arrêt de la pagination ; motif d'écriture du point d'arrivée.

Erreurs : type, message et pile complète pour toute exception non rattrapée. Une erreur attendue est journalisée avec sa cause et le fichier concerné, sans bruit de trace.

Compteurs : à chaque page, les medias vus, nouveaux, sautés, échoués, inaccessibles, limités, et les pages parcourues sur le plafond.

Résumé final : posts parcourus, médias téléchargés, sautés, échoués, inaccessibles, videos sans son, octets écrits, durée totale, raison d'arrêt, et chemin du fichier de journal.

### Sortie de diagnostic

`--dry-run` liste les médias qui seraient téléchargés, avec leur source et leur nom de destination, sans écrire aucun fichier.

## Erreurs et arrêt

- Flux RSS refusé, curseur non reconnu, 429 : la session s'arrête avec un message nommant le service et le code HTTP, et le nombre de médias conservés. Aucun parcours partiel n'est présenté comme reprenable.
- Page répétée ou page vide : fin normale du parcours, journalisée comme telle.
- Plafond de pages atteint sans rejoindre l'historique : parcours incomplet signalé, point d'arrivée conservé.
- Erreur réseau transitoire : trois tentatives, puis échec du média, la page continue.
- Erreur ffmpeg : la vidéo seule est conservée, un avertissement est journalisé, le média est compté à part.
- Au-delà de `--max-errors N` échecs non transitoires, la session s'arrête en indiquant la limite atteinte. La valeur par défaut 0 n'arrête jamais sur ce critère.
- `Ctrl+C` interrompt la session : les transferts en vol sont abandonnés, les fichiers temporaires sont supprimés, les pages non terminées ne sont pas enregistrées, et le résumé final est malgré tout écrit dans le journal.
- Fichiers temporaires : supprimés au sortir du bloc, en cas de succès comme d'échec.

## Tests

Le portage ne modifie aucun code Swift ; les tests Swift et Python existants restent valides et doivent continuer à passer.

Validation manuelle du script, sur un réseau où le flux public répond :

1. `python reddit_media_pocket.py r/test --limit 3 --verbose` : trois médias téléchargés, journal complet, aucun avertissement.
2. `python reddit_media_pocket.py u/<pseudo> --limit 3` : même résultat sur un profil ayant des images.
3. Un post v.redd.it : piste vidéo et piste audio choisies et tracées dans le journal, fichier final lisible ; avec ffmpeg absent, comportement video_seule et avertissement.
4. Un lien RedGIFs : HD retenu, ou SD après refus du HD avec la trace de chaque candidat.
5. `python reddit_media_pocket.py saved` : ouverture du navigateur, échange OAuth, lecture des sauvegardés ; puis relance sans navigateur, le jeton étant réutilisé.
6. Reprise : interrompure au milieu d'une page, relance, vérification que les fichiers complets sont ignorés et que la page est reprise.
7. Deux exécutions successives sans `--resume` : la seconde ne retélécharge rien et le journal indique les fichiers sautés.
8. Conflit de noms : deux posts de même titre produisent `nom - id.mp4` et `nom - id-2.mp4`.
9. Un subreddit inexistant et un profil inexistant produisent un message explicite, sans trace d'exception.

## Hors périmètre

- Galerie de l'interface, visionneuse, partage, export.
- Aperçus et miniatures : aucun téléchargement de miniature.
- Importation vers kDrive.
- Métadonnées binaires EXIF ou MP4 : seul le sidecar JSON est écrit.
- Identité de connection multi-comptes : un jeton à la fois.
- Persistance du cache RSS : le script n'a pas de cache en mémoire, la reprise s'appuie sur les fichiers présents et l'historique.
