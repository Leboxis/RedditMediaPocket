# Reddit Media Pocket — prototype iPhone

Application SwiftUI en français, destinée à LiveContainer (iOS 16+). On choisit `u/` (profil), `r/` (subreddit) ou `♥` (sauvegardés du compte) puis on saisit le nom — coller `u/pseudo`, `r/sub` ou `saved/pseudo` en entier fonctionne aussi — et l'application enregistre les médias directs accessibles depuis les flux RSS publics pour les profils et subreddits, ou le flux JSON privé pour les sauvegardés du compte connecté.

## État réel

Le code et le workflow sont disponibles dans ce dépôt. GitHub Actions compile et publie une IPA à chaque push sur main. Consulter le résultat du dernier workflow avant de télécharger une release. Les essais dans LiveContainer sur iPhone restent à effectuer. Un appel public au RSS de `u/reddit` a répondu HTTP 200 le 5 septembre 2026. Ce résultat ne garantit pas l'accès depuis un autre réseau ou pour un autre profil.

Ce prototype ne promet pas de télécharger tous les posts. Le flux peut tronquer l'historique, refuser la pagination ou refuser l'accès. L'application s'arrête si une page se répète, si le curseur n'est pas reconnu ou après 100 pages. Les miniatures ne sont pas utilisées à la place des originaux.

Les profils (`u/pseudo`, flux `submitted`) et les subreddits (`r/sub`, tri Nouveaux / Chauds / Top du mois) sont pris en charge. Le Top utilise le filtre serveur `t=month`. Les dossiers des subreddits sont préfixés `r.` (ex. `r.pics`) pour ne jamais entrer en collision avec un profil du même nom. Les archives existantes (pseudo nu) restent lues comme des profils.

Jusqu'à combien de posts ? Plafond théorique : 100 pages × ~25 posts par page RSS ≈ 2500 posts parcourus. En pratique, le RSS anonyme tronque bien avant : page qui se répète, curseur refusé ou HTTP 429 arrêtent le parcours, souvent après quelques centaines de posts. Le compteur « repérés » (nouveaux fichiers reçus / repérés pendant le parcours) progresse à chaque page mais ne constitue pas un total exhaustif de l'historique.

Sauvegardés (`♥`) : connecte-toi à Reddit dans les Réglages, sélectionne ♥ puis lance le téléchargement ; le champ peut rester vide. Le compte est détecté via `api/me.json` dans la session WebKit de connexion, puis ses éléments sont lus via `saved.json` dans cette même session (aucun accès à `saved.rss`). Le pseudo saisi précédemment est remplacé par le compte réellement connecté. Les publications, commentaires contenant des liens, galeries et crossposts sont pris en charge avec le curseur `after` fourni par Reddit, jusqu’à 100 pages et dans les limites de visibilité de Reddit. Une réponse 401/403 affiche un conseil de reconnexion ; une réponse 429 conserve le délai serveur, sans nouvelle tentative automatique. Les dossiers sont préfixés `saved.` (ex. `saved.leboxis`).

## Créer le dépôt et lancer la compilation

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
| Galerie Reddit | Non prise en charge ; indiquée dans le journal |
| Autres hébergeurs / galeries Imgur | Non pris en charge |
| Privé, supprimé, accès soumis à connexion | Non accessible |

RedGIFs utilise son propre service API ; aucune API Reddit n'est utilisée. Les structures distantes peuvent changer. Les manifests DASH segmentés sans fichier complet par représentation ne sont pas pris en charge. Un média supprimé ou inaccessible (ex. HTTP 404) est ignoré et compté « inaccessible » sans arrêter le parcours ; aucune vidéo muette n'est enregistrée silencieusement à la place d'une vidéo dont la piste audio a échoué. Seules les erreurs de flux RSS et l'annulation arrêtent la session et restent visibles.

## Comportement réseau et stockage

- Trois médias simultanés, remplacement immédiat de chaque transfert terminé. Les départs sont espacés par service : 7 secondes pour le RSS, 2 secondes pour les métadonnées RedGIFs, 1 seconde pour les médias. Les transferts peuvent se chevaucher. Aucun débit ne garantit l’accès.
- Pas de cookies persistants, compte, proxy, rotation d'identité ou tentative de contournement.
- Un HTTP 429 conserve le délai `Retry-After` par service entre lancements (15 minutes par défaut). Les médias des autres services déjà découverts continuent. Une limite sur le flux RSS arrête la découverte des pages suivantes. Les erreurs du flux RSS arrêtent la session ; les erreurs portant sur un seul média l'ignorent et continuent le parcours.
- Reprise par fichiers complets : relancer le pseudo saute les URLs déjà enregistrées. Un transfert interrompu recommence depuis le début. Le parcours RSS repart de la première page.
- Les médias sont dans `Documents/<pseudo>/`, accessibles via le bouton de partage. LiveContainer peut également exposer les documents de l'app invitée. Aucun post texte n'est enregistré.
- Garder l'application au premier plan. Le prototype n'implémente pas de service de téléchargement en arrière-plan.
- Vérifier l'espace libre et télécharger les médias que l'on a le droit de conserver.

