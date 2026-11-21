-- Schéma initial de la base D1 « ma-base ».
-- Les éléments sont différenciés par la colonne `type` :
--   collection     -> une collection RedditMediaPocket (drapeaux de source, archived, lastRun)
--   reglage        -> un réglage de l'app (nom = clé, data = valeur)
--   log            -> une ligne du journal de bord (date ISO, niveau, message)
--   compte_suivi   -> un pseudo suivi / sauvegardé (data = pseudo)
--   snapshot       -> copie complète et non secrète de l'app, envoyée à chaque changement
-- Les champs précis de chaque catégorie sont décrits côté iOS dans App/Models/Item.swift.

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
