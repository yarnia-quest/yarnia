import { Hono, type Context } from "hono";
import { cors } from "hono/cors";
import { init, id } from "@instantdb/admin";
import { loadChild } from "./child";
import { generateStory } from "./generate";
import { synthesizeStory } from "./synthesize";
import { createStory, type StoryDeps } from "./story";
import { createAgentSession, getSignedUrl, type ConversationTurn } from "./agent";
import { persistSession, persistAgentSession, type SaveSessionInput } from "./session";
import { verifyWebhookSignature } from "./webhook";
import { createCheckout, getPaymentStatus, type CheckoutResult } from "./payments";
import { generateChildToken, hashToken, verifyChildToken } from "./auth";
import { createRateLimiter } from "./ratelimit";
import { createTelemetry } from "./observability";
import { estimateStoryCost } from "./usage";

// Bindings come from api/.dev.vars locally (generated from api/.env) and from
// `wrangler secret put` / GitHub Actions in production. Never hardcoded. See api/.env.example.
type Bindings = {
  QWEN_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_AGENT_ID: string;
  // Shared secret for verifying ElevenLabs post-call webhooks (HMAC-SHA256). Set via
  // `wrangler secret put ELEVENLABS_WEBHOOK_SECRET`; copied from the EL webhook config.
  ELEVENLABS_WEBHOOK_SECRET: string;
  INSTANT_APP_ID: string;
  INSTANT_ADMIN_TOKEN: string;
  // SECONDARY network gate, on top of the PRIMARY per-child auth (X-Child-Token, always
  // enforced). When set (`wrangler secret put YARNIA_API_TOKEN`), all product routes also
  // require a matching `X-Yarnia-Token` header — a coarse "is this our app" check. Optional so
  // local dev/tests need no token; the real per-request authorization is the child token.
  YARNIA_API_TOKEN?: string;
  // Set in local dev (.dev.vars) to allow http://localhost CORS; unset in production.
  ALLOW_LOCALHOST_CORS?: string;
  // Payments (Mollie). MOLLIE_API_KEY enables live checkout; MOLLIE_PAYMENT_LINK is a static
  // fallback hosted-checkout URL. APP_BASE_URL is the post-payment redirect target.
  MOLLIE_API_KEY?: string;
  MOLLIE_PAYMENT_LINK?: string;
  APP_BASE_URL?: string;
  // Optional observability sinks (structured logs are always emitted; these forward them).
  ERROR_WEBHOOK?: string;
  ANALYTICS_WEBHOOK?: string;
};

// Browser origins allowed to call the API. Non-browser clients (the Flutter mobile build)
// send no Origin header, so CORS never applies to them. Localhost is allowed ONLY when
// ALLOW_LOCALHOST_CORS is set (local dev / `.dev.vars`); production leaves it unset so no
// localhost origin is ever reflected. Everything else is rejected — no wildcard `*`.
const ALLOWED_ORIGINS = ["https://app.yarnia.quest", "https://yarnia.quest"];
function corsOrigin(origin: string, allowLocalhost: boolean): string | null {
  if (!origin) return null;
  if (ALLOWED_ORIGINS.includes(origin)) return origin;
  if (allowLocalhost && /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) return origin;
  return null;
}

