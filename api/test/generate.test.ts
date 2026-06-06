import { describe, it, expect, vi } from "vitest";
import { generateStory } from "../src/generate";
import type { StoryPrompt } from "../src/prompt";

const prompt: StoryPrompt = { system: "SYS", user: "USR" };
const okBody = { choices: [{ message: { content: "Once upon a time, Lisa..." } }] };

// A fetch double that records calls and returns a canned OpenAI-compatible response.
function fakeFetch(body: unknown, status = 200) {
  return vi.fn(
    async () =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      }),
  );
}

describe("generateStory (Qwen, OpenAI-compatible)", () => {
  it("posts to the Qwen chat/completions endpoint with bearer auth", async () => {
    const f = fakeFetch(okBody);
    await generateStory(prompt, { apiKey: "k-123", fetch: f });
    expect(f).toHaveBeenCalledOnce();
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toContain("dashscope-intl.aliyuncs.com");
    expect(url).toContain("/chat/completions");
    expect((init.headers as Record<string, string>).authorization).toBe("Bearer k-123");
  });

  it("sends the system+user prompt as messages with the qwen3.7-max model", async () => {
    const f = fakeFetch(okBody);
    await generateStory(prompt, { apiKey: "k", fetch: f });
    const body = JSON.parse((f.mock.calls[0][1] as RequestInit).body as string);
    expect(body.model).toBe("qwen3.7-max");
    // Disable the reasoning pass: MAX with thinking takes ~49s (times out); without it ~4s.
    expect(body.enable_thinking).toBe(false);
    expect(body.messages).toEqual([
      { role: "system", content: "SYS" },
      { role: "user", content: "USR" },
    ]);
  });

  it("returns the generated story text", async () => {
    const f = fakeFetch(okBody);
    expect(await generateStory(prompt, { apiKey: "k", fetch: f })).toBe("Once upon a time, Lisa...");
  });

  it("allows overriding model and baseUrl", async () => {
    const f = fakeFetch(okBody);
    await generateStory(prompt, {
      apiKey: "k",
      model: "qwen-turbo",
      baseUrl: "https://example.test/v1",
      fetch: f,
    });
    const [url, init] = f.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://example.test/v1/chat/completions");
    expect(JSON.parse(init.body as string).model).toBe("qwen-turbo");
  });

  it("throws on a non-ok response", async () => {
    const f = fakeFetch({ error: "unauthorized" }, 401);
    await expect(generateStory(prompt, { apiKey: "k", fetch: f })).rejects.toThrow(/401/);
  });

  it("throws when the response has no story text", async () => {
    const f = fakeFetch({ choices: [] });
    await expect(generateStory(prompt, { apiKey: "k", fetch: f })).rejects.toThrow(/no story/i);
  });
});
