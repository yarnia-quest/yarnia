import { Hono } from "hono";
import { cors } from "hono/cors";

// Bindings come from api/.dev.vars locally (generated from api/.env) and from
// `wrangler secret put` / GitHub Actions in production. Never hardcoded. See api/.env.example.
type Bindings = {
  QWEN_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  INSTANT_APP_ID: string;
  INSTANT_ADMIN_TOKEN: string;
};

const app = new Hono<{ Bindings: Bindings }>();

// The Expo app (app/) calls this Worker cross-origin.
app.use("/*", cors());

app.get("/", (c) => c.json({ service: "yarnia-api", ok: true }));

// POST /story — the core endpoint. Frozen contract so app/ can integrate against it now;
// the pipeline (load child profile from InstantDB -> safety-constrained story via OpenAI
// -> narration via ElevenLabs -> persist) is wired in later build blocks.
//
// Request:  { childId: string, choice?: string }
// Response: { childId, choice, text: string | null, audio: string | null, status }
app.post("/story", async (c) => {
  const body = await c.req
    .json<{ childId?: string; choice?: string }>()
    .catch(() => ({}) as { childId?: string; choice?: string });
  const { childId, choice } = body;
  if (!childId) return c.json({ error: "childId required" }, 400);

  return c.json({
    childId,
    choice: choice ?? null,
    text: null,
    audio: null,
    status: "not_implemented",
  });
});

export default app;
