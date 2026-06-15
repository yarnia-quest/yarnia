import { describe, it, expect, vi } from "vitest";
import { createApp } from "../src/index";
import { buildGreetingPrompt, type Child } from "../src/prompt";

const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder"],
  pastSessions: [{ summary: "a dragon who shared", charactersUsed: ["dragon"], title: "Sharing Stones" }],
};

function appWith(over: Record<string, unknown>) {
  return createApp(() => ({
    loadChild: over.loadChild ?? (async () => lisa),
    generate: over.generate ?? (async () => "STORY"),
    generateGreeting: over.generateGreeting,
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

describe("buildGreetingPrompt", () => {
  it("greets the child by name and invites a story idea", () => {
    const p = buildGreetingPrompt(lisa);
    expect(p.system).toContain("Lisa");
    expect(p.system.toLowerCase()).toContain("greet");
  });
  it("greets in the chosen language", () => {
    expect(buildGreetingPrompt(lisa, "de").user.toLowerCase()).toContain("german");
  });
});

describe("POST /greeting", () => {
  it("returns a personalized greeting with agentContext", async () => {
    const generateGreeting = vi.fn(async () => "Hello Lisa! What should tonight's story be about?");
    const res = await post(appWith({ generateGreeting }), "/greeting", {
      childId: "lisa-1",
      language: "en",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.greeting).toBe("Hello Lisa! What should tonight's story be about?");
    expect(body.agentContext.name).toBe("Lisa");
    expect(body.agentContext.age).toBe(4);
    expect(body.agentContext.themes).toEqual(["friendship"]);
    expect(body.agentContext.fears).toEqual(["thunder"]);
    expect(body.agentContext.lastStory).toBe("Sharing Stones");
    expect(generateGreeting).toHaveBeenCalledOnce();
  });

  it("agentContext.lastStory is undefined when no past sessions", async () => {
    const childNoHistory = { ...lisa, pastSessions: [] };
    const res = await post(
      appWith({ loadChild: async () => childNoHistory }),
      "/greeting",
      { childId: "lisa-1" },
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.agentContext.lastStory).toBeUndefined();
  });

  it("400 without childId", async () => {
    const res = await post(appWith({}), "/greeting", {});
    expect(res.status).toBe(400);
  });

  it("404 for unknown child", async () => {
    const res = await post(appWith({ loadChild: async () => null }), "/greeting", {
      childId: "nope",
    });
    expect(res.status).toBe(404);
  });

  it("falls back to generate when generateGreeting is absent", async () => {
    const generate = vi.fn(async () => "Hi Lisa!");
    const res = await post(appWith({ generate }), "/greeting", { childId: "lisa-1" });
    expect(res.status).toBe(200);
    expect((await res.json()).greeting).toBe("Hi Lisa!");
    expect(generate).toHaveBeenCalledOnce();
  });
});
