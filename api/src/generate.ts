// Qwen story generation via the DashScope OpenAI-compatible API.
// Docs: https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope
// `fetch` is injectable so the client is unit-testable with no key and no API spend.
import type { StoryPrompt } from "./prompt";
import { withTimeout } from "./timeout";

// Singapore / international endpoint (right for an EU team). Override per region via baseUrl.
const DEFAULT_BASE_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
const DEFAULT_MODEL = "qwen3.7-max";
const DEFAULT_TIMEOUT_MS = 25_000;

export type GenerateOpts = {
  apiKey: string;
  model?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
};

type ChatResponse = {
  choices?: { message?: { content?: string } }[];
};

export async function generateStory(prompt: StoryPrompt, opts: GenerateOpts): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const model = opts.model ?? DEFAULT_MODEL;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  // Bounded so a hung Qwen call can never hold the request open; on timeout this rejects and
  // the route surfaces a clean error instead of stalling.
  return withTimeout(async () => {
    const res = await doFetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${opts.apiKey}`,
      },
      body: JSON.stringify({
        model,
        // qwen3.7-max with the reasoning pass on takes ~49s (times out); off it is ~4s and
        // the bedtime-story quality is unaffected. A story does not need chain-of-thought.
        enable_thinking: false,
        messages: [
          { role: "system", content: prompt.system },
          { role: "user", content: prompt.user },
        ],
      }),
    });

    if (!res.ok) {
      throw new Error(`Qwen request failed: ${res.status}`);
    }

    const data = (await res.json()) as ChatResponse;
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) {
      throw new Error("Qwen returned no story text");
    }
    return text;
  }, timeoutMs);
}
