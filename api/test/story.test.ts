import { describe, it, expect, vi } from "vitest";
import app, { createApp } from "../src/index";
import type { Child } from "../src/prompt";

// The app's deps: story deps plus the agent-session deps.
type AppDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  generate: (prompt: unknown) => Promise<string>;
  synthesize: (text: string) => Promise<string>;
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: unknown) => Promise<void>;
  storeAudio: (key: string, base64: string) => Promise<string>;
  getAudioUrl: (key: string) => Promise<string | null>;
  createChild: (input: unknown) => Promise<string>;
};

const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder"],
  pastSessions: [{ summary: "a dragon who shared", charactersUsed: ["dragon"] }],
};

// Build a test app whose deps are fakes (no InstantDB / Qwen), so the route is fully
// covered offline. The route never touches real services in these tests.
function appWith(deps: Partial<AppDeps>) {
  return createApp(() => ({
    loadChild: deps.loadChild ?? (async () => lisa),
    generate: deps.generate ?? (async () => "Once upon a time, Lisa..."),
    synthesize: deps.synthesize ?? (async () => "BASE64AUDIO"),
    agentId: deps.agentId ?? "agent_test",
    getSignedUrl: deps.getSignedUrl ?? (async () => "wss://signed"),
    saveSession: deps.saveSession ?? (async () => {}),
    storeAudio: deps.storeAudio ?? (async (key) => key),
    getAudioUrl: deps.getAudioUrl ?? (async () => "https://fake-url"),
    createChild: deps.createChild ?? (async () => "new-child-id"),
  }));
}

function post(target: ReturnType<typeof createApp>, path: string, body: unknown) {
  return target.request(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("GET /", () => {
  it("returns a health payload", async () => {
    const res = await app.request("/");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ service: "yarnia-api", ok: true });
  });
});

describe("POST /story", () => {
  it("400s when childId is missing (without building any deps)", async () => {
    // Uses the default app: deps factory must NOT run for a bad request.
    const res = await post(createApp(), "/story", {});
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "childId required" });
  });

  it("returns the generated story for a known child", async () => {
    const res = await post(appWith({}), "/story", { childId: "lisa-1", choice: "dragon" });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({
      childId: "lisa-1",
      choice: "dragon",
      text: "Once upon a time, Lisa...",
      audio: "data:audio/mpeg;base64,BASE64AUDIO",
      status: "ok",
    });
  });

  it("404s when the child is not found", async () => {
    const res = await post(appWith({ loadChild: async () => null }), "/story", { childId: "ghost" });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "child_not_found" });
  });
});

describe("POST /child", () => {
  it("400s when name is missing (without building any deps)", async () => {
    const res = await post(createApp(), "/child", {});
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "name required" });
  });

  it("400s when name is blank after trimming", async () => {
    const res = await post(appWith({}), "/child", { name: "   ", age: 6 });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "name required" });
  });

  it("400s when age is missing", async () => {
    const res = await post(appWith({}), "/child", { name: "Mira" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "age required" });
  });

  it("creates a child and returns the new childId + name", async () => {
    const createChild = vi.fn(async () => "child-abc");
    const res = await post(appWith({ createChild }), "/child", {
      name: "Mira",
      age: 6,
      favoriteCharacters: ["fox"],
      fearsToAvoid: ["spiders"],
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ childId: "child-abc", name: "Mira" });
    expect(createChild).toHaveBeenCalledWith({
      name: "Mira",
      age: 6,
      favoriteCharacters: ["fox"],
      themes: [],
      fearsToAvoid: ["spiders"],
    });
  });

  it("trims the name and defaults the optional preference fields", async () => {
    const createChild = vi.fn(async () => "child-xyz");
    const res = await post(appWith({ createChild }), "/child", { name: "  Sam  ", age: 4 });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ childId: "child-xyz", name: "Sam" });
    expect(createChild).toHaveBeenCalledWith({
      name: "Sam",
      age: 4,
      favoriteCharacters: [],
      themes: [],
      fearsToAvoid: [],
    });
  });
});

