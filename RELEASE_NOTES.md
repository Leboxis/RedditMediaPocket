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