## Développement et validation

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

Interface compacte : sélecteur `u/`, `r/` ou `♥`, nom, bouton démarrer/arrêter, compteur et grille de trois colonnes. Les fichiers déjà présents dans Documents sont chargés au lancement, tous profils confondus. Les images sont réduites pour les miniatures et les vidéos utilisent une image extraite localement. Toucher une miniature ouvre la prévisualisation native avec zoom ou lecture et partage. Aucun téléchargement réseau de miniature.

Trois médias maximum sont traités simultanément (résolution, transfert et assemblage compris). Un emplacement se remplit dès sa libération. Les étapes audio et vidéo d’un même média restent séquentielles. Un jeton RedGIFs partagé évite les authentifications anonymes concurrentes. L’arrêt ou une erreur autre qu’un HTTP 429 annule les autres transferts. Les fichiers complets restent conservés.

Les tests de concurrence vérifient le plafond de trois, le remplacement avant la fin du transfert le plus lent, l’annulation après erreur et le bouton arrêter.

## Export et navigation

Le bouton de partage en haut à droite exporte tous les médias actuellement téléchargés via la feuille de partage iOS. Il partage les fichiers originaux par URL sans charger toute la galerie en mémoire. Les destinations proposées et leurs limites dépendent d’iOS et des apps installées.

La visionneuse reçoit un instantané de la galerie et ouvre le média touché ; balayer à gauche/droite passe aux éléments suivants/précédents, images et vidéos mélangées. Le partage intégré suit le média affiché. Les téléchargements arrivant pendant la consultation apparaissent après réouverture de la visionneuse.

Les hôtes Reddit et redd.it partagent un délai, tout comme les hôtes API/CDN RedGIFs. Les nouvelles requêtes vers un service limité sont évitées localement, sans annuler les autres services. Les fichiers non téléchargés sont indiqués « à reprendre » ; relancer après le délai. Les anciens délais globaux sont respectés jusqu’à leur expiration car leur source n’était pas enregistrée. Aucun réglage ne garantit l’absence de limitation serveur.

## Qualité et investigation du débit

La meilleure qualité signifie la meilleure variante exposée par le chemin public pris en charge, pas le fichier source privé de l’auteur. Les images sont copiées telles quelles ; aucune réduction n’est appliquée au fichier enregistré. Seules les miniatures de galerie sont réduites en mémoire. Les suffixes Imgur de miniature sur identifiants historiques de 5/7 caractères sont retirés ; les autres liens restent inchangés. Reddit preview.redd.it n’est jamais utilisé comme original.

Pour DASH, la priorité est hauteur, largeur, fréquence d’images puis débit ; les attributs hérités de l’AdaptationSet sont lus. La piste audio au débit maximal est choisie. AVAssetExportPresetPassthrough conserve les pistes sans recompression. Si le manifest nécessite SegmentTemplate/SegmentList, cette version échoue explicitement plutôt que choisir discrètement une piste inférieure. RedGIFs prend HD quand cette URL existe ; SD seulement si le serveur n’expose pas HD. Une erreur HD ne déclenche pas de repli SD. Les fichiers anciens ne sont pas requalifiés ou remplacés automatiquement.

Investigation : aucune cadence sûre officielle trouvée pour le RSS anonyme et les CDN utilisés. Le quota Reddit Data API de 100 requêtes/minute concerne les clients OAuth et ne doit pas être transposé au RSS de cette app. Augmenter le nombre de connexions ou supprimer les pauses pourrait provoquer davantage de 429 ; aucune accélération chiffrée n’est revendiquée.

L’amélioration mise en œuvre vise les requêtes évitables : 16 pages RSS maximum réutilisables pendant 120 secondes, en mémoire seulement, limitées à 2 Mo chacune. Cela sert aux arrêts/reprises proches et peut retarder l’apparition d’un nouveau post de deux minutes. Les fichiers complets sont toujours ignorés à la reprise. Les en-têtes X-Ratelimit-Remaining/Reset, quand présents, peuvent ralentir préventivement les requêtes ; leur absence ne vaut pas autorisation d’accélérer. Les délais de base et le plafond de trois transferts restent inchangés.

Références consultées :
- Reddit : https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki
- Apple : https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough
- Sélection des formats RedGIFs dans yt-dlp : https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/redgifs.py
- Modèle d’images et miniatures Imgur : https://api.imgur.com/models/image

## Réglage de la concurrence

