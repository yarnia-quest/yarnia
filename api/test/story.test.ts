import { describe, it, expect, vi } from "vitest";
import app, { createApp } from "../src/index";
import type { Child } from "../src/prompt";
import type { ConversationTurn } from "../src/agent";

// The app's deps: story deps plus the agent-session deps.
type AppDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  generate: (prompt: unknown) => Promise<string>;
  synthesize: (text: string) => Promise<string>;
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
  saveSession: (childId: string, input: unknown) => Promise<void>;
  fetchTranscript: (conversationId: string) => Promise<ConversationTurn[]>;
  storeAudio: (key: string, base64: string) => Promise<void>;
  getAudio: (key: string) => Promise<ArrayBuffer | null>;
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
    fetchTranscript: deps.fetchTranscript ?? (async () => []),
    storeAudio: deps.storeAudio ?? (async () => {}),
    getAudio: deps.getAudio ?? (async () => null),
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

describe("POST /session/save", () => {
  it("400s when childId or conversationId is missing", async () => {
    const r1 = await post(appWith({}), "/session/save", { childId: "lisa-1" });
    expect(r1.status).toBe(400);
    const r2 = await post(appWith({}), "/session/save", { conversationId: "conv_abc" });
    expect(r2.status).toBe(400);
  });

  it("returns ok:true and calls fetchTranscript + saveSession in background", async () => {
    const fetchTranscript = vi.fn(async (): Promise<ConversationTurn[]> => [
      { role: "agent", message: "Welcome to Yarnia, Lisa." },
      { role: "user", message: "Hi!" },
      { role: "agent", message: "Once upon a time there was a gentle dragon..." },
    ]);
    const generate = vi.fn(async () =>
      JSON.stringify({ title: "The Gentle Dragon", summary: "dragon helped friends", characters: ["dragon"], continuityNotes: [] }),
    );
    const saveSession = vi.fn(async () => {});

    const res = await post(appWith({ fetchTranscript, generate, saveSession }), "/session/save", {
      childId: "lisa-1",
      conversationId: "conv_abc",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("retries an empty transcript with backoff, then saves once it's ready", async () => {
    vi.useFakeTimers();
    try {
      // ElevenLabs is slow to assemble the transcript: empty first, ready on retry.
      const fetchTranscript = vi
        .fn<() => Promise<ConversationTurn[]>>()
        .mockResolvedValueOnce([])
        .mockResolvedValueOnce([])
        .mockResolvedValue([{ role: "agent", message: "Once upon a time, a gentle dragon..." }]);
      const generate = vi.fn(async () =>
        JSON.stringify({ title: "Dragon", summary: "a gentle dragon", characters: ["dragon"], continuityNotes: [] }),
      );
      const saveSession = vi.fn(async () => {});

      const pending = post(appWith({ fetchTranscript, generate, saveSession }), "/session/save", {
        childId: "lisa-1",
        conversationId: "conv_slow",
      });
      // Drive the backoff sleeps to completion.
      await vi.runAllTimersAsync();
      const res = await pending;

      expect(res.status).toBe(200);
      expect(fetchTranscript.mock.calls.length).toBeGreaterThanOrEqual(3); // retried past the empties
      expect(saveSession).toHaveBeenCalledTimes(1); // saved once the transcript arrived
    } finally {
      vi.useRealTimers();
    }
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
