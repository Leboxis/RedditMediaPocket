# Refonte visuelle — design

Date : 2026-11-20
Statut : proposé (en attente d'approbation)

## Intention

L'app fait « prototype » : rayons incohérents (9, 14, 22 mélangés), gris système
partout, boutons carrés sans libellé, aucune hiérarchie entre l'action
principale et le reste. Le but est une interface qui se tienne à côté d'une app
Apple, sans perdre l'identité orange.

Référence retenue par le commanditaire : **Instagram**, appliquée à un outil de
téléchargement, pas à un réseau social. Ce qu'on emprunte : noir pur, chrome
monochrome, médias plein cadre, une seule couleur d'accent, mouvement qui
répond au doigt. Ce qu'on n'emprunte pas : barre d'onglets, codes sociaux,
dégradés de stories.

## Objectifs

- Une échelle unique de rayons, d'espacements et de typographie.
- Une action principale évidente (télécharger), le reste en retrait.
- Des animations présentes mais réglées : ressorts courts, échelonnement à
  l'ouverture, jamais de mouvement en boucle.
- Un basculement **dans l'app** entre nouvelle et ancienne interface.
- Zéro régression fonctionnelle : téléchargements, reprise, kDrive, journaux.

## Non-objectifs

- Changer la logique métier, les sources ou les endpoints.
- Ajouter des écrans ; on réhabille l'existant.
- Reproduire les codes sociaux d'Instagram.

## Anti-objectifs

- Une animation qui retarde une action (délai perçu).
- Un redesign qui casse kDrive ou le journal.
- Deux bases de code complètes à maintenir en parallèle.

## Contraintes

- iOS 26, SwiftUI, LiveContainer.
- Bilingue via `L()`, sans texte en dur.
- `accessibilityReduceMotion` respecté : tout ressort a un équivalent fondu.
- Mode sombre et clair, aucun hex en dur hors du fichier de thème.
- `swift test` doit rester vert ; CI = seule vérification de compilation.

## Approche retenue

**B — discipline Instagram, orange conservé.**

Écartées : A (liste, accent bleu) perd l'identité de l'app ; C (hybride) ne
corrige pas assez.

### L'architecture du basculement

Décision structurante : **le thème est un jeu de jetons, pas une seconde
interface.**

- Un seul fichier `Theme.swift` expose couleurs, rayons, espacements, durées.
- `@AppStorage("uiRevision")` vaut `2` (nouvelle interface, défaut) ou `1`
  (ancienne). Réglages → Apparence → « Nouvelle interface ».
- Les écrans lisent `Theme` : en mode `1`, `Theme` rend exactement les valeurs
  actuelles (rayon 14, gris système, orange). En mode `2`, le nouveau jeu.
- Seul l'**écran principal** a deux implémentations distinctes, car sa
  structure change (rangée → composeur + barre flottante). Il bifurque sur le
  même jeton.

Ainsi « revenir à l'ancien » est un changement de jetons, pas un chemin de code
parallèle à maintenir. C'est ce qui rend la promesse tenable.

## Jetons

| Jeton | Ancien (mode 1) | Nouveau (mode 2) |
|---|---|---|
| Fond | `.systemBackground` | noir pur / blanc pur |
| Surface | `.secondarySystemBackground` | `#1C1C1E` sombre, gris clair clair |
| Accent | `.orange` | `.orange` (inchangé) |
| Séparateur | `.separator` | `.separator` à 0,5 pt |
| Rayon | 9, 10, 12 et 14 selon l'élément | 10 (champ), 14 (carte), 22 (feuille/pilule) |
| Espacement | 6 / 10 / 16 | échelle 4 / 8 / 12 / 16 / 24 |

Typographie : styles système uniquement (`headline`, `body`, `caption`,
`caption2`). Aucune taille fixe hors glyphes.

Mouvement : ressort réponse 0,28 / amorti 0,86 pour une sélection ; 0,38 / 0,88
pour les feuilles ; échelonnement 20 ms par tuile ; appui à 0,97. En
`reduceMotion`, tout devient un fondu de 0,15 s.

## Ce que le mode 1 restaure exactement

Le commanditaire demande de **revenir à l'ancien affichage**. Une réversion
partielle serait un mensonge, donc la règle est stricte :

> **Tout changement visuel est piloté par `uiRevision`. En mode 1, l'app doit
> être indiscernable de celle d'aujourd'hui.**

Conséquences concrètes, souvent oubliées :

- Les **libellés longs** des tuiles reviennent (deux lignes pour TikTok
  sauvegardés), et les codes `u/`, `r/`, `RG` aussi.
- Le **logo est teinté en orange quand la tuile est active** en mode 1, comme
  aujourd'hui ; la teinte constante est une propriété du mode 2.
- Les rayons reprennent leurs valeurs réelles : 9 pour les champs, 10, 12 et 14
  ailleurs — pas un rayon unique.
- Le détent de la feuille de sources revient à 420 pt.
- La barre d'outils reste fixe, sans capsule flottante.

Le mode 1 n'est donc pas « les nouveaux jetons en gris » : c'est l'app
actuelle, à l'identique. Tout ce qui ne peut pas être reproduit est hors sujet
et ne doit pas être introduit.

## Composants

### Tuile de source (la grille ne bouge pas)

La grille 3×3, sa taille et son ordre sont conservés.

- **Logo à pleine intensité dans tous les états** (choix du commanditaire) :
  la teinte ne change pas à la sélection. Seuls le fond, le contour et une
  échelle de 1,03 marquent la tuile active.
- **Libellé simplifié** : un seul mot sous le logo (`Reddit`, `Subreddit`,
  `Sauvegardés`, `RedGifs`, `X-Fetish`, `X`, `TikTok`, `TikTok sauvegardés`,
  `Instagram`), en `caption`. Le code (`u/`, `r/`, `RG`…) disparaît : redondant
  à côté d'un logo. Le libellé long actuel (« sauvegardés TikTok — compte,
  collections ou tout le sauvegardé ») est retiré de la tuile et réservé à
  VoiceOver.
