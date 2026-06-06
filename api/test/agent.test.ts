import { describe, it, expect, vi } from "vitest";
import { toDynamicVariables, getSignedUrl, createAgentSession } from "../src/agent";
import type { Child } from "../src/prompt";

const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon", "owl"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder", "loud noises"],
  pastSessions: [
    { summary: "an owl in the dark", charactersUsed: ["owl"] },
    { summary: "a gentle dragon who learned to share", charactersUsed: ["dragon"] },
  ],
};

describe("toDynamicVariables", () => {
  it("maps a returning child with no recurring cast (no active series)", () => {
    expect(toDynamicVariables(lisa)).toEqual({
      child_name: "Lisa",
      child_age: "4",
      favorite_characters: "dragon and owl",
      fears_to_avoid: "thunder, loud noises",
      last_story: "a gentle dragon who learned to share", // most recent session
      session_state: "returning",
      active_story_series: "", // owl + dragon each appear once -> no series
      last_series_episode: "",
    });
  });

  it("detects an active series when characters recur across sessions", () => {
    const withSeries: Child = {
      ...lisa,
      pastSessions: [
        { summary: "Pip the owl met a firefly", charactersUsed: ["Pip the owl"] },
        { summary: "Pip and the dragon built a fort", charactersUsed: ["Pip the owl", "the dragon"] },
        { summary: "the dragon shared his stones", charactersUsed: ["the dragon"] },
      ],
    };
    const v = toDynamicVariables(withSeries);
    expect(v.active_story_series).toContain("Pip the owl");
    expect(v.active_story_series).toContain("the dragon");
    expect(v.last_series_episode).toBe("the dragon shared his stones");
  });

  it("uses gentle fallbacks and first_time for a child with no history", () => {
    const blank: Child = {
      name: "Max",
      age: 6,
      favoriteCharacters: [],
      themes: [],
      fearsToAvoid: [],
      pastSessions: [],
    };
    const v = toDynamicVariables(blank);
    expect(v.child_name).toBe("Max");
    expect(v.favorite_characters).not.toBe("");
    expect(v.fears_to_avoid).not.toBe("");
    expect(v.last_story).not.toBe("");
    expect(v.session_state).toBe("first_time");
    expect(v.active_story_series).toBe("");
    expect(v.last_series_episode).toBe("");
  });
});

describe("getSignedUrl", () => {
  const fakeFetch = (body: unknown, status = 200) =>
    vi.fn(
      async () =>
        new Response(JSON.stringify(body), {
          status,
          headers: { "content-type": "application/json" },
        }),
    );

  it("GETs the convai signed-url endpoint with the agent id and xi-api-key", async () => {
    const f = fakeFetch({ signed_url: "wss://signed" });
    await getSignedUrl("agent_123", { apiKey: "el-key", fetch: f });
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("/v1/convai/conversation/get-signed-url?agent_id=agent_123");
    expect((init.headers as Record<string, string>)["xi-api-key"]).toBe("el-key");
  });

  it("returns the signed_url", async () => {
    const f = fakeFetch({ signed_url: "wss://signed" });
    expect(await getSignedUrl("a", { apiKey: "k", fetch: f })).toBe("wss://signed");
  });

  it("throws on a non-ok response", async () => {
    const f = fakeFetch({ error: "nope" }, 401);
    await expect(getSignedUrl("a", { apiKey: "k", fetch: f })).rejects.toThrow(/401/);
  });

  it("throws when no signed_url is returned", async () => {
    const f = fakeFetch({});
    await expect(getSignedUrl("a", { apiKey: "k", fetch: f })).rejects.toThrow(/signed_url/i);
  });
});

describe("createAgentSession (orchestration)", () => {
  it("loads the child and returns agentId + dynamic variables + signed url", async () => {
    const loadChild = vi.fn(async () => lisa);
    const getSignedUrlDep = vi.fn(async () => "wss://signed");
    const res = await createAgentSession("lisa-1", {
      loadChild,
      agentId: "agent_1",
      getSignedUrl: getSignedUrlDep,
    });
    expect(loadChild).toHaveBeenCalledWith("lisa-1");
    expect(getSignedUrlDep).toHaveBeenCalledWith("agent_1");
    expect(res).toEqual({
      ok: true,
      agentId: "agent_1",
      dynamicVariables: toDynamicVariables(lisa),
      signedUrl: "wss://signed",
    });
  });

  it("returns child_not_found when the child is missing", async () => {
    const res = await createAgentSession("nope", {
      loadChild: vi.fn(async () => null),
      agentId: "agent_1",
      getSignedUrl: vi.fn(),
    });
    expect(res).toEqual({ ok: false, reason: "child_not_found" });
  });

  it("degrades to signedUrl:null (still returns variables) when signing fails", async () => {
    const res = await createAgentSession("lisa-1", {
      loadChild: vi.fn(async () => lisa),
      agentId: "agent_1",
      getSignedUrl: vi.fn(async () => {
        throw new Error("ElevenLabs signed-url request failed: 401");
      }),
    });
    expect(res).toMatchObject({ ok: true, signedUrl: null });
    if (res.ok) expect(res.dynamicVariables.child_name).toBe("Lisa");
  });
});
