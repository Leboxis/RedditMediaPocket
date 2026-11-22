-- Schéma de la base D1 « ma-base ».
-- Deux catégories sont stockées :
--   items   -> `suivi` : liste des comptes suivis (Reddit, X et TikTok) et leur statut (nom = "suivis") :
--              pseudos suivis, coche « déjà téléchargé », date du dernier téléchargement
--              complet et date du dernier upload.
--              Le format exact du champ `data` est décrit côté iOS dans App/Models/PocketSnapshot.swift.
--   cookies -> une ligne par site (reddit, x, tiktok, instagram) contenant ses cookies de
--              session WebKit, afin de retrouver les connexions après une réinstallation.
--              Une seule clé API protège le tout : usage personnel, une seule installation.

CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT,
  name TEXT NOT NULL,
  description TEXT,
  data TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
CREATE INDEX IF NOT EXISTS idx_items_name ON items(name);

-- `site` vaut reddit, x, tiktok ou instagram (validé par le Worker).
-- `data` est un tableau JSON de cookies sérialisés côté iOS (CookieRecord).
CREATE TABLE IF NOT EXISTS cookies (
  site TEXT PRIMARY KEY,
  data TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT
);