- Point de session manquante : inchangé, mais déplacé en coin de tuile.

### Composeur et action principale

- La rangée devient une carte unique : bouton source (logo), champ, et bouton
  d'action **avec libellé** (« Télécharger » / « Arrêter »), en pilule orange.
- Pendant un parcours, la pilule devient « Arrêter » avec un anneau de
  progression autour de l'icône.

### Galerie

- Grille plein cadre, gouttière de 1 pt, sans rayon par cellule (le média prime).
- Barre d'outils en capsule flottante discrète (recherche + tri + filtre).
- Les compteurs passent en une seule ligne `caption2` secondaire.

### Feuilles

Poignée visible, titre en `headline`, fermeture en bouton texte à droite,
contenu à 16 pt de marge.

## Inventaire des écrans (portée : toute l'app)

| Écran | Nature du changement |
|---|---|
| Écran principal (composeur + galerie) | refonte structurelle, double implémentation |
| Feuille de sources, sélecteur TikTok | tuiles, libellés, mouvement |
| Barre de galerie, visionneuse, fiche média | jetons + chrome |
| Réglages, filtres | jetons + sections ; accueille l'interrupteur |
| Sauvegardés, Suivis, leurs cartes | jetons + en-têtes |
| Journal, journal des échecs, diagnostic | jetons, lignes, badges |
| kDrive (envoi, bannière, sélecteur de dossier) | jetons uniquement, **aucune logique touchée** |
| Connexions Reddit / X / TikTok / Instagram | jetons + barre d'outils |

## Découpage

