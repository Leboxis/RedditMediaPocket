/// <reference types="@cloudflare/workers-types" />

// Tout le code et les commentaires sont en français.
// Backend de RedditMediaPocket : Worker Cloudflare + base D1 (SQLite dans le cloud).
// Deux usages : synchroniser l'écran Suivis et restaurer les sessions WebKit
// (cookies des sites) après une réinstallation de l'application.

export interface Env {
  DB: D1Database;
  API_KEY: string;
}

/** Sites dont les cookies de session peuvent être synchronisés. */
const SITES_SESSION = new Set(["reddit", "x", "tiktok", "instagram"]);
const MAX_COOKIES_PAR_SITE = 400;
const MAX_LONGUEUR_CORPS = 1_000_000;
const MAX_LONGUEUR_CHAMP = 8_192;

/** En-têtes CORS : l'app iOS est un client navigateur-like, le prévol doit passer sans clé. */
const ENTETES_CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-API-Key",
  "Access-Control-Max-Age": "86400",
};

/** Ligne brute telle que renvoyée par D1. */
interface LigneItem {
  id: number;
  type: string | null;
  name: string;
  description: string | null;
  data: string | null;
  created_at: string;
  updated_at: string | null;
}

/** Ligne de la table `cookies`, une par site. */
interface LigneCookie {
  site: string;
  data: string;
  created_at: string;
  updated_at: string | null;
}

/** Réponse JSON avec les en-têtes CORS. */
function json(corps: unknown, statut = 200): Response {
  return new Response(JSON.stringify(corps), {
    status: statut,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...ENTETES_CORS,
    },
  });
}

/** Erreur normalisée : {"erreur": "..."}. */
function erreur(statut: number, message: string): Response {
  return json({ erreur: message }, statut);
}

/** Méthode non autorisée sur une route connue. */
function nonAutorise(): Response {
  return erreur(405, "Méthode non autorisée");
}

/**
 * Vérifie la clé API sur toutes les routes /api/items.
 * La clé n'est jamais journalisée, même en cas d'échec.
 * Renvoie null quand tout est correct, sinon la réponse d'erreur à renvoyer.
 */
function verifierCle(requete: Request, env: Env): Response | null {
  if (!env.API_KEY) {
    return erreur(
      500,
      "Clé API serveur absente : exécutez « npx wrangler secret put API_KEY » puis redéployez."
    );
  }
  if (requete.headers.get("X-API-Key") !== env.API_KEY) {
    return erreur(401, "Non autorisé");
  }
  return null;
}

/** Lit un corps JSON d'objet. Un corps vide est accepté comme un objet vide. */
async function lireCorps(
  requete: Request,
  limiteOctets = MAX_LONGUEUR_CORPS
): Promise<Record<string, unknown> | Response> {
  try {
    const texte = await requete.text();
    if (texte.length > limiteOctets) {
      return erreur(413, "Corps trop volumineux");
    }
    if (!texte.trim()) return {};
    const valeur: unknown = JSON.parse(texte);
    if (typeof valeur !== "object" || valeur === null || Array.isArray(valeur)) {
      return erreur(400, "Corps JSON invalide : un objet est attendu");
    }
    return valeur as Record<string, unknown>;
  } catch {
    return erreur(400, "Corps JSON invalide");
  }
}

/** `data` est stocké en TEXT : on le redésérialise en objet JSON pour le client. */
function donneesObjet(brut: string | null): unknown {
  if (!brut) return null;
  try {
    return JSON.parse(brut) as unknown;
  } catch {
    return null;
  }
}

/** Convertit une ligne D1 en élément renvoyé au client (clés en snake_case). */
function versItem(ligne: LigneItem) {
  return {
    id: ligne.id,
    name: ligne.name,
    description: ligne.description,
    type: ligne.type,
    data: donneesObjet(ligne.data),
    created_at: ligne.created_at,
    updated_at: ligne.updated_at,
  };
}

/** Valide un identifiant numérique positif. */
function identifiant(brut: string): number | null {
  const valeur = Number.parseInt(brut, 10);
  return Number.isInteger(valeur) && valeur > 0 ? valeur : null;
}

