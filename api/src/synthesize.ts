// ElevenLabs text-to-speech: turn a story into narration audio (base64 mp3).
// Docs: https://elevenlabs.io/docs/api-reference/text-to-speech/convert
// `fetch` is injectable so the client is unit-testable with no key and no API spend.
import { withTimeout } from "./timeout";

const DEFAULT_BASE_URL = "https://api.elevenlabs.io";
// "Clara" (Relaxing/Calm) — the same voice as the conversational agent, so the child hears
// one consistent storyteller across /story and the live agent. Override via opts.voiceId.
const DEFAULT_VOICE = "Qggl4b0xRMiqOwhPtVWT";
const DEFAULT_MODEL = "eleven_multilingual_v2";

export type SynthesizeOpts = {
  apiKey: string;
  voiceId?: string;
  modelId?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
  // Retry budget for TRANSIENT failures (5xx, network errors). Default 2 (so up to 3 attempts).
  maxRetries?: number;
  // Base backoff between retries; grows linearly per attempt. Default 300ms (0 in tests).
  retryDelayMs?: number;
  // Per-attempt timeout; a hung TTS call rejects (and is retried) rather than stalling.
  timeoutMs?: number;
};

const sleep = (ms: number) => (ms > 0 ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve());

// Returns base64-encoded mp3. The route wraps it as a data: URI for the client to play.
// Transient failures (5xx, dropped connections) are retried with backoff; permanent ones
// (4xx: bad key, quota_exceeded) fail fast since retrying cannot help.
export async function synthesizeStory(text: string, opts: SynthesizeOpts): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const voiceId = opts.voiceId ?? DEFAULT_VOICE;
  const modelId = opts.modelId ?? DEFAULT_MODEL;
  const maxRetries = opts.maxRetries ?? 2;
  const retryDelayMs = opts.retryDelayMs ?? 300;
  const timeoutMs = opts.timeoutMs ?? 20_000;

  for (let attempt = 0; ; attempt++) {
    let res: Response;
    try {
      res = await withTimeout(
        () =>
          doFetch(`${baseUrl}/v1/text-to-speech/${voiceId}`, {
            method: "POST",
            headers: {
              "xi-api-key": opts.apiKey,
              "content-type": "application/json",
              accept: "audio/mpeg",
            },
            body: JSON.stringify({ text, model_id: modelId }),
          }),
        timeoutMs,
      );
    } catch (networkErr) {
      // Network failure or per-attempt timeout: transient, retry if budget remains.
      if (attempt < maxRetries) {
        await sleep(retryDelayMs * (attempt + 1));
        continue;
      }
      throw networkErr;
    }

    if (!res.ok) {
      // ElevenLabs returns 401 for several distinct states (bad key, free-tier disabled,
      // quota_exceeded). Surface its `detail.status` so the fallback log says *why* narration
      // was skipped. 5xx is transient (retry); 4xx is permanent (fail fast).
      const reason = await readErrorReason(res);
      if (res.status >= 500 && attempt < maxRetries) {
        await sleep(retryDelayMs * (attempt + 1));
        continue;
      }
      throw new Error(`ElevenLabs request failed: ${res.status}${reason ? ` (${reason})` : ""}`);
    }

    const buf = await res.arrayBuffer();
    if (buf.byteLength === 0) {
      throw new Error("ElevenLabs returned empty audio");
    }
    return base64FromArrayBuffer(buf);
  }
}

// Best-effort extraction of ElevenLabs' error reason. Their error bodies look like
// { detail: { status, message } } (status e.g. "quota_exceeded", "detected_unusual_activity").
// Returns "" if the body is missing or not the expected JSON shape.
async function readErrorReason(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { detail?: { status?: string; message?: string } };
    return body?.detail?.status ?? body?.detail?.message ?? "";
  } catch {
    return "";
  }
}

// Workers-native base64 (no Node Buffer): build a binary string, then btoa.
function base64FromArrayBuffer(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}
