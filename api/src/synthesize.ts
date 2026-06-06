// ElevenLabs text-to-speech: turn a story into narration audio (base64 mp3).
// Docs: https://elevenlabs.io/docs/api-reference/text-to-speech/convert
// `fetch` is injectable so the client is unit-testable with no key and no API spend.

const DEFAULT_BASE_URL = "https://api.elevenlabs.io";
// "Sarah" — mature, reassuring; a calm fit for bedtime narration. Override via opts.voiceId.
const DEFAULT_VOICE = "EXAVITQu4vr4xnSDxMaL";
const DEFAULT_MODEL = "eleven_multilingual_v2";

export type SynthesizeOpts = {
  apiKey: string;
  voiceId?: string;
  modelId?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
};

// Returns base64-encoded mp3. The route wraps it as a data: URI for the client to play.
export async function synthesizeStory(text: string, opts: SynthesizeOpts): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;
  const voiceId = opts.voiceId ?? DEFAULT_VOICE;
  const modelId = opts.modelId ?? DEFAULT_MODEL;

  const res = await doFetch(`${baseUrl}/v1/text-to-speech/${voiceId}`, {
    method: "POST",
    headers: {
      "xi-api-key": opts.apiKey,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body: JSON.stringify({ text, model_id: modelId }),
  });

  if (!res.ok) {
    throw new Error(`ElevenLabs request failed: ${res.status}`);
  }

  const buf = await res.arrayBuffer();
  if (buf.byteLength === 0) {
    throw new Error("ElevenLabs returned empty audio");
  }
  return base64FromArrayBuffer(buf);
}

// Workers-native base64 (no Node Buffer): build a binary string, then btoa.
function base64FromArrayBuffer(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}
