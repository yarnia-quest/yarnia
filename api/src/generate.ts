// Story generation via DashScope (OpenAI-compatible, requires API key).
// `fetch` is injectable so the client is unit-testable with no API spend.
import type { StoryPrompt } from "./prompt";
import { withTimeout } from "./timeout";

// DashScope international endpoint — OpenAI-compatible, needs Bearer auth.
const DEFAULT_BASE_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
const DEFAULT_MODEL = "qwen3.7-max";
const DEFAULT_TIMEOUT_MS = 45_000;

export type GenerateOpts = {
  model?: string;
  baseUrl?: string;
  apiKey?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
  maxTokens?: number;
};

export type ChatMessage = { role: "user" | "assistant"; content: string };

type ChatResponse = {
  choices?: { message?: { content?: string } }[];
};

// Multi-turn chat generation — takes a system prompt and a full conversation history.
export async function generateChat(
  system: string,
  history: ChatMessage[],
  opts: GenerateOpts = {},
): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const model = opts.model ?? DEFAULT_MODEL;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  return withTimeout(async () => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (opts.apiKey) headers["authorization"] = `Bearer ${opts.apiKey}`;

    const res = await doFetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        model,
        messages: [{ role: "system", content: system }, ...history],
        enable_thinking: false,
        ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
      }),
    });

    if (!res.ok) throw new Error(`LLM request failed: ${res.status}`);
    const data = (await res.json()) as ChatResponse;
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) throw new Error("LLM returned no text");
    return text;
  }, timeoutMs);
}

export async function generateStory(prompt: StoryPrompt, opts: GenerateOpts = {}): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const model = opts.model ?? DEFAULT_MODEL;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  // Bounded so a hung call can never hold the request open.
  return withTimeout(async () => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (opts.apiKey) headers["authorization"] = `Bearer ${opts.apiKey}`;

    const res = await doFetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: prompt.system },
          { role: "user", content: prompt.user },
        ],
        // Disable the reasoning pass — ~4s vs ~49s, no quality loss for stories.
        enable_thinking: false,
        ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
      }),
    });

    if (!res.ok) {
      throw new Error(`LLM request failed: ${res.status}`);
    }

    const data = (await res.json()) as ChatResponse;
    const text = data.choices?.[0]?.message?.content?.trim();
    if (!text) {
      throw new Error("LLM returned no story text");
    }
    return text;
  }, timeoutMs);
}
