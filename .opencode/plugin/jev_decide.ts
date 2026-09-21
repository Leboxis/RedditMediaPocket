import { tool } from "@opencode-ai/plugin";

// Modèle Jev via OpenRouter Decisions API (PAS du chat classique).
// Réf : https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request
const JEV_MODEL = "typesafe/jev-1.13";
const PRIMARY_ENDPOINT = "https://openrouter.ai/api/alpha/decisions";
// Endpoint de compatibilité TypeSafe SDK, même shape requête/réponse.
const FALLBACK_ENDPOINT = "https://openrouter.ai/api/v1/systemone";

const DEFAULT_TIMEOUT_MS = 30_000;
const MIN_TIMEOUT_MS = 5_000;
const MAX_TIMEOUT_MS = 120_000;
// Garde-fou local : Jev 1.13 a 32k de contexte. Au-delà, on refuse
// avant de payer un aller-retour qui finirait en 413.
const MAX_STATE_CHARS = 24_000;
const MAX_QUESTION_CHARS = 4_000;
const MAX_CHOICES = 255;
const MIN_CHOICES = 2;
// En-dessous de ce seuil, Jev dit "je ne sais pas" (distribution plate).
const LOW_CONFIDENCE_THRESHOLD = 0.2;

type ChoiceAnswer = {
  type: "choice";
  choice: string;
  confidence?: number;
  probabilities?: Record<string, number>;
};

function fail(code: string, message: string): never {
  throw new Error(`jev_decide[${code}]: ${message}`);
}

function asRecord(value: unknown): Record<string, string> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail("invalid_choices", "`choices` doit être un objet { option: description }.");
  }
  return value as Record<string, string>;
}

async function postDecisions(
  endpoint: string,
  apiKey: string,
  body: unknown,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "X-Title": "opencode-jev-decide",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") {
      fail("timeout", `Jev n'a pas répondu en ${timeoutMs} ms (timeout).`);
    }
    fail("network", `Erreur réseau vers OpenRouter : ${(err as Error).message}`);
  } finally {
    clearTimeout(timer);
  }
}

async function readErrorMessage(res: Response): Promise<string> {
  try {
    const data = (await res.json()) as {
      error?: { code?: number; message?: string };
    };
    if (data?.error?.message) return `HTTP ${res.status} : ${data.error.message}`;
  } catch {
    // Corps illisible : on retombe sur le statut brut.
  }
  return `HTTP ${res.status} : ${res.statusText || "erreur inconnue"}`;
}

