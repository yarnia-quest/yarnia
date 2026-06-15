import { describe, it, expect, vi } from "vitest";
import { createApp } from "../src/index";
import { buildAgentTurnSystem, type Child } from "../src/prompt";

const mia: Child = {
  name: "Mia",
  age: 5,
  favoriteCharacters: ["fox"],
  themes: ["friendship", "animals"],
  fearsToAvoid: ["spiders"],
  pastSessions: [{ summary: "the fox and the feather", charactersUsed: ["fox"], title: "The Golden Feather" }],
};

function appWith(over: Record<string, unknown>) {
  return createApp(() => ({
    loadChild: over.loadChild ?? (async () => mia),
    generate: over.generate ?? (async () => "STORY"),
    generateGreeting: over.generateGreeting,
    generateAgentTurn: over.generateAgentTurn,
    agentId: "agent_test",
    getSignedUrl: async () => "wss://signed",
    saveSession: async () => "session-id",
    updateSessionAudio: async () => {},
    storeAudio: async (k: string) => k,
    getAudioUrl: async () => "https://fake",
    createChild: async () => "new-child-id",
  }) as never);
}

function post(target: ReturnType<typeof createApp>, path: string, body: unknown) {
  return target.request(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

// ── buildAgentTurnSystem ────────────────────────────────────────────────────

describe("buildAgentTurnSystem", () => {
  it("includes child name and language", () => {
    const s = buildAgentTurnSystem(mia, "de");
    expect(s).toContain("Mia");
    expect(s).toContain("German");
  });

  it("includes age when present", () => {
    expect(buildAgentTurnSystem(mia)).toContain("age 5");
  });

  it("includes last story reference", () => {
    expect(buildAgentTurnSystem(mia)).toContain("Golden Feather");
  });

  it("includes fears", () => {
    expect(buildAgentTurnSystem(mia)).toContain("spiders");
  });

  it("includes themes", () => {
    expect(buildAgentTurnSystem(mia)).toContain("friendship");
  });

  it("always includes READY: instruction", () => {
    expect(buildAgentTurnSystem(mia)).toContain("READY:");
  });

  it("defaults to English when language is omitted", () => {
    expect(buildAgentTurnSystem(mia)).toContain("English");
  });

  it("no last-story line when no past sessions", () => {
    const child = { ...mia, pastSessions: [] };
    expect(buildAgentTurnSystem(child)).not.toContain("last time");
  });
});

// ── POST /agent/turn ────────────────────────────────────────────────────────

describe("POST /agent/turn", () => {
  it("returns chatting phase for a normal reply", async () => {
    const generateAgentTurn = vi.fn(async () => "What kind of animal should be in the story?");
    const res = await post(appWith({ generateAgentTurn }), "/agent/turn", {
      childId: "mia-1",
      language: "en",
      history: [],
      userMessage: "I want a story about something cozy",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.phase).toBe("chatting");
    expect(body.say).toBe("What kind of animal should be in the story?");
    expect(body.brief).toBeUndefined();
  });

  it("returns ready phase when LLM responds with READY: prefix", async () => {
    const generateAgentTurn = vi.fn(async () => "READY: a little fox who finds a glowing feather");
    const res = await post(appWith({ generateAgentTurn }), "/agent/turn", {
      childId: "mia-1",
      language: "en",
      history: [{ role: "user", content: "a fox story" }],
      userMessage: "yes that sounds perfect",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.phase).toBe("ready");
    expect(body.brief).toBe("a little fox who finds a glowing feather");
    expect(body.say).toBeTruthy();
  });

  it("ready phase with leading sentence extracts say correctly", async () => {
    const generateAgentTurn = vi.fn(async () => "That sounds lovely! READY: a dragon who learned to share");
    const res = await post(appWith({ generateAgentTurn }), "/agent/turn", {
      childId: "mia-1",
      userMessage: "a dragon",
    });
    const body = await res.json();
    expect(body.phase).toBe("ready");
    expect(body.say).toContain("lovely");
    expect(body.brief).toBe("a dragon who learned to share");
  });

  it("passes conversation history to the LLM", async () => {
    const generateAgentTurn = vi.fn(async () => "Great choice!");
    await post(appWith({ generateAgentTurn }), "/agent/turn", {
      childId: "mia-1",
      history: [{ role: "assistant", content: "What should tonight be about?" }],
      userMessage: "a bunny",
    });
    const callArgs = generateAgentTurn.mock.calls[0];
    // generateAgentTurn receives (system, history) — check history contains the user utterance
    const history = callArgs[1] as { role: string; content: string }[];
    expect(history.some((m) => m.content.toLowerCase().includes("bunny"))).toBe(true);
  });

  it("400 when childId is missing", async () => {
    const res = await post(appWith({}), "/agent/turn", { userMessage: "a fox" });
    expect(res.status).toBe(400);
  });

  it("400 when userMessage is missing", async () => {
    const res = await post(appWith({}), "/agent/turn", { childId: "mia-1" });
    expect(res.status).toBe(400);
  });

  it("404 when child is not found", async () => {
    const res = await post(appWith({ loadChild: async () => null }), "/agent/turn", {
      childId: "ghost",
      userMessage: "hello",
    });
    expect(res.status).toBe(404);
  });
});
