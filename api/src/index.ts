import { Hono } from "hono";
import { cors } from "hono/cors";
import { init, id } from "@instantdb/admin";
import { loadChild } from "./child";
import { generateStory } from "./generate";
import { synthesizeStory } from "./synthesize";
import { createStory, type StoryDeps } from "./story";
import { createAgentSession, getSignedUrl, fetchConversationTranscript, type ConversationTurn } from "./agent";
import { persistSession, persistAgentSession, type SaveSessionInput } from "./session";

// Bindings come from api/.dev.vars locally (generated from api/.env) and from
// `wrangler secret put` / GitHub Actions in production. Never hardcoded. See api/.env.example.
type Bindings = {
  QWEN_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_AGENT_ID: string;
  INSTANT_APP_ID: string;
  INSTANT_ADMIN_TOKEN: string;
  AUDIO: R2Bucket;
};

// Everything the routes need, built from the Worker env. Injectable so tests pass fakes.
type AppDeps = StoryDeps & {
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: SaveSessionInput) => Promise<void>;
  fetchTranscript: (conversationId: string) => Promise<ConversationTurn[]>;
  storeAudio: (key: string, base64: string) => Promise<void>;
  getAudio: (key: string) => Promise<ArrayBuffer | null>;
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
    fetchTranscript: (conversationId) =>
      fetchConversationTranscript(conversationId, { apiKey: env.ELEVENLABS_API_KEY }),
    storeAudio: async (key, base64) => {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      await env.AUDIO.put(key, bytes, { httpMetadata: { contentType: "audio/mpeg" } });
    },
    getAudio: async (key) => {
      const obj = await env.AUDIO.get(key);
      if (!obj) return null;
      return obj.arrayBuffer();
    },
  };
}

export function createApp(makeDeps: (env: Bindings) => AppDeps = defaultDeps) {
  const app = new Hono<{ Bindings: Bindings }>();

  app.use("/*", cors());

  app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

  // POST /story — { childId, choice? } -> { childId, choice, text, audio, audioKey, status }.
  // Stores audio in R2; returns both the base64 URI (for immediate playback) and the key
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

  // POST /session/save — { childId, conversationId }
  // Fetches ElevenLabs transcript, synthesizes audio, stores in R2, saves session.
  app.post("/session/save", async (c) => {
    const body = await c.req
      .json<{ childId?: string; conversationId?: string }>()
      .catch(() => ({}) as { childId?: string; conversationId?: string });
    const { childId, conversationId } = body;
    if (!childId || !conversationId) {
      return c.json({ error: "childId and conversationId required" }, 400);
    }

    const deps = makeDeps(c.env);
    try {
      c.executionCtx.waitUntil(
        (async () => {
          const transcript = await deps.fetchTranscript(conversationId);
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
              console.error("audio synthesis/storage failed, continuing without audio:", err);
            }
          }

          await persistAgentSession(childId, transcript, deps, audioKey);
        })(),
      );
    } catch {
      // no execution context in tests
    }
    return c.json({ ok: true });
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

  // GET /audio/:key — serve a stored audio file from R2.
  app.get("/audio/:key{.+}", async (c) => {
    const key = c.req.param("key");
    const deps = makeDeps(c.env);
    const buf = await deps.getAudio(key);
    if (!buf) return c.json({ error: "not_found" }, 404);
    return new Response(buf, { headers: { "content-type": "audio/mpeg", "cache-control": "public, max-age=31536000" } });
  });

  return app;
}

export default createApp();
