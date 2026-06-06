import { describe, it, expect } from "vitest";
import { createApp } from "../src/index";

type ShareSession = { title?: string; storyText?: string | null; audioKey?: string | null };

function appWithShare(
  loadSession: (id: string) => Promise<ShareSession | null>,
  getAudioUrl?: (key: string) => Promise<string | null>,
) {
  return createApp(() => ({
    loadChild: async () => null,
    generate: async () => "x",
    synthesize: async () => "A",
    agentId: "a",
    getSignedUrl: async () => "wss",
    saveSession: async () => "s",
    updateSessionAudio: async () => {},
    storeAudio: async (k: string) => k,
    getAudioUrl: getAudioUrl ?? (async () => "https://cdn.example/audio.mp3"),
    createChild: async () => "c",
    loadSession,
  }) as never);
}

describe("GET /share/:sessionId (public shareable story page)", () => {
  it("renders an HTML page containing the story text and title", async () => {
    const app = appWithShare(async () => ({ title: "The Owl and the Cat", storyText: "Once upon a time, Lisa...", audioKey: null }));
    const res = await app.request("/share/abc123");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("The Owl and the Cat");
    expect(html).toContain("Once upon a time, Lisa");
  });

  it("includes an audio player when the session has audio", async () => {
    const app = appWithShare(
      async () => ({ title: "T", storyText: "s", audioKey: "stories/x.mp3" }),
      async () => "https://cdn.example/x.mp3",
    );
    const html = await (await app.request("/share/abc123")).text();
    expect(html).toContain("<audio");
    expect(html).toContain("https://cdn.example/x.mp3");
  });

  it("escapes HTML in the story text (no injection)", async () => {
    const app = appWithShare(async () => ({ title: "T", storyText: "<script>alert(1)</script>", audioKey: null }));
    const html = await (await app.request("/share/abc123")).text();
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("404s for an unknown session", async () => {
    const app = appWithShare(async () => null);
    expect((await app.request("/share/missing")).status).toBe(404);
  });

  it("stays public even when the API token gate is enabled", async () => {
    const app = appWithShare(async () => ({ title: "T", storyText: "s", audioKey: null }));
    const res = await app.request("/share/abc123", {}, { YARNIA_API_TOKEN: "secret" } as never);
    expect(res.status).toBe(200);
  });
});
