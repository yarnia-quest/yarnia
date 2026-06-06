// Generates every audio clip for the Yarnia demo video, plus a manifest with exact
// durations (so the Remotion timeline can sync frames to audio with no guesswork).
//
// We use ElevenLabs' /with-timestamps TTS endpoint: it returns the mp3 AND per-character
// timings, so we get the precise clip length (last character end time) for free — no ffprobe.
//
// Yarnia speaks in Clara (the same voice as the live agent + /story narration) so the demo
// matches the product. The child uses a children's-character voice.
//
// Run: node video/scripts/gen-audio.mjs   (reads ELEVENLABS_API_KEY from api/.env)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", ".."); // repo root
const publicDir = resolve(here, "..", "public");
const manifestPath = resolve(here, "..", "src", "yarnia", "manifest.json");

// Read the API key from the backend env (single source of truth, gitignored).
const env = {};
for (const line of readFileSync(resolve(root, "api", ".env"), "utf8").split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
  if (m && !line.trimStart().startsWith("#")) env[m[1]] = m[2];
}
const KEY = env.ELEVENLABS_API_KEY;
if (!KEY) throw new Error("ELEVENLABS_API_KEY missing from api/.env");

const CLARA = "Qggl4b0xRMiqOwhPtVWT"; // Yarnia (matches the live agent + /story)
const KID = "NbvR1eY6Q8ivACdEO8PV"; // children's character voice
const MODEL = "eleven_multilingual_v2";

// The scripted ~60s conversation. A returning child, so it shows the memory moment
// ("I remember our story about...") and a calm auto-sleep ending.
const SCRIPT = [
  { id: "yarnia-1", speaker: "yarnia", text: "Welcome back to Yarnia, Mira. I remember our story about the little fox who found the moonlit pond. Shall we see where the fox wanders tonight?" },
  { id: "kid-1", speaker: "kid", text: "Yes! The little fox again!" },
  { id: "yarnia-2", speaker: "yarnia", text: "Wonderful. Tonight, the little fox followed a trail of soft, silver starlight, deep into the quiet forest, where the trees whispered gentle goodnights." },
  { id: "kid-2", speaker: "kid", text: "Mmm. So cozy." },
  { id: "yarnia-3", speaker: "yarnia", text: "The fox curled up in the warm, mossy grass, watching the slow, twinkling stars. And slowly... softly... it closed its eyes. Good night, Mira." },
  { id: "kid-3", speaker: "kid", text: "Night night." },
];

async function tts(text, voiceId) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}/with-timestamps`,
    {
      method: "POST",
      headers: { "xi-api-key": KEY, "content-type": "application/json" },
      body: JSON.stringify({ text, model_id: MODEL }),
    },
  );
  if (!res.ok) throw new Error(`TTS failed ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const data = await res.json();
  const ends = data.alignment?.character_end_times_seconds ?? [];
  const duration = ends.length ? ends[ends.length - 1] : 0;
  return { audioBase64: data.audio_base64, duration, alignment: data.alignment };
}

mkdirSync(publicDir, { recursive: true });
const manifest = [];
for (const line of SCRIPT) {
  const voice = line.speaker === "yarnia" ? CLARA : KID;
  const { audioBase64, duration, alignment } = await tts(line.text, voice);
  writeFileSync(resolve(publicDir, `${line.id}.mp3`), Buffer.from(audioBase64, "base64"));
  manifest.push({ id: line.id, speaker: line.speaker, text: line.text, durationInSeconds: duration, alignment });
  console.log(`${line.id.padEnd(10)} ${duration.toFixed(2)}s  "${line.text.slice(0, 50)}..."`);
}
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
console.log(`\nWrote ${manifest.length} clips + manifest. Total speech: ${manifest.reduce((s, m) => s + m.durationInSeconds, 0).toFixed(1)}s`);