// Strip prompt-injection delimiters and cap length on the user-supplied `choice` before it
// reaches the LLM prompt. A bedtime "choice" is a short phrase ("a dragon and an owl"); this
// removes braces/brackets/angle brackets, collapses whitespace, and bounds the length.
export function sanitizeChoice(raw: string): string {
  return raw
    .replace(/[{}[\]<>]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

// Same guard applied to onboarding string lists (favoriteCharacters/themes/fearsToAvoid),
// which are stored verbatim and later interpolated into the story prompt. Drops blank entries.
export function sanitizeList(xs?: string[]): string[] {
  return (xs ?? []).map(sanitizeChoice).filter((s) => s.length > 0);
}

// Everything the routes need, built from the Worker env. Injectable so tests pass fakes.
type AppDeps = StoryDeps & {
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: SaveSessionInput) => Promise<string>;
  updateSessionAudio: (sessionId: string, audioKey: string) => Promise<void>;
  storeAudio: (key: string, base64: string) => Promise<string>;
  getAudioUrl: (key: string) => Promise<string | null>;
  createChild: (input: NewChild) => Promise<string>;
  // Loads a single session for the public share page (by its unguessable shareToken).
  // Optional so test helpers that don't exercise /share need not provide it.
  loadSession?: (shareToken: string) => Promise<ShareSession | null>;
  // Per-child auth: returns the stored token hash (or null for legacy children). Optional so
  // tests that don't exercise auth need not provide it (auth is skipped when absent).
  loadChildAuth?: (childId: string) => Promise<{ tokenHash: string | null } | null>;
  // Payments: creates a Mollie checkout (only present when MOLLIE_API_KEY is configured).
  checkout?: (args: { redirectUrl: string; childId?: string; webhookUrl?: string }) => Promise<CheckoutResult>;
  // Static hosted-checkout fallback URL (when no live key).
  paymentLink?: string;
  // Confirms a payment's real status with Mollie (for the webhook).
  paymentStatus?: (paymentId: string) => Promise<{ status: string; metadata: Record<string, unknown> }>;
  // Flips a child to subscribed (called after a confirmed paid checkout).
  markSubscribed?: (childId: string) => Promise<void>;
};

// Minimal view of a session for the public /share page.
type ShareSession = { title?: string; storyText?: string | null; audioKey?: string | null };

const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function sharePage(title: string, storyText: string, audioUrl: string | null): string {
  const paragraphs = storyText
    .split(/\n\s*\n/)
    .map((p) => `<p>${escapeHtml(p.trim())}</p>`)
    .join("\n");
  const audio = audioUrl
    ? `<audio controls preload="none" src="${escapeHtml(audioUrl)}"></audio>`
    : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${escapeHtml(title)} — Yarnia</title>
<style>
  body{margin:0;background:#12132a;color:#f6efe0;font-family:Georgia,'Times New Roman',serif;line-height:1.7}
  main{max-width:42rem;margin:0 auto;padding:3rem 1.5rem 5rem}
  h1{font-size:1.6rem;color:#f1c673;font-weight:600}
  .moon{font-size:2.5rem}
  p{font-size:1.1rem;font-style:italic;opacity:.92}
  audio{width:100%;margin:1.5rem 0}
  a{color:#f1c673} footer{margin-top:3rem;opacity:.6;font-size:.9rem;font-style:normal}
</style></head><body><main>
<div class="moon">🌙</div>
<h1>${escapeHtml(title)}</h1>
${audio}
${paragraphs}
<footer>A bedtime story from <a href="https://yarnia.quest">Yarnia</a>. Make one for your little one.</footer>
</main></body></html>`;
}

const shareNotFoundPage = () =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"/><title>Story not found — Yarnia</title>
<style>body{margin:0;background:#12132a;color:#f6efe0;font-family:Georgia,serif;text-align:center;padding:5rem 1.5rem}a{color:#f1c673}</style>
</head><body><div style="font-size:2.5rem">🌙</div><p>This story could not be found.</p>
<p><a href="https://yarnia.quest">Make a bedtime story with Yarnia</a></p></body></html>`;

// What onboarding collects. name + age are required (the two questions the screen-off
// onboarding asks); the rest default to empty. Stored verbatim into the `children` entity.
type NewChild = {
  name: string;
  age: number;
  favoriteCharacters: string[];
  themes: string[];
  fearsToAvoid: string[];
  tokenHash?: string;
};

function defaultDeps(env: Bindings): AppDeps {
  const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
  return {
    loadChild: (childId) => loadChild(childId, db.query.bind(db)),
    generate: (prompt) => generateStory(prompt, { apiKey: env.QWEN_API_KEY }),
    synthesize: (text) => synthesizeStory(text, { apiKey: env.ELEVENLABS_API_KEY }),
    agentId: env.ELEVENLABS_AGENT_ID,
    getSignedUrl: (agentId) => getSignedUrl(agentId, { apiKey: env.ELEVENLABS_API_KEY }),
    saveSession: async (childId, input) => {
      const sessionId = id();
      await db.transact(
        db.tx.sessions[sessionId]
          .update({
            title: input.title,
            summary: input.summary,
            messages: input.messages,
            charactersUsed: input.charactersUsed,
            continuityNotes: input.continuityNotes,
            storyText: input.storyText ?? null,
            audioKey: input.audioKey ?? null,
            createdAt: Date.now(),
            // Unguessable public-share handle (never the internal session id).
            shareToken: generateChildToken(),
          })
          .link({ child: childId }),
      );
      return sessionId;
    },
    // Attaches the narration mp3 to an already-saved session (the audio is synthesized
    // after the row is written so the story shows up in history without waiting on TTS).
    updateSessionAudio: async (sessionId, audioKey) => {
      await db.transact(db.tx.sessions[sessionId].update({ audioKey }));
    },
    storeAudio: async (key, base64) => {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      await db.storage.uploadFile(key, bytes, { contentType: "audio/mpeg" });
      return key;
    },
    getAudioUrl: async (key) => {
      const res = await db.query({ $files: { $: { where: { path: key } } } });
      return res.$files?.[0]?.url ?? null;
    },
    // Mints a child row with the admin token (clients can't write `children` — perms are
    // all-false). The generated id is the stable handle the app keeps so the same child is
    // recalled on future nights.
    createChild: async (input) => {
      const childId = id();
      await db.transact(
        db.tx.children[childId].update({
          name: input.name,
          age: input.age,
          favoriteCharacters: input.favoriteCharacters,
          themes: input.themes,
          fearsToAvoid: input.fearsToAvoid,
          createdAt: Date.now(),
          tokenHash: input.tokenHash ?? null,
        }),
      );
      return childId;
    },
    // Loads one session by its public shareToken for /share (best-effort; null if absent).
    loadSession: async (shareToken) => {
      const res = await db.query({ sessions: { $: { where: { shareToken } } } });
      const row = res?.sessions?.[0];
      if (!row) return null;
      return { title: row.title, storyText: row.storyText, audioKey: row.audioKey };
    },
    // Reads just the child's stored token hash for auth checks.
    loadChildAuth: async (childId) => {
      const res = await db.query({ children: { $: { where: { id: childId } } } });
      const row = res?.children?.[0];
      if (!row) return null;
      return { tokenHash: row.tokenHash ?? null };
    },
    // Live Mollie checkout, only when a key is configured. childId rides in metadata so the
    // webhook can grant the subscription to the right profile.
    checkout: env.MOLLIE_API_KEY
      ? ({ redirectUrl, childId, webhookUrl }) =>
          createCheckout({
            apiKey: env.MOLLIE_API_KEY as string,
            redirectUrl,
            webhookUrl,
            metadata: childId ? { childId } : undefined,
          })
      : undefined,
    paymentLink: env.MOLLIE_PAYMENT_LINK,
    paymentStatus: env.MOLLIE_API_KEY
      ? (paymentId) => getPaymentStatus(paymentId, { apiKey: env.MOLLIE_API_KEY as string })
      : undefined,
    markSubscribed: async (childId) => {
      await db.transact(db.tx.children[childId].update({ subscribed: true }));
    },
  };
}

// In-isolate rate limiters (best-effort; pair with Cloudflare account-level rules for durable
// enforcement). Only applied to real edge requests (those carrying cf-connecting-ip).
const storyLimiter = createRateLimiter({ limit: 30, windowMs: 60_000 }); // 30 stories/min/IP
const writeLimiter = createRateLimiter({ limit: 60, windowMs: 60_000 }); // 60 writes/min/IP

export function createApp(makeDeps: (env: Bindings) => AppDeps = defaultDeps) {
  const app = new Hono<{ Bindings: Bindings }>();

  app.use("/*", cors({ origin: (origin, c) => corsOrigin(origin, !!c.env?.ALLOW_LOCALHOST_CORS) }));

  // Optional shared-secret gate. No-op until YARNIA_API_TOKEN is set, so nothing breaks
  // before the secret is provisioned. Skips CORS preflight, the health route, and the
  // webhook (which authenticates with its own HMAC signature).
  app.use("/*", async (c, next) => {
    const required = c.env?.YARNIA_API_TOKEN;
    if (!required || c.req.method === "OPTIONS") return next();
    const path = c.req.path;
    // Public routes: health, the HMAC-verified agent webhook, the Mollie payments webhook
    // (verified by re-fetching status from Mollie), and the shareable story page.
    if (
      path === "/" ||
      path === "/healthz" ||
      path === "/agent/webhook" ||
      path === "/payments/webhook" ||
      path.startsWith("/share/")
    ) {
      return next();
    }
    if (c.req.header("x-yarnia-token") !== required) {
      return c.json({ error: "missing or invalid API token" }, 401);
    }
    return next();
  });

  // Telemetry bound to the request: structured logs + optional webhook forwarding via waitUntil.
  type Ctx = Context<{ Bindings: Bindings }>;
  const makeTelemetry = (c: Ctx) =>
    createTelemetry({
      errorWebhook: c.env?.ERROR_WEBHOOK,
      analyticsWebhook: c.env?.ANALYTICS_WEBHOOK,
      defer: (p) => {
        try {
          c.executionCtx.waitUntil(p);
        } catch {
          /* no execution context in tests */
        }
      },
    });

  // Enforces the per-child auth token on child-scoped routes. No-op when loadChildAuth is not
  // wired (tests) or the child is legacy (no stored hash). Returns a 401 Response when denied.
  const requireChildToken = async (c: Ctx, deps: AppDeps, childId: string) => {
    if (!deps.loadChildAuth) return null;
    const auth = await deps.loadChildAuth(childId);
    const ok = await verifyChildToken(auth?.tokenHash, c.req.header("x-child-token"));
    return ok ? null : c.json({ error: "invalid_child_token" }, 401);
  };

  app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

  // GET /healthz — readiness probe. Reports whether each dependency is configured so a monitor
  // can alert before users hit failures (no secrets are revealed, only presence booleans).
  app.get("/healthz", (c) => {
    const e = c.env ?? ({} as Bindings);
    const checks = {
      instant: !!e.INSTANT_APP_ID && !!e.INSTANT_ADMIN_TOKEN,
      story_gen: !!e.QWEN_API_KEY,
      voice: !!e.ELEVENLABS_API_KEY && !!e.ELEVENLABS_AGENT_ID,
      webhook_secret: !!e.ELEVENLABS_WEBHOOK_SECRET,
      payments: !!e.MOLLIE_API_KEY || !!e.MOLLIE_PAYMENT_LINK,
    };
    const ok = checks.instant && checks.story_gen && checks.voice;
    return c.json({ ok, checks }, ok ? 200 : 503);
  });

  // POST /payments/webhook — Mollie notifies us of a payment status change with just the id.
  // We never trust the body: we re-fetch the payment from Mollie, and only on a confirmed
  // "paid" status grant the subscription to the childId carried in the payment metadata.
  app.post("/payments/webhook", async (c) => {
    const deps = makeDeps(c.env);
    const telemetry = makeTelemetry(c);
    if (!deps.paymentStatus || !deps.markSubscribed) return c.json({ ok: true, skipped: true });
    // Mollie sends application/x-www-form-urlencoded: id=tr_xxx
    let paymentId: string | undefined;
    try {
      const form = await c.req.parseBody();
      paymentId = typeof form.id === "string" ? form.id : undefined;
    } catch {
      paymentId = undefined;
    }
    if (!paymentId) return c.json({ error: "missing payment id" }, 400);
    try {
      const { status, metadata } = await deps.paymentStatus(paymentId);
      const childId = typeof metadata.childId === "string" ? metadata.childId : undefined;
      if (status === "paid" && childId) {
        await deps.markSubscribed(childId);
        telemetry.track("subscription_activated", { childId, paymentId });
      }
      return c.json({ ok: true, status });
    } catch (err) {
      telemetry.error("payments_webhook_failed", { paymentId, message: String((err as Error)?.message ?? err) });
      return c.json({ error: "webhook_failed" }, 502);
    }
  });

  // POST /story — { childId, choice? } -> { childId, choice, text, audio, audioKey, status }.
  // Stores audio in Instant Storage; returns both the base64 URI (for immediate playback) and the key
  // (for later replay via GET /audio/:key without re-synthesizing).
  app.post("/story", async (c) => {
    const ip = c.req.header("cf-connecting-ip");
    if (ip && !storyLimiter.check(`story:${ip}`).allowed) {
      return c.json({ error: "rate_limited" }, 429);
    }
    const body = await c.req
      .json<{ childId?: string; choice?: string }>()
      .catch(() => ({}) as { childId?: string; choice?: string });
    const { childId } = body;
    if (!childId) return c.json({ error: "childId required" }, 400);

    const deps = makeDeps(c.env);
    const telemetry = makeTelemetry(c);
    const denied = await requireChildToken(c, deps, childId);
    if (denied) return denied;
    // Sanitize the caller-supplied choice before it ever reaches the LLM prompt.
    const choice = sanitizeChoice(body.choice ?? "") || "a gentle surprise";

    const result = await createStory(childId, choice, deps);
    if (!result.ok) {
      if (result.reason === "subscription_required") {
        // Free tier exhausted: the client should surface the EUR 8/mo subscribe flow.
        return c.json({ error: "subscription_required" }, 402);
      }
      telemetry.error("story_child_not_found", { childId });
      return c.json({ error: result.reason }, 404);
    }
    // Cost visibility: estimate and record the marginal LLM/TTS spend of this story.
    const cost = estimateStoryCost(result.text, result.audio != null);
    telemetry.track("story_created", {
      childId,
      hasAudio: result.audio != null,
      tokens: cost.tokens,
      estUsd: cost.totalUsd,
    });

    const audioBase64 = result.audio ?? null;
    const audioKey = audioBase64 ? `stories/${crypto.randomUUID()}.mp3` : null;

    try {
      c.executionCtx.waitUntil(
        (async () => {
          if (audioBase64 && audioKey) {
            await deps.storeAudio(audioKey, audioBase64);
          }
          await persistSession(childId, choice ?? "a gentle surprise", result.prompt, result.text, deps, audioKey ?? undefined);
        })(),
      );
    } catch {
      // no execution context in tests
    }

    return c.json({
      childId,
      choice: choice ?? null,
      text: result.text,
      audio: audioBase64 ? `data:audio/mpeg;base64,${audioBase64}` : null,
      audioKey,
      status: "ok",
    });
  });

  // POST /child — onboarding. { name, age, favoriteCharacters?, themes?, fearsToAvoid? }
  // -> { childId, name }. Mints a child row (admin-only write) and returns its id so the
  // app can immediately start a personalized voice session with GET /agent/session?childId=.
  app.post("/child", async (c) => {
    type ChildBody = {
      name?: string;
      age?: number;
      favoriteCharacters?: string[];
      themes?: string[];
      fearsToAvoid?: string[];
    };
    const ip = c.req.header("cf-connecting-ip");
    if (ip && !writeLimiter.check(`child:${ip}`).allowed) {
      return c.json({ error: "rate_limited" }, 429);
    }
    const body = await c.req.json<ChildBody>().catch(() => ({}) as ChildBody);
    // Sanitize every field that later flows into the LLM prompt, not just the per-request
    // `choice` — these are stored once and reused on every story, so injection here persists.
    const name = sanitizeChoice(body.name ?? "");
    if (!name) return c.json({ error: "name required" }, 400);
    if (typeof body.age !== "number" || !Number.isFinite(body.age)) {
      return c.json({ error: "age required" }, 400);
    }

    const deps = makeDeps(c.env);
    // Mint a per-child auth token; store only its hash, return the raw token to the client once.
    const childToken = generateChildToken();
    const childId = await deps.createChild({
      name,
      age: body.age,
      favoriteCharacters: sanitizeList(body.favoriteCharacters),
      themes: sanitizeList(body.themes),
      fearsToAvoid: sanitizeList(body.fearsToAvoid),
      tokenHash: await hashToken(childToken),
    });
    makeTelemetry(c).track("child_created", { childId });
    return c.json({ childId, name, childToken });
  });

  // GET /agent/session?childId=...
  app.get("/agent/session", async (c) => {
    const childId = c.req.query("childId");
    const deps = makeDeps(c.env);
    // Anonymous starts (no childId) are allowed; a given child requires its token.
    if (childId) {
      const denied = await requireChildToken(c, deps, childId);
      if (denied) return denied;
    }
    const result = await createAgentSession(childId, {
      loadChild: deps.loadChild,
      agentId: deps.agentId,
      getSignedUrl: deps.getSignedUrl,
    });
    if (!result.ok) return c.json({ error: result.reason }, 404);
    return c.json({
      agentId: result.agentId,
      dynamicVariables: result.dynamicVariables,
      signedUrl: result.signedUrl,
    });
  });

  // POST /agent/webhook — ElevenLabs post-call webhook (type "post_call_transcription").
  // This is the PRIMARY, durable save path: ElevenLabs calls it when a conversation ends,
  // so a story is persisted even if the app was killed/backgrounded or its network dropped
  // (the client POST /session/save is just a faster-feedback fallback). The transcript is in
  // the payload, so no polling is needed. We recover the child from the child_id dynamic
  // variable that round-trips through the conversation. HMAC-verified to reject forgeries.
  app.post("/agent/webhook", async (c) => {
    // Read the RAW body: HMAC is computed over the exact bytes, so we must not re-serialize.
    const rawBody = await c.req.text();
    const signature = c.req.header("ElevenLabs-Signature");
    const valid = await verifyWebhookSignature(rawBody, signature, c.env.ELEVENLABS_WEBHOOK_SECRET);
    if (!valid) return c.json({ error: "invalid signature" }, 401);

    let payload: {
      type?: string;
      data?: {
        transcript?: Array<{ role?: string; message?: string | null }>;
        conversation_initiation_client_data?: { dynamic_variables?: { child_id?: string } };
      };
    };
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return c.json({ error: "invalid json" }, 400);
    }

    // Ignore other event types (e.g. audio webhooks) without erroring, so EL doesn't retry them.
    if (payload.type !== "post_call_transcription") {
      return c.json({ ok: true, ignored: payload.type ?? null });
    }

    const data = payload.data ?? {};
    const childId = data.conversation_initiation_client_data?.dynamic_variables?.child_id;
    const transcript: ConversationTurn[] = (data.transcript ?? [])
      .filter((t): t is { role: string; message?: string | null } => t?.role === "agent" || t?.role === "user")
      .map((t) => ({ role: t.role as "agent" | "user", message: t.message ?? null }));

    // Anonymous conversation (no child) or an empty transcript: nothing to persist.
    if (!childId || !transcript.some((t) => t.role === "agent" && t.message)) {
      return c.json({ ok: true, persisted: false });
    }

    const deps = makeDeps(c.env);
    const persist = async () => {
      // 1) Write the session row FIRST (recap + memory). This is fast, so the story shows up
      //    in history almost immediately instead of waiting on mp3 synthesis.
      const sessionId = await persistAgentSession(childId, transcript, deps);
      if (!sessionId) return;

      // 2) Then the slow part — synthesize + store the narration mp3 — and attach it to the
      //    saved row. If TTS fails, the story is already saved (just without replay audio).
      const storyText = transcript
        .filter((t) => t.role === "agent" && t.message)
        .map((t) => t.message!)
        .join("\n\n");
      if (storyText) {
        try {
          const audioBase64 = await deps.synthesize(storyText.slice(0, 4500));
          if (audioBase64) {
            const audioKey = `stories/${crypto.randomUUID()}.mp3`;
            await deps.storeAudio(audioKey, audioBase64);
            await deps.updateSessionAudio(sessionId, audioKey);
          }
        } catch (err) {
          console.error("webhook audio synthesis/storage failed, story saved without audio:", err);
        }
      }
    };

    try {
      c.executionCtx.waitUntil(persist());
    } catch {
      await persist(); // no execution context in tests — run synchronously
    }
    return c.json({ ok: true, persisted: true });
  });

  // GET /child/:childId/sessions — past sessions newest-first.
  app.get("/child/:childId/sessions", async (c) => {
    const childId = c.req.param("childId");
    const deps = makeDeps(c.env);
    const denied = await requireChildToken(c, deps, childId);
    if (denied) return denied;
    const child = await deps.loadChild(childId);
    if (!child) return c.json({ error: "child_not_found" }, 404);

    const sessions = [...child.pastSessions]
      .reverse()
      .map((s) => ({
        title: s.title ?? "A bedtime story",
        summary: s.summary,
        charactersUsed: s.charactersUsed,
        continuityNotes: s.continuityNotes ?? [],
        createdAt: s.createdAt ?? null,
        storyText: s.storyText ?? null,
        audioKey: s.audioKey ?? null,
        // Public share handle so the client can build a /share link without exposing the id.
        shareToken: s.shareToken ?? null,
      }));

    return c.json({ sessions });
  });

  // POST /checkout — start the EUR 8/month subscription. Returns a hosted Mollie checkout URL
  // (live when MOLLIE_API_KEY is set, else a configured static link), or 503 if unconfigured.
  app.post("/checkout", async (c) => {
    const ip = c.req.header("cf-connecting-ip");
    if (ip && !writeLimiter.check(`checkout:${ip}`).allowed) {
      return c.json({ error: "rate_limited" }, 429);
    }
    const body = await c.req.json<{ childId?: string }>().catch(() => ({}) as { childId?: string });
    const deps = makeDeps(c.env);
    const telemetry = makeTelemetry(c);
    if (deps.checkout) {
      try {
        const redirectUrl = c.env?.APP_BASE_URL ?? "https://app.yarnia.quest";
        const origin = new URL(c.req.url).origin;
        const result = await deps.checkout({
          redirectUrl,
          childId: body.childId,
          webhookUrl: `${origin}/payments/webhook`,
        });
        telemetry.track("checkout_started", { paymentId: result.paymentId, mode: "live" });
        return c.json({ checkoutUrl: result.checkoutUrl, paymentId: result.paymentId, mode: "live" });
      } catch (err) {
        telemetry.error("checkout_failed", { message: String((err as Error)?.message ?? err) });
        return c.json({ error: "checkout_failed" }, 502);
      }
    }
    if (deps.paymentLink) {
      telemetry.track("checkout_started", { mode: "static" });
      return c.json({ checkoutUrl: deps.paymentLink, mode: "static" });
    }
    return c.json({ error: "payments_not_configured" }, 503);
  });

  // GET /share/:shareToken — public, unauthenticated HTML page for a saved story ("send to
  // grandma"). Looked up by an unguessable shareToken (never the internal session id). Renders
  // the story text and, when available, an audio player. No token required.
  app.get("/share/:shareToken", async (c) => {
    const deps = makeDeps(c.env);
    if (!deps.loadSession) return c.html(shareNotFoundPage(), 404);
    const session = await deps.loadSession(c.req.param("shareToken"));
    if (!session || !session.storyText) return c.html(shareNotFoundPage(), 404);
    let audioUrl: string | null = null;
    if (session.audioKey) {
      try {
        audioUrl = await deps.getAudioUrl(session.audioKey);
      } catch {
        audioUrl = null;
      }
    }
    return c.html(sharePage(session.title ?? "A bedtime story", session.storyText, audioUrl));
  });

  // GET /audio-url/:key — return the signed CloudFront URL for a stored audio file.
  // Flutter fetches this once, downloads the file, caches it locally, plays from cache.
  app.get("/audio-url/:key{.+}", async (c) => {
    const key = c.req.param("key");
    const deps = makeDeps(c.env);
    const url = await deps.getAudioUrl(key);
    if (!url) return c.json({ error: "not_found" }, 404);
    return c.json({ url });
  });

  return app;
}

export default createApp();
