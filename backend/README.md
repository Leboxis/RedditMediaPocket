# Backend de RedditMediaPocket

Backend gratuit **Cloudflare Workers + D1** (SQLite dans le cloud). Il sert à synchroniser deux choses :
1. l'écran **Suivis** de l'app : la liste des comptes suivis (Reddit, X et TikTok) ainsi que leur statut (coche « déjà téléchargé », date du dernier téléchargement complet et celle du dernier upload) ;
2. les **cookies de session WebKit** de Reddit, X, TikTok et Instagram, pour qu'une installation neuve retrouve ses connexions dès que la clé API est saisie.

HTTPS, sans carte bancaire, sans endormissement. **Limite du plan gratuit : 100 000 requêtes par jour.**

Aucun média n'est envoyé. Les cookies sont stockés tels quels dans D1 : ce backend est prévu pour un usage personnel, avec une seule clé. La clé API est vérifiée côté serveur et stockée dans le Keychain de l'iPhone.

## 1. Installation et préparation

```bash
cd backend
npm install
npx wrangler login
npx wrangler d1 create ma-base
```

La dernière commande renvoie un `database_id` : **colle-le** dans `wrangler.jsonc` à la place de `"A_REMPLACER"`.

```bash
npx wrangler secret put API_KEY
```

Choisis une longue chaîne aléatoire. Elle sera demandée en secret, jamais affichée. C'est cette même valeur que tu enregistreras dans le Keychain de l'iPhone (service `mon-api`, compte `api-key`).

## 2. Tester en local

La base **locale** et la base **distante** sont deux bases séparées : initialise chacune de son côté. Le schéma contient désormais la table `cookies` ; relance `db:init` après une mise à jour pour la créer (les `CREATE TABLE IF NOT EXISTS` rendent l'opération sans risque).

```bash
npm run db:init:local
npm run dev
```

Dans un autre terminal, vérifie le déploiement local :

```bash
curl http://127.0.0.1:8787/api/health
# {"status":"ok"}
```

Puis un cycle complet (remplace `VOTRE_CLE` par la clé choisie) :

```bash
# Créer (l'app envoie un seul élément « suivis » de type « suivi »)
curl -X POST http://127.0.0.1:8787/api/items \
  -H "Content-Type: application/json" \
  -H "X-API-Key: VOTRE_CLE" \
  -d '{"name":"suivis","type":"suivi","data":{"suivis":["Alice","Bob"],"comptes":{"alice":{"marque":true,"dernierTelechargement":"2026-11-21T08:00:00Z","dernierUpload":null}},"suivisX":["Carol"],"comptesX":{"carol":{"marque":false,"dernierTelechargement":null,"dernierUpload":null}},"suivisTikTok":["dave.tt"],"comptesTikTok":{}}}'

# Lire la liste
curl http://127.0.0.1:8787/api/items \
  -H "X-API-Key: VOTRE_CLE"

# Lire un élément (id 1)
curl http://127.0.0.1:8787/api/items/1 \
  -H "X-API-Key: VOTRE_CLE"

# Modifier
curl -X PUT http://127.0.0.1:8787/api/items/1 \
  -H "Content-Type: application/json" \
  -H "X-API-Key: VOTRE_CLE" \
  -d '{"description":"modifié"}'

# Supprimer
curl -X DELETE http://127.0.0.1:8787/api/items/1 \
  -H "X-API-Key: VOTRE_CLE"

# Sessions : lire, sauvegarder puis effacer
curl http://127.0.0.1:8787/api/cookies \
  -H "X-API-Key: VOTRE_CLE"

curl -X PUT http://127.0.0.1:8787/api/cookies \
  -H "Content-Type: application/json" \
  -H "X-API-Key: VOTRE_CLE" \
  -d '{"sites":{"reddit":[{"name":"reddit_session","value":"...","domain":".reddit.com","path":"/","expires":null,"secure":true,"httpOnly":true,"version":0}],"x":[],"tiktok":[],"instagram":[]}}'

curl -X DELETE http://127.0.0.1:8787/api/cookies \
  -H "X-API-Key: VOTRE_CLE"
```

## 3. Déployer

```bash
npm run db:init
npm run deploy
```

`npm run db:init` est indispensable après l'ajout de la table `cookies` : sans elle, les appels à `/api/cookies` renverront une erreur 500. `wrangler deploy` affiche l'URL publique (par exemple `https://mon-api.<ton-sous-domaine>.workers.dev`). Reporte-la dans `ConfigurationAPI.baseURL` côté iOS.

Vérification finale :

```bash
curl https://mon-api.<ton-sous-domaine>.workers.dev/api/health
```

## Routes

| Méthode | Route | Description | Clé requise |
|---|---|---|---|
| `OPTIONS` | toutes | Prévol CORS, renvoie 204 | non |
| `GET` | `/` | Liste des routes | non |
| `GET` | `/api` | Liste des routes | non |
| `GET` | `/api/health` | État du service `{"status":"ok"}` | non |
| `GET` | `/api/items` | Liste paginée, filtres `search` et `type` | oui |
| `GET` | `/api/items/:id` | Un élément, 404 si absent | oui |
| `POST` | `/api/items` | Créer (`name` obligatoire), 201 | oui |
| `PUT` | `/api/items/:id` | Modifier partiellement, 404 si absent | oui |
| `DELETE` | `/api/items/:id` | Supprimer, 404 si absent | oui |
| `GET` | `/api/cookies` | Cookies par site (`{"sites":{...},"updated_at":...}`) | oui |
| `PUT` | `/api/cookies` | Remplacer les cookies (`{"sites":{...}}`), une liste vide efface le site | oui |
| `DELETE` | `/api/cookies` | Effacer toutes les sessions sauvegardées | oui |

Paramètres de la liste des items : `page` (≥ 1), `limit` (1–100, défaut 20), `search` (recherche sur `name` et `description`), `type` (égalité). Réponse : `{ page, limit, total, pages, items }`.

Pour `/api/cookies`, les seuls sites acceptés sont `reddit`, `x`, `tiktok` et `instagram` ; au plus 400 cookies par site et 1 Mo de corps. Chaque cookie doit au minimum porter `name`, `value`, `domain` et `path`.

Formats d'erreur : `{"erreur":"..."}` avec 400 (id, JSON ou cookie invalide), 401 (clé absente ou fausse), 404 (route ou élément introuvable), 405 (méthode non autorisée), 413 (corps trop volumineux), 500 (erreur interne ou clé serveur absente).

## Vérification du code

```bash
npm run typecheck
```

## Sécurité

- Une seule clé partagée : **elle ne sépare pas les données par utilisateur**. Ce backend est prévu pour un usage unique, comme demandé.
- La clé n'est jamais journalisée côté serveur, ni stockée en clair côté iOS (Keychain). Les cookies non plus : aucune valeur de cookie n'est écrite dans les journaux, seulement le type d'erreur en cas de problème.
- La table `cookies` conserve les cookies **en clair** dans D1 : acceptable pour une application personnelle à utilisateur unique, mais toute personne ayant accès au compte Cloudflare ou à la clé API peut les lire. Ne pas exposer cette clé.
- Sur une installation neuve, l'app envoie la clé, récupère les cookies et les réinjecte dans WebKit : les sites apparaissent connectés sans nouvelle saisie d'identifiants.
- Le plan gratuit est limité à 100 000 requêtes/jour.