La roue dentée ouvre le réglage de 1 à 6 médias simultanés (3 par défaut). La préférence est mémorisée. Chaque session fixe sa limite au démarrage ; un changement pendant les transferts s’applique au prochain lancement. Le compteur affiche la limite effective, et les délais par service restent respectés. Choisir 1 ou 2 peut aider si les limitations sont fréquentes, sans garantie. La connexion par cookies n’est pas implémentée dans cette version.

## Connexion Reddit locale

Réglages → Se connecter à Reddit. Saisir ses identifiants directement sur le site Reddit dans la fenêtre intégrée, puis Terminé. WebKit conserve la session dans son stockage local à l’app. Aucun mot de passe n’est lu par le code Swift, aucun cookie n’est envoyé à GitHub et aucun formulaire natif ne collecte les identifiants. La connexion par fournisseurs externes n’est pas intégrée ; utiliser l’identifiant Reddit.

Les requêtes HTTPS reddit.com peuvent recevoir les cookies correspondants à leur domaine, chemin et expiration. Les cookies ne sont jamais appliqués à redd.it, RedGIFs ou Imgur. Chaque redirection reconstruit les cookies pour sa destination et retire l’autorisation lors d’un changement d’hôte. Les navigations principales de la fenêtre de connexion sont limitées à HTTPS reddit.com et ses sous-domaines.

Déconnexion supprime les cookies et autres données WebKit de l’app. Le changement de session invalide le cache RSS. Connexion et déconnexion sont désactivées pendant les téléchargements pour éviter un changement de compte en cours de transfert. Aucun délai de limitation n’est effacé. La présence de reddit_session affiche « Session détectée », sans prétendre avoir vérifié le compte côté serveur. En cas de session expirée, rouvrir Reddit depuis les réglages.

Cette fonction reste à valider dans LiveContainer avec une connexion réelle sur l’iPhone. Elle ne garantit ni l’acceptation du RSS authentifié, ni la suppression des blocages et quotas. L’app continue de lire le RSS sans API JSON Reddit. La session sert aussi à lire l’onglet Sauvegardés (`♥`) du compte.

## Transferts immédiats et état de session

Les pauses artificielles de départ ont été supprimées, ainsi que le lissage du débit inféré des quotas encore disponibles. Aucun Task.sleep n’est utilisé par la couche réseau. Les tâches démarrent dès qu’un emplacement est libre. Les réponses HTTP 429 et quotas explicitement épuisés continuent de bloquer le service concerné jusqu’au délai requis.

Le compteur affiche les appels de téléchargement réseau en cours, et non la totalité des tâches de résolution/assemblage. Le nombre choisi est un maximum de médias traités simultanément ; il peut être inférieur pendant la découverte RSS, les résolutions, l’assemblage ou à la fin d’une page.

Un bandeau vert « Session Reddit détectée » est visible dans la galerie, les réglages et la connexion. Il reflète la présence du cookie attendu, sans prétendre confirmer la validité du compte côté serveur.

## Interface et indicateurs

La galerie affiche des compteurs de largeur égale et centrés : fichiers locaux tous profils confondus, somme des tailles des fichiers terminés, puis nouveaux fichiers reçus / repérés pendant le parcours en cours. Le dénominateur progresse à chaque page ; les fichiers déjà présents sont exclus de ce dénominateur. Il ne constitue pas un maximum exhaustif de l’historique Reddit. Les téléchargements échoués ou limités restent dans le total repéré.

La connexion est présentée en plein écran. Une seule barre supérieure affiche reddit.com et une croix. La vue Web est contrainte au guide UIKit du clavier, et le déplacement automatique de l’ensemble par SwiftUI est désactivé pour cet écran.

Quick Look est remplacé par une visionneuse plein écran : fond noir, titre tronqué au milieu et centré entre commandes de même largeur, index centré, croix et partage. Les vidéos utilisent AVPlayer et s’arrêtent quand on quitte leur page. Les images disposent d’un zoom par pincement/double toucher. Seuls les médias voisins sont préparés ; les images d’affichage sont limitées à 4096 pixels, sans modifier les originaux téléchargés ou partagés. Les GIF sont affichés dans une vue Web locale non persistante sans JavaScript.

À vérifier sur iPhone : connexion avec clavier visible, balayage des images et vidéos, fermeture du lecteur, zoom et partage. La compilation CI ne remplace pas ces essais d’interface.

## Galerie compacte et zones tactiles

Les compteurs sont regroupés sur une ligne de texte sans panneau de fond. La ligne de transfert, son spinner et son espace réservé sont supprimés. Les erreurs fatales apparaissent dans une alerte ponctuelle ; les limites de service gardent leur message conditionnel.

Chaque bouton de galerie définit une zone tactile rectangulaire et les overlays décoratifs ne participent pas au hit-testing. Le découpage visuel seul de scaledToFill ne suffisait pas à borner la zone tactile. Vérifier sur iPhone les touchers près du bord supérieur d’une vidéo et du bord inférieur de la carte qui la précède.
