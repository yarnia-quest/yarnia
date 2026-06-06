import { describe, it, expect } from "vitest";
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
  }));
}

function post(target: ReturnType<typeof createApp>, body: unknown) {
  return target.request("/story", {
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
    const res = await post(createApp(), {});
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "childId required" });
  });

  it("returns the generated story for a known child", async () => {
    const res = await post(appWith({}), { childId: "lisa-1", choice: "dragon" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      childId: "lisa-1",
      choice: "dragon",
      text: "Once upon a time, Lisa...",
      audio: "data:audio/mpeg;base64,BASE64AUDIO",
      status: "ok",
    });
  });

  it("404s when the child is not found", async () => {
    const res = await post(appWith({ loadChild: async () => null }), { childId: "ghost" });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "child_not_found" });
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
