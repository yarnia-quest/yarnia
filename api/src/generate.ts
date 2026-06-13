// Story generation via Nebula (OpenAI-compatible, no auth required).
// `fetch` is injectable so the client is unit-testable with no API spend.
import type { StoryPrompt } from "./prompt";
import { withTimeout } from "./timeout";

// Nebula endpoint — OpenAI-compatible, no auth required.
const DEFAULT_BASE_URL = "https://ai.yapboz.cc/v1";
const DEFAULT_MODEL = "Qwen3-8B";
const DEFAULT_TIMEOUT_MS = 30_000;

export type GenerateOpts = {
  model?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
};

type ChatResponse = {
  choices?: { message?: { content?: string } }[];
};

export async function generateStory(prompt: StoryPrompt, opts: GenerateOpts = {}): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const model = opts.model ?? DEFAULT_MODEL;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  // Bounded so a hung call can never hold the request open.
  return withTimeout(async () => {
    const res = await doFetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: prompt.system },
          { role: "user", content: prompt.user },
        ],
      }),
    });

    if (!res.ok) {
      throw new Error(`Nebula request failed: ${res.status}`);
    }

    const data = (await res.json()) as ChatResponse;
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) {
      throw new Error("Nebula returned no story text");
    }
    return text;
  }, timeoutMs);
}
