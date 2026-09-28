# Intégration des albums x-fetish.tube

Date : 2026-09-28
Dépôt : Leboxis/RedditMediaPocket
Branche : feat/xfetish-profile-albums

## But

Depuis l'application iPhone, choisir x-fetish.tube dans le sélecteur de source existant, saisir le seul nom d'un profil (par exemple `itwasalwaysmysolesvip`) et télécharger les images originales accessibles de tous ses albums publics, sur toutes les pages. Les images sont consultables, exportables et supprimables comme les collections actuelles. Les vidéos, l'avatar, la bannière et les miniatures de la page de profil sont hors périmètre de cette première version.

## Interface

- Le bouton de source conserve son interaction et son animation. Son cycle devient `u/ → r/ → ♥ → x/ → u/`. La face `x/` porte un libellé d'accessibilité explicite « profil x-fetish.tube » et sa traduction anglaise.
- En mode `x/`, le champ affiche « nom du profil » / « profile name ». Un nom nu est la saisie normale ; les autres modes gardent leur comportement et leurs valeurs mémorisées.
- Le bouton Télécharger, l'arrêt, le statut, les compteurs, la galerie, le partage et les actions de collection restent les commandes déjà présentes. Le tri de subreddit et l'indication de connexion Reddit ne s'affichent que pour les sources auxquelles ils s'appliquent.
- Sélectionner une collection `x/nom` replace le sélecteur sur `x/` et le nom dans le champ. L'action « Reprendre le téléchargement » relance cette source.

## Modèle et stockage

- Introduire une identité de source explicite pour distinguer Reddit `u/`, `r/`, `saved/` et `x/`, sans faire passer les profils du nouveau site par `FeedSource` ou le RSS Reddit.
- Lire les collections enregistrées par les versions antérieures en conservant leurs identifiants et dossiers actuels. Les nouvelles collections ont l'identifiant `x/<nom>` et le dossier `x.<nom>`, distincts des dossiers Reddit. La suppression et la découverte de dossiers reconnaissent ce préfixe.
- Valider le nom comme un seul segment d'URL, en minuscules ASCII, chiffres, tirets ou underscores ; refuser les chemins, paramètres et URLs arbitraires. Construire uniquement `https://x-fetish.tube/models/<nom>/`.

## Découverte et téléchargement

- Un composant de découverte propre à x-fetish.tube lit les pages publiques du profil, suit leur pagination, collecte les liens d'albums appartenant à ce profil, puis lit chaque album et sa pagination. Il extrait les URL d'images de contenu en meilleure qualité publiquement exposée ; il écarte les vignettes de liste, la navigation, les annonces et les autres médias.
- La découverte valide les hôtes et les chemins de page avant de suivre un lien, normalise les URL relatives, mémorise les pages et images déjà rencontrées et détecte les cycles. Elle s'arrête à la fin effective de la pagination. Une limite de sécurité ou une page mal formée produit un état « parcours incomplet » et conserve la reprise, jamais une réussite annoncée comme exhaustive.
- Les images passent par les transferts et la gestion locale déjà utilisés par `Downloader` : concurrence réglable, annulation, fichiers temporaires puis déplacement, noms stables, dédoublonnage et saut des fichiers existants. La reprise ne valide une page qu'après traitement de ses images. Un refus HTTP 429 arrête la session ; les erreurs de page ne sont pas converties en album vide. Les erreurs individuelles d'image sont comptées et visibles.
- Aucun compte x-fetish.tube, cookie Reddit, contournement de contrôle d'accès ou récupération de contenu privé n'est ajouté. Les requêtes restent HTTPS et limitées aux hôtes nécessaires observés pour les pages et les images.

## Choix technique

Approche retenue : lecture des pages publiques par `Network` et analyse HTML dans un module séparé, testable avec des pages enregistrées. Cela garde le comportement de téléchargement de l'app et évite une dépendance externe. Une extraction via `WKWebView` serait envisagée uniquement si les listes d'albums ou les images ne sont réellement disponibles qu'après exécution de JavaScript ; elle ajouterait un cycle de vie WebKit et des règles de session qui ne sont pas justifiés à ce stade. Un service tiers imposerait une disponibilité et des données transmises supplémentaires.

Le HTML exact du profil fourni n'a pas pu être lu depuis cet environnement. L'implémentation devra confirmer les sélecteurs et le mécanisme de pagination sur une réponse réelle du site, puis enregistrer des fixtures expurgées pour les tests. Si le site ne sert pas ces images aux visiteurs publics, la fonction affichera l'échec au lieu de promettre un téléchargement exhaustif.

## Vérification et critères d'acceptation

- Tests du nom et des URL, de la compatibilité des anciennes collections, du cycle de source, de la pagination profil/album, du choix de l'image de contenu, des doublons, des boucles, des pages vides et des réponses d'erreur.
- Compilation Swift et tests `MediaCore` dans le CI du dépôt ; contrôle manuel dans LiveContainer sur iPhone pour le bouton, l'affichage de la collection, l'arrêt, la reprise et un profil public réel.
- Pour le profil d'exemple, saisir `itwasalwaysmysolesvip` suffit ; l'app doit découvrir les albums publics paginés et conserver leurs images accessibles. Elle doit signaler clairement toute limite du site, erreur ou interruption, sans attribuer le résultat à tort à un parcours complet.