describe("GET /agent/session", () => {
  it("returns an anonymous session (empty name, asks the name) when no childId", async () => {
    const res = await appWith({}).request("/agent/session");
    expect(res.status).toBe(200);
    const json = (await res.json()) as { dynamicVariables: { child_name: string; greeting: string } };
    expect(json.dynamicVariables.child_name).toBe("");
    expect(json.dynamicVariables.greeting.toLowerCase()).toMatch(/name/);
  });

  it("returns agentId + dynamic variables + signedUrl for a known child", async () => {
    const res = await appWith({}).request("/agent/session?childId=lisa-1");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      agentId: "agent_test",
      dynamicVariables: {
        child_id: "lisa-1",
        child_name: "Lisa",
        child_age: "4",
        favorite_characters: "dragon",
        fears_to_avoid: "thunder",
        last_story: "a dragon who shared",
        session_state: "returning",
        active_story_series: "",
        last_series_episode: "",
        greeting:
          "Welcome back to Yarnia, Lisa, where your stories untangle. I remember our story about a dragon who shared. Are you all cozy and ready for a new one tonight?",
      },
      signedUrl: "wss://signed",
    });
  });

  it("404s when the child is not found", async () => {
    const res = await appWith({ loadChild: async () => null }).request("/agent/session?childId=ghost");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "child_not_found" });
  });

  it("greets in English (the agent handles other languages itself at runtime)", async () => {
    const res = await appWith({}).request("/agent/session?childId=lisa-1");
    expect(res.status).toBe(200);
    const json = (await res.json()) as { dynamicVariables: { greeting: string } };
    expect(json.dynamicVariables.greeting).toContain("Welcome back to Yarnia, Lisa");
    expect(json.dynamicVariables.greeting).toContain("a dragon who shared");
  });
});

describe("GET /child/:childId/sessions", () => {
  it("returns sessions newest-first for a known child", async () => {
    const res = await appWith({}).request("/child/lisa-1/sessions");
    expect(res.status).toBe(200);
    const json = (await res.json()) as { sessions: unknown[] };
    expect(json.sessions).toHaveLength(1);
    expect(json.sessions[0]).toMatchObject({
      summary: "a dragon who shared",
      charactersUsed: ["dragon"],
    });
  });

  it("404s for an unknown child", async () => {
    const res = await appWith({ loadChild: async () => null }).request("/child/ghost/sessions");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "child_not_found" });
  });
});

describe("POST /agent/webhook (ElevenLabs post-call)", () => {
  const SECRET = "whsec_test";
  const ENV = { ELEVENLABS_WEBHOOK_SECRET: SECRET } as Record<string, string>;

  async function signed(body: string, ts = Math.floor(Date.now() / 1000)) {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${body}`));
    const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `t=${ts},v0=${hex}`;
  }

  const webhookBody = (childId: string | null) =>
    JSON.stringify({
      type: "post_call_transcription",
      event_timestamp: 1_700_000_000,
      data: {
        conversation_id: "conv_xyz",
        transcript: [
          { role: "agent", message: "Once upon a time, a gentle dragon..." },
          { role: "user", message: "more!" },
        ],
        conversation_initiation_client_data: {
          dynamic_variables: childId ? { child_id: childId } : {},
        },
      },
    });

  it("401s when the signature is missing or invalid", async () => {
    const body = webhookBody("lisa-1");
    const res = await appWith({}).request(
      "/agent/webhook",
      { method: "POST", headers: { "content-type": "application/json" }, body },
      ENV,
    );
    expect(res.status).toBe(401);
  });

  it("verifies signature, persists the session, and synthesizes audio", async () => {
    const saveSession = vi.fn(async () => {});
    const synthesize = vi.fn(async () => "BASE64AUDIO");
    const storeAudio = vi.fn(async () => {});
    const generate = vi.fn(async () =>
      JSON.stringify({ title: "Dragon", summary: "a gentle dragon", characters: ["dragon"], continuityNotes: [] }),
    );
    const body = webhookBody("lisa-1");
    const res = await appWith({ saveSession, synthesize, storeAudio, generate }).request(
      "/agent/webhook",
      { method: "POST", headers: { "content-type": "application/json", "ElevenLabs-Signature": await signed(body) }, body },
      ENV,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, persisted: true });
    expect(synthesize).toHaveBeenCalledOnce();
    expect(storeAudio).toHaveBeenCalledOnce();
    expect(saveSession).toHaveBeenCalledOnce();
    expect(saveSession.mock.calls[0][0]).toBe("lisa-1"); // linked to the right child
  });

  it("ignores non-transcription event types", async () => {
    const saveSession = vi.fn(async () => {});
    const body = JSON.stringify({ type: "post_call_audio", data: {} });
    const res = await appWith({ saveSession }).request(
      "/agent/webhook",
      { method: "POST", headers: { "content-type": "application/json", "ElevenLabs-Signature": await signed(body) }, body },
      ENV,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, ignored: "post_call_audio" });
    expect(saveSession).not.toHaveBeenCalled();
  });

  it("does not persist an anonymous conversation (no child_id)", async () => {
    const saveSession = vi.fn(async () => {});
    const body = webhookBody(null);
    const res = await appWith({ saveSession }).request(
      "/agent/webhook",
      { method: "POST", headers: { "content-type": "application/json", "ElevenLabs-Signature": await signed(body) }, body },
      ENV,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, persisted: false });
    expect(saveSession).not.toHaveBeenCalled();
  });
});
