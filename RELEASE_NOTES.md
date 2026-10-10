Moins de requêtes sur les comptes X déjà archivés, et un avertissement clair quand l'archive est incomplète.

- Relancer un compte X déjà téléchargé ne relit plus tout le fil : le parcours s'arrête dès qu'il a rattrapé l'historique, au lieu de redemander les 100 pages à chaque lancement. Un média en échec reste retenté, et un fil jamais terminé continue de s'arrêter à la limite de pages pour reprendre au même endroit.
- Un bandeau d'information apparaît quand le parcours n'a pas atteint la fin du contenu, pour toutes les sources (profils, subreddits, sauvegardés, RedGifs, X et X-Fetish). Ce n'est pas une erreur : rien n'est perdu, un nouveau lancement continue exactement où le parcours s'était arrêté. Le bandeau disparaît au lancement suivant.
- X-Fetish ne signale plus sa limite de pages comme une panne. Atteindre cette limite signifie simplement « il reste des pages », ce qui est désormais indiqué sans alerte rouge.

Connexion X plus stable, galerie et reprise cohérentes.

- L'indicateur de session X ne retombe plus tout seul en « accès à vérifier » : X renouvelle son jeton CSRF en cours de session, et ce renouvellement était lu comme une nouvelle connexion.
- L'interface ne se redessine plus à chaque écriture de cookie par X. Les indicateurs de session ne sont rafraîchis que lorsqu'ils changent réellement, au lieu de redessiner l'écran entier à chaque requête.
- Un média `.m4v` téléchargé apparaît maintenant dans la galerie et dans les compteurs, alors que le tagging et la déduplication le reconnaissaient déjà.
- Un parcours X demandé avec une limite de pages nulle signale une erreur au lieu d'interrompre l'application.
- La clé d'un média X (qui décide si le fichier est déjà sur disque) est écrite au même endroit que celle qui la relit : les deux ne peuvent plus diverger et faire retélécharger le média à chaque lancement.

Reprise après une limitation de requêtes.

- Reddit publie parfois plusieurs fenêtres dans un seul en-tête de limitation. Lues comme un nombre unique, elles étaient ignorées : aucune pause n'était enregistrée et chaque relance repartait sur un refus immédiat.
- L'application n'inventorie plus tout le dossier après chaque fichier téléchargé, ce qui rendait la progression très lente sur une collection importante.

Fiabilité du moteur de téléchargement.

- La règle de relance sur erreur temporaire (réseau instable) a une source unique et testée, au lieu d'une copie dans le moteur de téléchargement qui pouvait diverger.
- Une limite de transferts simultanés invalide lève une erreur au lieu d'arrêter l'application.

Fiabilité des téléchargements et de la reprise.

- L’ajout des métadonnées conserve le fichier original si le remplacement échoue.
- Une erreur temporaire lors de la résolution d’une galerie Reddit interrompt la page sans la marquer comme traitée ; une relance peut la reprendre. L’historique Reddit est revérifié une fois pour récupérer les galeries auparavant ignorées, sans retélécharger les fichiers déjà présents.
- Le compteur des sauvegardés compte les médias réellement présents, y compris ceux des exécutions précédentes.
- Les profils X dépassant 100 pages reprennent après la dernière page terminée. Après la fin du parcours, le lancement suivant recherche les nouveautés depuis le début.

Correction de la connexion à X (Twitter).

- Détection de la connexion dès que X pose le cookie d'authentification, sans attendre le cookie CSRF.
- Les appels à l'API X continuent d'exiger les deux cookies, pour éviter d'envoyer une requête incomplète.
- Session X conservée dans un profil WebKit persistant séparé de Reddit, y compris après une fermeture complète de l'application ; la déconnexion efface les données de ce profil.
- Connexion directe au formulaire X dès l’ouverture ; suppression du mode accueil et de son bouton de bascule.
- Suppression du feed web X et retour de la fenêtre des sauvegardés à son fonctionnement Reddit précédent.
- Le téléchargement des médias des profils X (`tw`) reste disponible avec la session X.

Choix des médias X-Fetish : images, vidéos ou les deux.

- Un sélecteur segmenté apparaît sous le champ de saisie en mode `x/`. Il est mémorisé et vaut « Images » par défaut, sans changer le comportement des installations existantes.
- « Vidéos » parcourt les pages `/models/<nom>/videos/` puis chaque page `/video/<id>/`, dont le lecteur publie la route signée `get_file`. Les clés `xf-<album>-<image>` et `xfv-<vidéo>` partagent le même dossier `x.nom` : un média déjà présent n'est jamais retéléchargé, quel que soit le sélecteur.
- Les pages `/video/` et les médias `get_file` passent par l'IPv4 forcé, comme `get_image` : le stockage `storage*.x-fetish.tube` est IPv4-only et le jeton `v-acctoken` est lié à l'adresse IP.
- Correction associée : les identifiants d'album et de vidéo sont construits à partir du titre du média et dépassaient souvent la limite de 80 caractères ; ces médias étaient silencieusement ignorés. La limite ne s'applique qu'au nom du profil saisi.

