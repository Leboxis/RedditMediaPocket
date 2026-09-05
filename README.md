# Reddit Media Pocket — prototype iPhone

Application SwiftUI en français, destinée à LiveContainer (iOS 16+). On saisit un pseudo Reddit et l'application enregistre les médias directs accessibles depuis son flux RSS public, sans compte ni API JSON Reddit.

## État réel

Le code et le workflow sont disponibles dans ce dépôt. GitHub Actions compile et publie une IPA à chaque push sur main. Consulter le résultat du dernier workflow avant de télécharger une release. Les essais dans LiveContainer sur iPhone restent à effectuer. Un appel public au RSS de `u/reddit` a répondu HTTP 200 le 5 septembre 2026. Ce résultat ne garantit pas l'accès depuis un autre réseau ou pour un autre profil.

Ce prototype ne promet pas de télécharger tous les posts. Le flux peut tronquer l'historique, refuser la pagination ou refuser l'accès. L'application s'arrête si une page se répète, si le curseur n'est pas reconnu ou après 100 pages. Les miniatures ne sont pas utilisées à la place des originaux.

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

RedGIFs utilise son propre service API ; aucune API Reddit n'est utilisée. Les structures distantes peuvent changer. Les manifests DASH segmentés sans fichier complet par représentation ne sont pas pris en charge. Les échecs de résolution arrêtent la session et restent visibles ; aucune vidéo muette n'est enregistrée silencieusement à la place d'une vidéo dont la piste audio a échoué.

## Comportement réseau et stockage

- Trois médias simultanés, remplacement immédiat de chaque transfert terminé. Seules les requêtes de découverte RSS sont espacées de 7 secondes. Aucun débit ne garantit l’accès.
- Pas de cookies persistants, compte, proxy, rotation d'identité ou tentative de contournement.
- Un HTTP 429 arrête la session et conserve le délai `Retry-After` entre lancements (15 minutes par défaut). Les autres erreurs arrêtent également la session.
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

Interface compacte : pseudo, bouton démarrer/arrêter, compteur et grille de trois colonnes. Les fichiers déjà présents dans Documents sont chargés au lancement, tous profils confondus. Les images sont réduites pour les miniatures et les vidéos utilisent une image extraite localement. Toucher une miniature ouvre la prévisualisation native avec zoom ou lecture et partage. Aucun téléchargement réseau de miniature.

Trois médias maximum sont traités simultanément (résolution, transfert et assemblage compris). Un emplacement se remplit dès sa libération. Les étapes audio et vidéo d’un même média restent séquentielles. Un jeton RedGIFs partagé évite les authentifications anonymes concurrentes. L’arrêt ou une erreur annule les autres transferts. Les fichiers complets restent conservés.

Les tests de concurrence vérifient le plafond de trois, le remplacement avant la fin du transfert le plus lent, l’annulation après erreur et le bouton arrêter.
