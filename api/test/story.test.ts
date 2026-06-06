import { describe, it, expect } from "vitest";
import app, { createApp } from "../src/index";
import type { StoryDeps } from "../src/story";
import type { Child } from "../src/prompt";

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
function appWith(deps: Partial<StoryDeps>) {
  return createApp(() => ({
    loadChild: deps.loadChild ?? (async () => lisa),
    generate: deps.generate ?? (async () => "Once upon a time, Lisa..."),
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
      audio: null,
      status: "ok",
    });
  });

  it("404s when the child is not found", async () => {
    const res = await post(appWith({ loadChild: async () => null }), { childId: "ghost" });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "child_not_found" });
  });
});
