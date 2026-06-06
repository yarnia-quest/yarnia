import { describe, it, expect, vi } from "vitest";
import { synthesizeStory } from "../src/synthesize";

// Fake fetch returning binary audio bytes, recording the request.
function fakeFetch(bytes: Uint8Array, status = 200) {
  return vi.fn(async () => new Response(bytes, { status }));
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

  it("throws when the audio is empty", async () => {
    const f = fakeFetch(new Uint8Array([]));
    await expect(synthesizeStory("hi", { apiKey: "k", fetch: f })).rejects.toThrow(/empty/i);
  });
});
