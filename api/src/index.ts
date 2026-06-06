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
};

// Everything the routes need, built from the Worker env. Injectable so tests pass fakes.
type AppDeps = StoryDeps & {
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: SaveSessionInput) => Promise<void>;
  fetchTranscript: (conversationId: string) => Promise<ConversationTurn[]>;
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
            createdAt: Date.now(),
          })
          .link({ child: childId }),
      ),
    fetchTranscript: (conversationId) =>
      fetchConversationTranscript(conversationId, { apiKey: env.ELEVENLABS_API_KEY }),
  };
}

export function createApp(makeDeps: (env: Bindings) => AppDeps = defaultDeps) {
  const app = new Hono<{ Bindings: Bindings }>();

  // The Expo app (app/) calls this Worker cross-origin.
  app.use("/*", cors());

  app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

  // POST /story — { childId, choice? } -> { childId, choice, text, audio, status }.
  app.post("/story", async (c) => {
    const body = await c.req
      .json<{ childId?: string; choice?: string }>()
      .catch(() => ({}) as { childId?: string; choice?: string });
    const { childId, choice } = body;
    if (!childId) return c.json({ error: "childId required" }, 400);

    const deps = makeDeps(c.env);
    const result = await createStory(childId, choice ?? "a gentle surprise", deps);
    if (!result.ok) return c.json({ error: result.reason }, 404);

    try {
      c.executionCtx.waitUntil(
        persistSession(childId, choice ?? "a gentle surprise", result.prompt, result.text, deps),
      );
    } catch {
      // no execution context in tests
    }

    return c.json({
      childId,
      choice: choice ?? null,
      text: result.text,
      audio: result.audio ? `data:audio/mpeg;base64,${result.audio}` : null,
      status: "ok",
    });
  });

  // GET /agent/session?childId=... — start a conversational ElevenLabs Agent session.
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

  // POST /session/save — { childId, conversationId } — fetches the ElevenLabs transcript,
  // runs a Qwen recap, and saves to InstantDB. Called by Flutter after agent onDisconnect.
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
          await persistAgentSession(childId, transcript, deps);
        })(),
      );
    } catch {
      // no execution context in tests
    }
    return c.json({ ok: true });
  });

  // GET /child/:childId/sessions — past sessions newest-first, including storyText for replay.
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
      }));

    return c.json({ sessions });
  });

  // POST /tts — { text } -> { audio } — re-narrates any text via ElevenLabs TTS.
  // Used by the history panel "listen again" feature.
  app.post("/tts", async (c) => {
    const body = await c.req
      .json<{ text?: string }>()
      .catch(() => ({}) as { text?: string });
    const { text } = body;
    if (!text) return c.json({ error: "text required" }, 400);

    const deps = makeDeps(c.env);
    const audio = await deps.synthesize(text);
    return c.json({ audio: audio ? `data:audio/mpeg;base64,${audio}` : null });
  });

  return app;
}

export default createApp();
