import { Hono } from "hono";
import { cors } from "hono/cors";
import { init } from "@instantdb/admin";
import { loadChild } from "./child";
import { generateStory } from "./generate";
import { createStory, type StoryDeps } from "./story";

// Bindings come from api/.dev.vars locally (generated from api/.env) and from
// `wrangler secret put` / GitHub Actions in production. Never hardcoded. See api/.env.example.
type Bindings = {
  QWEN_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  INSTANT_APP_ID: string;
  INSTANT_ADMIN_TOKEN: string;
};

// Real story dependencies, built from the Worker env: loadChild over the InstantDB admin
// SDK, generate over Qwen. Injectable so tests pass fakes (see createApp).
function defaultDeps(env: Bindings): StoryDeps {
  const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
  return {
    loadChild: (childId) => loadChild(childId, db.query.bind(db)),
    generate: (prompt) => generateStory(prompt, { apiKey: env.QWEN_API_KEY }),
  };
}

export function createApp(makeDeps: (env: Bindings) => StoryDeps = defaultDeps) {
  const app = new Hono<{ Bindings: Bindings }>();

  // The Expo app (app/) calls this Worker cross-origin.
  app.use("/*", cors());

  app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

  // POST /story — { childId, choice? } -> { childId, choice, text, audio, status }.
  // Loads the child's memory, builds a safety-constrained prompt, generates the story.
  // (audio stays null until the ElevenLabs slice lands.)
  app.post("/story", async (c) => {
    const body = await c.req
      .json<{ childId?: string; choice?: string }>()
      .catch(() => ({}) as { childId?: string; choice?: string });
    const { childId, choice } = body;
    if (!childId) return c.json({ error: "childId required" }, 400);

    const result = await createStory(childId, choice ?? "a gentle surprise", makeDeps(c.env));
    if (!result.ok) return c.json({ error: result.reason }, 404);

    return c.json({
      childId,
      choice: choice ?? null,
      text: result.text,
      audio: null,
      status: "ok",
    });
  });

  return app;
}

export default createApp();