/** Liste paginée, avec filtres optionnels « search » et « type ». */
async function lister(requete: Request, env: Env): Promise<Response> {
  const url = new URL(requete.url);
  const pageBrute = Number.parseInt(url.searchParams.get("page") ?? "1", 10);
  const page = Number.isFinite(pageBrute) && pageBrute >= 1 ? pageBrute : 1;
  const limiteBrute = Number.parseInt(url.searchParams.get("limit") ?? "20", 10);
  const limit = Number.isFinite(limiteBrute)
    ? Math.min(100, Math.max(1, limiteBrute))
    : 20;
  const recherche = (url.searchParams.get("search") ?? "").trim();
  const type = (url.searchParams.get("type") ?? "").trim();

  const conditions: string[] = [];
  const valeurs: (string | number)[] = [];
  if (type) {
    conditions.push("type = ?");
    valeurs.push(type);
  }
  if (recherche) {
    conditions.push("(name LIKE ? OR description LIKE ?)");
    const motif = `%${recherche}%`;
    valeurs.push(motif, motif);
  }
  const ou = conditions.length ? ` WHERE ${conditions.join(" AND ")}` : "";

  // Requêtes préparées uniquement : aucune donnée utilisateur n'est concaténée dans le SQL.
  const denombrement = await env.DB.prepare(
    `SELECT COUNT(*) AS total FROM items${ou}`
  )
    .bind(...valeurs)
    .first<{ total: number }>();
  const total = denombrement?.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / limit));

  const resultat = await env.DB.prepare(
    `SELECT * FROM items${ou} ORDER BY id DESC LIMIT ? OFFSET ?`
  )
    .bind(...valeurs, limit, (page - 1) * limit)
    .all<LigneItem>();

  return json({
    page,
    limit,
    total,
    pages,
    items: resultat.results.map(versItem),
  });
}

/** Lecture d'un élément par identifiant. */
async function lireUn(id: number, env: Env): Promise<Response> {
  const ligne = await env.DB.prepare("SELECT * FROM items WHERE id = ?")
    .bind(id)
    .first<LigneItem>();
  if (!ligne) return erreur(404, "Élément introuvable");
  return json(versItem(ligne));
}

/** Création d'un élément. */
async function creer(requete: Request, env: Env): Promise<Response> {
  const corps = await lireCorps(requete);
  if (corps instanceof Response) return corps;

  const nom = typeof corps.name === "string" ? corps.name.trim() : "";
  if (!nom) return erreur(400, "Le champ « name » est obligatoire et non vide");

  const type = typeof corps.type === "string" && corps.type.trim()
    ? corps.type.trim()
    : null;
  const description = typeof corps.description === "string"
    ? corps.description
    : null;
  const data = corps.data === undefined || corps.data === null
    ? null
    : JSON.stringify(corps.data);

  const ligne = await env.DB.prepare(
    "INSERT INTO items (type, name, description, data) VALUES (?, ?, ?, ?) RETURNING *"
  )
    .bind(type, nom, description, data)
    .first<LigneItem>();

  return json(ligne ? versItem(ligne) : { erreur: "Insertion impossible" }, ligne ? 201 : 500);
}

/** Modification partielle : un champ absent garde sa valeur actuelle. */
async function modifier(id: number, requete: Request, env: Env): Promise<Response> {
  const actuel = await env.DB.prepare("SELECT * FROM items WHERE id = ?")
    .bind(id)
    .first<LigneItem>();
  if (!actuel) return erreur(404, "Élément introuvable");

  const corps = await lireCorps(requete);
  if (corps instanceof Response) return corps;

  if ("name" in corps) {
    const nom = typeof corps.name === "string" ? corps.name.trim() : "";
    if (!nom) return erreur(400, "Le champ « name » ne peut pas être vide");
  }

  const nom = "name" in corps && typeof corps.name === "string"
    ? corps.name.trim()
    : actuel.name;
  const type = "type" in corps
    ? (typeof corps.type === "string" && corps.type.trim() ? corps.type.trim() : null)
    : actuel.type;
  const description = "description" in corps
    ? (typeof corps.description === "string" ? corps.description : null)
    : actuel.description;
  const data = "data" in corps
    ? (corps.data === undefined || corps.data === null ? null : JSON.stringify(corps.data))
    : actuel.data;

  const ligne = await env.DB.prepare(
    "UPDATE items SET name = ?, type = ?, description = ?, data = ?, updated_at = datetime('now') WHERE id = ? RETURNING *"
  )
    .bind(nom, type, description, data, id)
    .first<LigneItem>();

  if (!ligne) return erreur(404, "Élément introuvable");
  return json(versItem(ligne));
}

