import { describe, it, expect, vi } from "vitest";
import { synthesizeStory } from "../src/synthesize";

// Fake fetch returning binary audio bytes, recording the request.
function fakeFetch(bytes: Uint8Array, status = 200) {
  return vi.fn(async () => new Response(bytes, { status }));
}
// Fake fetch returning a JSON error body, as ElevenLabs does for quota/auth failures.
function fakeErrorFetch(detail: { status: string; message: string }, status = 401) {
  return vi.fn(
    async () =>
      new Response(JSON.stringify({ detail }), {
        status,
        headers: { "content-type": "application/json" },
      }),
  );
}
const AUDIO = new Uint8Array([1, 2, 3, 4]); // base64 -> "AQIDBA=="

describe("synthesizeStory (ElevenLabs TTS)", () => {
  it("posts to the text-to-speech voice endpoint with the xi-api-key header", async () => {
    const f = fakeFetch(AUDIO);
    await synthesizeStory("Once upon a time", { apiKey: "el-key", fetch: f });
    expect(f).toHaveBeenCalledOnce();
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("api.elevenlabs.io/v1/text-to-speech/");
    expect((init.headers as Record<string, string>)["xi-api-key"]).toBe("el-key");
  });

  it("sends the text and a model_id in the body", async () => {
    const f = fakeFetch(AUDIO);
    await synthesizeStory("Once upon a time", { apiKey: "k", fetch: f });
    const body = JSON.parse((f.mock.calls[0][1] as RequestInit).body as string);
    expect(body.text).toBe("Once upon a time");
    expect(body.model_id).toBeTruthy();
  });

  it("returns the audio as base64", async () => {
    const f = fakeFetch(AUDIO);
    expect(await synthesizeStory("hi", { apiKey: "k", fetch: f })).toBe("AQIDBA==");
  });

  it("uses the default voice but allows overriding voiceId", async () => {
    const f = fakeFetch(AUDIO);
    await synthesizeStory("hi", { apiKey: "k", voiceId: "custom-voice", fetch: f });
    expect((f.mock.calls[0][0] as string)).toContain("/text-to-speech/custom-voice");
  });

  it("throws on a non-ok response", async () => {
    const f = fakeFetch(AUDIO, 401);
    await expect(synthesizeStory("hi", { apiKey: "k", fetch: f })).rejects.toThrow(/401/);
  });

  it("surfaces the ElevenLabs reason (e.g. quota_exceeded) in the thrown error", async () => {
    const f = fakeErrorFetch({
      status: "quota_exceeded",
      message: "This request exceeds your quota.",
    });
    await expect(synthesizeStory("hi", { apiKey: "k", fetch: f })).rejects.toThrow(
      /401.*quota_exceeded/,
    );
  });

  it("throws when the audio is empty", async () => {
    const f = fakeFetch(new Uint8Array([]));
    await expect(synthesizeStory("hi", { apiKey: "k", fetch: f })).rejects.toThrow(/empty/i);
  });

  it("retries a transient 5xx and then succeeds", async () => {
    let n = 0;
    const f = vi.fn(async () => {
      n++;
      return n === 1 ? new Response("upstream", { status: 503 }) : new Response(AUDIO, { status: 200 });
    });
    const out = await synthesizeStory("hi", { apiKey: "k", fetch: f, retryDelayMs: 0 });
    expect(out).toBe("AQIDBA==");
    expect(f).toHaveBeenCalledTimes(2);
  });

  it("retries a thrown network error and then succeeds", async () => {
    let n = 0;
    const f = vi.fn(async () => {
      n++;
      if (n === 1) throw new Error("network down");
      return new Response(AUDIO, { status: 200 });
    });
    const out = await synthesizeStory("hi", { apiKey: "k", fetch: f, retryDelayMs: 0 });
    expect(out).toBe("AQIDBA==");
    expect(f).toHaveBeenCalledTimes(2);
  });

  it("does NOT retry a permanent 401 (bad key / quota)", async () => {
    const f = fakeFetch(AUDIO, 401);
    await expect(synthesizeStory("hi", { apiKey: "k", fetch: f, retryDelayMs: 0 })).rejects.toThrow(/401/);
    expect(f).toHaveBeenCalledOnce();
  });
});
