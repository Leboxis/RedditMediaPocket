-- Schéma initial de la base D1 « ma-base ».
-- Une seule catégorie est stockée : `suivi`.
--   suivi -> état des comptes Reddit suivis (nom = "suivis") :
--            coche « déjà téléchargé », date du dernier téléchargement complet,
--            date du dernier upload. Aucune session, aucun jeton, aucun média.
-- Le format exact du champ `data` est décrit côté iOS dans App/Models/PocketSnapshot.swift.

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