/** Suppression d'un élément. */
async function supprimer(id: number, env: Env): Promise<Response> {
  const resultat = await env.DB.prepare("DELETE FROM items WHERE id = ?")
    .bind(id)
    .run();
  const nombre = (resultat.meta as { changes?: number }).changes ?? 0;
  if (nombre === 0) return erreur(404, "Élément introuvable");
  return json({ message: "Élément supprimé", id });
}

/** Valide un cookie sérialisé, sans jamais journaliser sa valeur. */
function cookieValide(valeur: unknown): boolean {
  if (typeof valeur !== "object" || valeur === null || Array.isArray(valeur)) return false;
  const cookie = valeur as Record<string, unknown>;
  for (const cle of ["name", "domain"] as const) {
    const champ = cookie[cle];
    if (typeof champ !== "string" || !champ.trim() || champ.length > MAX_LONGUEUR_CHAMP) return false;
  }
  const chemin = cookie.path;
  if (typeof chemin !== "string" || chemin.length > MAX_LONGUEUR_CHAMP) return false;
  const valeurCookie = cookie.value;
  if (typeof valeurCookie !== "string" || valeurCookie.length > MAX_LONGUEUR_CHAMP) return false;
  if ("expires" in cookie && cookie.expires !== null &&
      (typeof cookie.expires !== "number" || !Number.isFinite(cookie.expires))) return false;
  for (const cle of ["secure", "httpOnly"] as const) {
    if (cle in cookie && typeof cookie[cle] !== "boolean") return false;
  }
  return true;
}

/** Valide la carte { site: [cookies] } : seuls les quatre sites connus sont acceptés. */
function validerSites(corps: Record<string, unknown>): Record<string, unknown[]> | Response {
  if (!("sites" in corps)) return erreur(400, "Le champ « sites » est obligatoire");
  const brut = corps.sites;
  if (typeof brut !== "object" || brut === null || Array.isArray(brut)) {
    return erreur(400, "« sites » doit être un objet");
  }
  const sortie: Record<string, unknown[]> = {};
  for (const [site, valeur] of Object.entries(brut as Record<string, unknown>)) {
    if (!SITES_SESSION.has(site)) return erreur(400, `Site inconnu : ${site}`);
    if (!Array.isArray(valeur)) return erreur(400, `Les cookies de « ${site} » doivent être une liste`);
    if (valeur.length > MAX_COOKIES_PAR_SITE) {
      return erreur(400, `Trop de cookies pour « ${site} » (max. ${MAX_COOKIES_PAR_SITE})`);
    }
    if (!valeur.every(cookieValide)) return erreur(400, `Cookie invalide pour « ${site} »`);
    sortie[site] = valeur;
  }
  return sortie;
}

/** Lit tous les cookies sauvegardés, par site. */
async function lireCookies(env: Env): Promise<Response> {
  const resultat = await env.DB.prepare("SELECT site, data, updated_at FROM cookies ORDER BY site")
    .all<LigneCookie>();
  const sites: Record<string, unknown> = {};
  let derniere: string | null = null;
  for (const ligne of resultat.results) {
    sites[ligne.site] = donneesObjet(ligne.data) ?? [];
    if (ligne.updated_at && (!derniere || ligne.updated_at > derniere)) derniere = ligne.updated_at;
  }
  return json({ sites, updated_at: derniere });
}

