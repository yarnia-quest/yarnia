// Generates the dubbed voice clips for the REAL-APP demo (out/yarnia-realapp-demo.mp4).
//
// Playwright video has no audio, so the live session's speech is dubbed in afterward. The
// real capture only had the greeting; this adds the child asking for a story and Yarnia
// telling it, so the demo shows the whole loop: greeting -> child's request -> bedtime story.
//
// Voices match the product: Yarnia = Clara (the live agent + /story narration); the child
// uses the same children's-character voice as the Remotion recreation. The greeting text is
// the exact line the live agent spoke (see capture marks.json) so the dub matches what shipped.
//
// Run: node video/scripts/gen-realapp-audio.mjs   (reads ELEVENLABS_API_KEY from api/.env)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..", ".."); // repo root
const publicDir = resolve(here, "..", "public");

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

// The dubbed turns, in order. The greeting is the exact live-agent line from the capture;
// the child answers its "shall we find a cozy story?" and Yarnia tells a short, calm story.
const SCRIPT = [
  { id: "realapp-greeting", speaker: "yarnia", text: "Welcome to Yarnia, Mira, where your stories untangle. I'm so glad you're here. Shall we find a cozy story for tonight?" },
  { id: "realapp-kid", speaker: "kid", text: "Yes! Can you tell me a story about a brave little fox?" },
  { id: "realapp-story", speaker: "yarnia", text: "Of course, Mira. One quiet evening, a brave little fox tiptoed across a meadow of silver moonflowers, following a trail of sleepy fireflies all the way home. The fox curled up in the warm, soft grass, watching the slow, twinkling stars. And slowly... softly... it closed its eyes. Goodnight, Mira." },
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
  return { audioBase64: data.audio_base64, duration };
}

mkdirSync(publicDir, { recursive: true });
for (const line of SCRIPT) {
  const voice = line.speaker === "yarnia" ? CLARA : KID;
  const { audioBase64, duration } = await tts(line.text, voice);
  writeFileSync(resolve(publicDir, `${line.id}.mp3`), Buffer.from(audioBase64, "base64"));
  console.log(`${line.id.padEnd(18)} ${duration.toFixed(2)}s  "${line.text.slice(0, 50)}..."`);
}
console.log("\nDone. Clips in video/public/. Mux per video/README.md 'Real-app capture'.");