0. **Extraction d'état, sans aucun changement visuel.** `ContentView` porte
   l'état le plus dense de l'app : environ quinze feuilles, dialogues et
   alertes, le focus, la sélection multiple, l'export et l'action kDrive de la
   barre d'outils. Les regrouper dans un modificateur partagé, avec
   `SourceSelection`, `SourceKindButton` et `Selection` passés de `private` à
   `internal`. Cette étape ne doit rien changer à l'écran : elle rend les deux
   mises en page possibles. Compilable et vérifiable seule.
1. `Theme.swift` injecté par l'environnement + interrupteur + écran principal.
2. Feuille de sources : tuiles, libellés, mouvement.
3. Galerie et barre d'outils.
4. Écrans secondaires, fichier par fichier.
5. Passe d'accessibilité et de mode sombre.

Chaque étape est compilable et réversible seule. L'étape 0 est un préalable,
pas un luxe : sans elle, la seconde mise en page devrait dupliquer l'état.

## Décisions prises en revue

Points laissés ouverts par la première version et tranchés ici, pour qu'aucune
question ne remonte en cours d'implémentation :

- **Propagation du thème** : `uiRevision` est lu une seule fois à la racine et
  injecté par l'environnement. Aucune vue ne lit `UserDefaults` elle-même,
  sinon le basculement ne repeindrait rien avant relance.
- **Intensité des logos** : monochrome à opacité pleine, teinte constante. Pas
  de couleurs de marque — `SourceMarkView` ne remplit qu'un tracé d'une seule
  teinte, et un dégradé Instagram demanderait un artwork séparé.
- **Anneau de progression** : déterminé quand une fraction existe
  (`TransferUnit`), indéterminé sinon. Jamais de pourcentage inventé pour les
  parcours Reddit, qui n'annoncent pas de total.
- **Capsule flottante** : en surimpression basse au-dessus de la grille, avec
  inset de contenu ; elle s'efface quand la barre de sélection multiple est
  active, jamais les deux empilées.
- **Écrans de connexion** : les quatre vues WebKit fixent leur fond en UIKit ;
  elles reçoivent la couleur résolue du thème, sans toucher au contenu web.
- **Dynamic Type** : tailles fixes réservées aux glyphes et aux chiffres ; tout
  texte en style système. La pilule reste sur une ligne avec `minimumScaleFactor`.
- **Détents** : 420 pt en mode 1, `.medium` en mode 2.
- **Anglais** : « TikTok saved » reste deux mots ; la règle « un seul mot » est
  un guide, pas une contrainte de traduction.

## Risques

- **Le double écran n'est pas que du balisage.** La mise en page actuelle porte
  l'état le plus dense de l'app. « Elles partagent le modèle et aucune logique »
  exige d'abord l'extraction de l'étape 0, sur le fichier le plus délicat, et
  cette extraction n'est vérifiée que par la compilation. C'est le vrai coût du
  projet, pas les couleurs.
- **La réversibilité est infalsifiable sans appareil.** Aucun test ne couvre
  `App/` et la CI ne juge que la compilation : ni une erreur de jeton, ni un
  oubli de garde `uiRevision` ne seront détectés automatiquement. Mitigation :
  une revue systématique des points d'entrée visuels à chaque étape, et l'essai
  du basculement dans les deux sens sur l'iPhone.
- **kDrive** est le plus gros écran (1 305 + 1 273 lignes) et le plus fragile :
  on n'y touche qu'aux couleurs, jamais aux flux.
- Deux implémentations de l'écran principal : risque de divergence. Mitigation :
  elles partagent le modèle (`Downloader`) et aucune logique.
- Flou et verre coûtent cher dans LiveContainer : le verre reste limité à la
  capsule flottante, jamais sur les cartes.
- `Downloader.swift` (3 769 lignes) ne doit pas bouger : aucune refonte visuelle
  n'a de raison d'y entrer.
- La CI ne juge que la compilation : les valeurs de mouvement et les tailles
  demandent un essai sur appareil.
