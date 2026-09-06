Téléchargement des éléments sauvegardés du compte.

- Troisième position du sélecteur (`♥`) : saisir le pseudo du compte connecté.
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
