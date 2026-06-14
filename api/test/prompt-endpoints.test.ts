import { describe, it, expect, vi } from "vitest";
import { createApp } from "../src/index";
import type { Child } from "../src/prompt";

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
    generate: async () => "STORY",
    saveSession: over.saveSession ?? (async () => "session-id"),
    agentId: "agent_test",
    getSignedUrl: async () => "wss://signed",
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

describe("POST /story/prompt", () => {
  it("returns a built prompt with the child's memory, no LLM call", async () => {
    const generate = vi.fn(async () => "should not be called");
    const app = createApp(() => ({
      loadChild: async () => lisa,
      generate,
      saveSession: async () => "s",
      agentId: "a",
      getSignedUrl: async () => "u",
      updateSessionAudio: async () => {},
      storeAudio: async (k: string) => k,
      getAudioUrl: async () => "x",
      createChild: async () => "c",
    }) as never);
    const res = await post(app, "/story/prompt", { childId: "lisa-1", choice: "a fox", language: "en" });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.system).toContain("Lisa");
    expect(body.user).toContain("fox");
    expect(body.user).toContain("Sharing Stones"); // recall layer present
    expect(body.choice).toBe("a fox");
    expect(generate).not.toHaveBeenCalled();
  });

  it("400 without childId", async () => {
    expect((await post(appWith({}), "/story/prompt", {})).status).toBe(400);
  });

  it("404 for unknown child", async () => {
    const res = await post(appWith({ loadChild: async () => null }), "/story/prompt", { childId: "x" });
    expect(res.status).toBe(404);
  });
});

describe("POST /session/persist", () => {
  it("saves an on-device-generated story", async () => {
    const saveSession = vi.fn(async () => "sess-42");
    const res = await post(appWith({ saveSession }), "/session/persist", {
      childId: "lisa-1",
      choice: "a fox",
      text: "Once upon a time, Lisa met a kind fox. They watched the stars and fell asleep.",
      system: "sys",
      user: "usr",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, sessionId: "sess-42" });
    expect(saveSession).toHaveBeenCalledOnce();
    const input = saveSession.mock.calls[0][1] as { storyText: string; messages: unknown[] };
    expect(input.storyText).toContain("kind fox");
    expect(input.messages.length).toBe(3); // system, user, assistant
  });

  it("400 without text", async () => {
    expect((await post(appWith({}), "/session/persist", { childId: "lisa-1" })).status).toBe(400);
  });
});
