# Backend de RedditMediaPocket

Backend gratuit **Cloudflare Workers + D1** (SQLite dans le cloud). Il sert uniquement à synchroniser l'écran **Suivis** de l'app : la liste des comptes suivis (Reddit et X) ainsi que leur statut (coche « déjà téléchargé », date du dernier téléchargement complet et celle du dernier upload), afin de pouvoir les afficher même sans connexion. HTTPS, sans carte bancaire, sans endormissement. **Limite du plan gratuit : 100 000 requêtes par jour.**

Aucune session, aucun jeton et aucun média ne sont envoyés. La clé API est vérifiée côté serveur et stockée dans le Keychain de l'iPhone.

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

La base **locale** et la base **distante** sont deux bases séparées : initialise chacune de son côté.

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
  -d '{"name":"suivis","type":"suivi","data":{"suivis":["Alice","Bob"],"comptes":{"alice":{"marque":true,"dernierTelechargement":"2026-11-21T08:00:00Z","dernierUpload":null}},"suivisX":["Carol"],"comptesX":{"carol":{"marque":false,"dernierTelechargement":null,"dernierUpload":null}}}}'

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
```

## 3. Déployer

```bash
npm run db:init
npm run deploy
```

`wrangler deploy` affiche l'URL publique (par exemple `https://mon-api.<ton-sous-domaine>.workers.dev`). Reporte-la dans `ConfigurationAPI.baseURL` côté iOS.

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

Paramètres de la liste : `page` (≥ 1), `limit` (1–100, défaut 20), `search` (recherche sur `name` et `description`), `type` (égalité). Réponse : `{ page, limit, total, pages, items }`.

Formats d'erreur : `{"erreur":"..."}` avec 400 (id ou JSON invalide), 401 (clé absente ou fausse), 404 (route ou élément introuvable), 405 (méthode non autorisée), 500 (erreur interne ou clé serveur absente).

## Vérification du code

```bash
npm run typecheck
```

## Sécurité

- Une seule clé partagée : **elle ne sépare pas les données par utilisateur**. Ce backend est prévu pour un usage unique, comme demandé.
- La clé n'est jamais journalisée côté serveur, ni stockée en clair côté iOS (Keychain).
- Le plan gratuit est limité à 100 000 requêtes/jour.