/** Remplace les cookies d'un site. Une liste vide supprime la ligne du site. */
async function ecrireCookies(requete: Request, env: Env): Promise<Response> {
  const corps = await lireCorps(requete);
  if (corps instanceof Response) return corps;
  const sites = validerSites(corps);
  if (sites instanceof Response) return sites;

  const ecrits: string[] = [];
  for (const [site, cookies] of Object.entries(sites)) {
    if (cookies.length === 0) {
      await env.DB.prepare("DELETE FROM cookies WHERE site = ?").bind(site).run();
      continue;
    }
    await env.DB.prepare(
      "INSERT INTO cookies (site, data, updated_at) VALUES (?, ?, datetime('now')) " +
      "ON CONFLICT(site) DO UPDATE SET data = excluded.data, updated_at = datetime('now')"
    ).bind(site, JSON.stringify(cookies)).run();
    ecrits.push(site);
  }
  if (Object.keys(sites).length === 0) {
    await env.DB.prepare("DELETE FROM cookies").run();
  }
  const ligne = await env.DB.prepare("SELECT MAX(updated_at) AS updated_at FROM cookies")
    .first<{ updated_at: string | null }>();
  return json({ sites: ecrits, updated_at: ligne?.updated_at ?? null });
}

/** Efface toutes les sessions sauvegardées (déconnexion de toutes les installations). */
async function supprimerCookies(env: Env): Promise<Response> {
  await env.DB.prepare("DELETE FROM cookies").run();
  return json({ message: "Sessions effacées" });
}

/** Liste publique des routes, utile pour vérifier le déploiement. */
function routeIndex(): Response {
  return json({
    service: "mon-api",
    routes: [
      "GET  /                  — liste des routes (public)",
      "GET  /api              — liste des routes (public)",
      "GET  /api/health       — état du service (public)",
      "GET  /api/items        — liste paginée (clé requise)",
      "GET  /api/items/:id    — un élément (clé requise)",
      "POST /api/items        — créer un élément (clé requise)",
      "PUT  /api/items/:id    — modifier un élément (clé requise)",
      "DELETE /api/items/:id  — supprimer un élément (clé requise)",
      "GET  /api/cookies      — cookies de session par site (clé requise)",
      "PUT  /api/cookies      — enregistrer les cookies (clé requise)",
      "DELETE /api/cookies    — effacer toutes les sessions (clé requise)",
    ],
  });
}

export default {
  async fetch(requete: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(requete.url);
      const chemin = url.pathname.replace(/\/+$/, "") || "/";

      // Prévol CORS : aucune vérification de clé.
      if (requete.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: ENTETES_CORS });
      }

      // Routes publiques.
      if (chemin === "/" || chemin === "/api") {
        if (requete.method !== "GET") return nonAutorise();
        return routeIndex();
      }
      if (chemin === "/api/health") {
        if (requete.method !== "GET") return nonAutorise();
        return json({ status: "ok" });
      }

      // Toutes les routes /api/items exigent la clé, y compris les méthodes inattendues.
      if (chemin === "/api/items" || chemin.startsWith("/api/items/")) {
        const refus = verifierCle(requete, env);
        if (refus) return refus;

        if (chemin === "/api/items") {
          if (requete.method === "GET") return await lister(requete, env);
          if (requete.method === "POST") return await creer(requete, env);
          return nonAutorise();
        }

        const correspondance = chemin.match(/^\/api\/items\/([^/]+)$/);
        if (!correspondance) return erreur(404, "Route inconnue");
        const id = identifiant(correspondance[1]);
        if (id === null) return erreur(400, "Identifiant invalide");

        if (requete.method === "GET") return await lireUn(id, env);
        if (requete.method === "PUT") return await modifier(id, requete, env);
        if (requete.method === "DELETE") return await supprimer(id, env);
        return nonAutorise();
      }

      // Cookies de session : mêmes clé et en-têtes que /api/items, table dédiée.
      if (chemin === "/api/cookies" || chemin.startsWith("/api/cookies/")) {
        const refus = verifierCle(requete, env);
        if (refus) return refus;
        if (chemin !== "/api/cookies") return erreur(404, "Route inconnue");
        if (requete.method === "GET") return await lireCookies(env);
        if (requete.method === "PUT") return await ecrireCookies(requete, env);
        if (requete.method === "DELETE") return await supprimerCookies(env);
        return nonAutorise();
      }

      return erreur(404, "Route inconnue");
    } catch (cause) {
      // Aucun secret n'est journalisé : seulement le type de l'erreur.
      console.error("Erreur interne du Worker :", cause instanceof Error ? cause.message : "inconnue");
      return erreur(500, "Erreur interne du serveur");
    }
  },
};