Résilience RedGIFs et message de fin plus précis.

- La fiche RedGIFs est demandée avec les mêmes en-têtes que le lecteur web (Référent/Origine, `views=yes`), comme les implémentations de référence.
- Si le fichier HD RedGIFs est inaccessible (404/410 du CDN), la variante SD exposée est essayée avant de compter le média « inaccessible ».
- Le message final cite le nombre exact de médias ignorés et rappelle qu'ils sont le plus souvent supprimés par leur hébergeur ; un HTTP 410 du service RedGIFs signifie un contenu retiré de leur côté.

Erreurs plus lisibles et reprise fiable après une limitation.

- Les erreurs s’affichent dans une fenêtre native, sans message dupliqué au-dessus de la galerie. Les aperçus, la connexion Reddit et kDrive utilisent aussi des alertes.
- Une erreur de téléchargement indique sa cause et le nombre total de médias conservés dans la collection, y compris les téléchargements précédents.
- Un HTTP 429 reçu pendant un transfert interrompt le lot sans marquer la page comme terminée. Les fichiers déjà enregistrés sont conservés et ignorés à la reprise.
- La recherche des nouveautés ne remplace plus le curseur de l’historique. Une page déjà connue ne termine plus prématurément une reprise.
- Relancer efface les limites et le cache RSS locaux, puis retente réellement le serveur. Les réponses d’une ancienne session ne peuvent plus rétablir une limite. Reddit peut toujours refuser la nouvelle requête.
- L’ancien historique de chaque collection est reconstruit une fois pour retrouver les posts auparavant marqués comme traités à tort, sans effacer les médias présents.

Sélection automatique du compte pour les sauvegardés.

- Le cœur utilise la session Reddit connectée sans demander de pseudo.
- Le compte est identifié depuis le flux privé à chaque lancement du téléchargement.
- Une ancienne saisie de profil ou de subreddit ne remplace plus la sélection du cœur.

Correction des redirections HTTP 301 des sauvegardés.

- Suit les redirections HTTPS du flux sauvegardé entre `old.reddit.com`, `www.reddit.com` et `reddit.com`, y compris les variantes de chemin du même compte.
- Conserve le jeton privé et le curseur de pagination lorsque la redirection omet les paramètres.
- Refuse toujours les destinations externes, les autres comptes et les pages hors flux ; distingue une redirection bloquée d’un refus d’authentification.

Correction de l’authentification des sauvegardés.

- Récupération du lien RSS privé du compte connecté au lieu d’un simple `saved.rss` avec cookies.
- Vérification du pseudo, conservation du jeton sur chaque page et pagination après les commentaires sauvegardés.
- Bouton « Flux privés » dans la connexion Reddit pour activer cette option si nécessaire.
- Messages explicites pour les refus HTTP et les flux privés indisponibles ; aucun jeton conservé sur disque ou affiché dans les erreurs.

Téléchargement des éléments sauvegardés du compte.

- Troisième position du sélecteur (`♥`) : sauvegardés du compte connecté.
- Exige une session Reddit active, sinon le lancement est bloqué avec un message.
- Session expirée en cours de parcours : erreur explicite conseillant la reconnexion.
- Dossiers `saved.…`, chips ♥, même plafond de 100 pages.

Les médias inaccessibles n'arrêtent plus le parcours.

- Un post supprimé (HTTP 404 et similaires) est ignoré et compté « inaccessible » ; le téléchargement continue avec les autres médias.
- Seules les erreurs du flux RSS et l'annulation interrompent la session.
- Indispensable sur les subreddits volumineux, où un contenu supprimé est quasi garanti.

Téléchargement depuis les subreddits.

- Saisie `u/pseudo` ou `r/sub` ; les archives existantes restent des profils.
- Tri Nouveaux / Chauds / Top du mois pour les subreddits (Top : `t=month`).
- Même plafond de 100 pages RSS que les profils : ~2500 posts théoriques, souvent quelques centaines en pratique, sans exhaustivité garantie.
- Dossiers `r.…` pour les subreddits, sans collision avec les profils.

Galerie plus compacte et correction des zones tactiles.

- Suppression de la ligne de transferts, de son spinner et de son espace réservé.
- Médias, poids total et progression regroupés sur une seule ligne compacte.
- Zones tactiles bornées au rectangle de chaque carte ; les miniatures et badges ne capturent plus les touchers des cartes voisines.
- Les erreurs de téléchargement restent accessibles dans une alerte ponctuelle.