export default tool({
  description:
    "Moteur de décision structuré (Jev 1.13 via OpenRouter Decisions API). " +
    "À utiliser quand il faut ARBITRER entre plusieurs stratégies/options crédibles : " +
    "choisir une approche d'implémentation, comparer des options, décider de la prochaine action. " +
    "N'ÉCRIT PAS de code et ne rédige pas la réponse finale : il renvoie decision + confidence + " +
    "probabilities, à toi de vérifier la compatibilité avec le projet puis d'exécuter. " +
    "Inutile pour les tâches triviales ou quand une seule option est raisonnable.",

  args: {
    question: tool.schema
      .string()
      .min(1)
      .max(MAX_QUESTION_CHARS)
      .describe(
        "Question d'arbitrage posée à Jev (instructions, ex : 'Quelle stratégie choisir pour implémenter X ?').",
      ),
    state: tool.schema
      .string()
      .min(1)
      .max(MAX_STATE_CHARS)
      .describe(
        "État/contexte factuel à évaluer (code concerné, contraintes, exigences). Plus il est précis, meilleure est la décision.",
      ),
    choices: tool.schema
      .record(tool.schema.string(), tool.schema.string())
      .describe(
        "Options en concurrence : objet { 'A': 'description de A', 'B': 'description de B', ... }. " +
          "2 options minimum. Chaque description doit permettre de distinguer l'option des autres.",
      ),
    timeoutMs: tool.schema
      .number()
      .int()
      .min(MIN_TIMEOUT_MS)
      .max(MAX_TIMEOUT_MS)
      .optional()
      .describe(`Timeout en ms (défaut ${DEFAULT_TIMEOUT_MS}).`),
  },

  async execute(args) {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) {
      fail(
        "missing_api_key",
        "OPENROUTER_API_KEY est absente de l'environnement. " +
          "Définis-la avant d'appeler jev_decide (ex : $env:OPENROUTER_API_KEY='...' sous Windows).",
      );
    }

    const choices = asRecord(args.choices);
    const entries = Object.entries(choices).filter(
      ([k, v]) => k.trim().length > 0 && typeof v === "string" && v.trim().length > 0,
    );
    if (entries.length < MIN_CHOICES) {
      fail(
        "invalid_choices",
        `Il faut au moins ${MIN_CHOICES} options non vides, ${entries.length} reçue(s). ` +
          "Jev arbitre entre des options, il ne valide pas une option unique.",
      );
    }
    if (entries.length > MAX_CHOICES) {
      fail("invalid_choices", `Trop d'options : ${entries.length} (max ${MAX_CHOICES}).`);
    }
    const criteria: Record<string, string> = Object.fromEntries(entries);

    const timeoutMs = args.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const body = {
      model: JEV_MODEL,
      state: args.state,
      questions: {
        decision: {
          type: "choice",
          instructions: args.question,
          criteria,
        },
      },
    };

    let res = await postDecisions(PRIMARY_ENDPOINT, apiKey, body, timeoutMs);
    // Le endpoint canonique est /api/alpha/decisions (hors /v1).
    // Si OpenRouter le déplace un jour, on tente l'équivalent SystemOne.
    if (res.status === 404) {
      res = await postDecisions(FALLBACK_ENDPOINT, apiKey, body, timeoutMs);
    }
    if (!res.ok) {
      const detail = await readErrorMessage(res);
      if (res.status === 401) fail("auth", `Clé OpenRouter rejetée. ${detail}`);
      if (res.status === 402)
        fail("credits", `Crédits OpenRouter insuffisants. ${detail} (voir https://openrouter.ai/credits)`);
      if (res.status === 429)
        fail("rate_limit", `Rate limit OpenRouter. Réessaie plus tard. ${detail}`);
      if (res.status >= 500 || res.status === 408)
        fail("provider", `Jev/OpenRouter temporairement indisponible. ${detail}`);
      fail("bad_request", `Requête rejetée par Jev. ${detail}`);
    }

    let data: unknown;
    try {
      data = await res.json();
    } catch {
      fail("invalid_json", "Réponse de Jev illisible (JSON invalide).");
    }

    const answer = (data as { answers?: Record<string, ChoiceAnswer> })?.answers?.decision;
    if (!answer || answer.type !== "choice" || typeof answer.choice !== "string") {
      fail("invalid_answer", "Réponse de Jev inattendue : champ `answers.decision` de type `choice` absent.");
    }
    if (!(answer.choice in criteria)) {
      fail(
        "unknown_choice",
        `Jev a renvoyé une option inconnue : "${answer.choice}". Options valides : ${Object.keys(criteria).join(", ")}.`,
      );
    }

    const probabilities: Record<string, number> = {};
    for (const key of Object.keys(criteria)) {
      const p = answer.probabilities?.[key];
      probabilities[key] = typeof p === "number" && Number.isFinite(p) ? p : key === answer.choice ? 1 : 0;
    }
    const confidence =
      typeof answer.confidence === "number" && Number.isFinite(answer.confidence)
        ? answer.confidence
        : probabilities[answer.choice];
    const ranked = Object.entries(probabilities).sort((a, b) => b[1] - a[1]);
    const actionable = confidence >= LOW_CONFIDENCE_THRESHOLD;

    return JSON.stringify(
      {
        ok: true,
        decision: answer.choice,
        confidence,
        probabilities,
        ranked: ranked.map(([option, score]) => ({ option, score })),
        actionable,
        warning: actionable
          ? null
          : `Confiance faible (${confidence}) : Jev ne sait pas trancher — ne pas agir aveuglément, ` +
            "affine l'état/les options ou tranche toi-même.",
        reminder:
          "Jev a arbitré, il n'a rien exécuté. Vérifie que la décision est compatible avec le contexte réel du projet avant d'agir.",
        model: (data as { model?: string })?.model ?? JEV_MODEL,
        usage: (data as { usage?: unknown })?.usage ?? null,
      },
      null,
      2,
    );
  },
});
