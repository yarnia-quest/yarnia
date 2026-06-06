import { Hono } from "hono";
import { cors } from "hono/cors";
import { init, id } from "@instantdb/admin";
import { loadChild } from "./child";
import { generateStory } from "./generate";
import { synthesizeStory } from "./synthesize";
import { createStory, type StoryDeps } from "./story";
import { createAgentSession, getSignedUrl, type ConversationTurn } from "./agent";
import { persistSession, persistAgentSession, type SaveSessionInput } from "./session";
import { verifyWebhookSignature } from "./webhook";

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
};

// Everything the routes need, built from the Worker env. Injectable so tests pass fakes.
type AppDeps = StoryDeps & {
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: SaveSessionInput) => Promise<void>;
  storeAudio: (key: string, base64: string) => Promise<string>;
  getAudioUrl: (key: string) => Promise<string | null>;
  createChild: (input: NewChild) => Promise<string>;
};

// What onboarding collects. name + age are required (the two questions the screen-off
// onboarding asks); the rest default to empty. Stored verbatim into the `children` entity.
type NewChild = {
  name: string;
  age: number;
  favoriteCharacters: string[];
  themes: string[];
  fearsToAvoid: string[];
};

function defaultDeps(env: Bindings): AppDeps {
  const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
  return {
    loadChild: (childId) => loadChild(childId, db.query.bind(db)),
    generate: (prompt) => generateStory(prompt, { apiKey: env.QWEN_API_KEY }),
    synthesize: (text) => synthesizeStory(text, { apiKey: env.ELEVENLABS_API_KEY }),
    agentId: env.ELEVENLABS_AGENT_ID,
    getSignedUrl: (agentId) => getSignedUrl(agentId, { apiKey: env.ELEVENLABS_API_KEY }),
    saveSession: (childId, input) =>
      db.transact(
        db.tx.sessions[id()]
          .update({
            title: input.title,
            summary: input.summary,
            messages: input.messages,
            charactersUsed: input.charactersUsed,
            continuityNotes: input.continuityNotes,
            storyText: input.storyText ?? null,
            audioKey: input.audioKey ?? null,
            createdAt: Date.now(),
          })
          .link({ child: childId }),
      ),
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
        }),
      );
      return childId;
    },
  };
}

export function createApp(makeDeps: (env: Bindings) => AppDeps = defaultDeps) {
  const app = new Hono<{ Bindings: Bindings }>();

  app.use("/*", cors());

  app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

  // POST /story — { childId, choice? } -> { childId, choice, text, audio, audioKey, status }.
  // Stores audio in Instant Storage; returns both the base64 URI (for immediate playback) and the key
  // (for later replay via GET /audio/:key without re-synthesizing).
  app.post("/story", async (c) => {
    const body = await c.req
      .json<{ childId?: string; choice?: string }>()
      .catch(() => ({}) as { childId?: string; choice?: string });
    const { childId, choice } = body;
    if (!childId) return c.json({ error: "childId required" }, 400);

    const deps = makeDeps(c.env);
    const result = await createStory(childId, choice ?? "a gentle surprise", deps);
    if (!result.ok) return c.json({ error: result.reason }, 404);

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
    const body = await c.req.json<ChildBody>().catch(() => ({}) as ChildBody);
    const name = body.name?.trim();
    if (!name) return c.json({ error: "name required" }, 400);
    if (typeof body.age !== "number" || !Number.isFinite(body.age)) {
      return c.json({ error: "age required" }, 400);
    }

    const deps = makeDeps(c.env);
    const childId = await deps.createChild({
      name,
      age: body.age,
      favoriteCharacters: body.favoriteCharacters ?? [],
      themes: body.themes ?? [],
      fearsToAvoid: body.fearsToAvoid ?? [],
    });
    return c.json({ childId, name });
  });

  // GET /agent/session?childId=...
  app.get("/agent/session", async (c) => {
    const childId = c.req.query("childId");
    const deps = makeDeps(c.env);
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
      const storyText = transcript
        .filter((t) => t.role === "agent" && t.message)
        .map((t) => t.message!)
        .join("\n\n");

      let audioKey: string | undefined;
      if (storyText) {
        try {
          const audioBase64 = await deps.synthesize(storyText.slice(0, 4500));
          if (audioBase64) {
            audioKey = `stories/${crypto.randomUUID()}.mp3`;
            await deps.storeAudio(audioKey, audioBase64);
          }
        } catch (err) {
          console.error("webhook audio synthesis/storage failed, continuing without audio:", err);
        }
      }
      await persistAgentSession(childId, transcript, deps, audioKey);
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
      }));

    return c.json({ sessions });
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
