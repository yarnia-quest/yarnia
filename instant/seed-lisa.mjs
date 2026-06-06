// Seeds the demo child "Lisa" with 3 prior sessions ("episodes"), so the live demo opens
// with the memory moment. Each session stores the full message chain + a title + summary,
// matching the richer model (see ideation/ELLA-FINN-EXAMPLE.md). Idempotent: fixed ids +
// .update() upsert. "Lisa" is fictional demo data, not a real child.
//
// Run:  node instant/seed-lisa.mjs            (upsert the 3 curated sessions)
//       node instant/seed-lisa.mjs --reset    (first DELETE all of Lisa's sessions —
//                                               incl. ones written back by /story — then seed,
//                                               for a pristine demo state)
import { init } from "@instantdb/admin";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const env = {};
for (const line of readFileSync(resolve(here, "..", "api", ".env"), "utf8").split(/\r?\n/)) {
  if (line.trimStart().startsWith("#")) continue;
  const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
  if (m) env[m[1]] = m[2];
}

const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
const reset = process.argv.includes("--reset");

const LISA = "11111111-1111-4111-8111-111111111111";
const S1 = "22222222-2222-4222-8222-222222222221";
const S2 = "22222222-2222-4222-8222-222222222222";
const S3 = "22222222-2222-4222-8222-222222222223";

// Three nights, oldest -> newest (last is the most recent the next story will reference).
const NIGHT = 86_400_000;
const T3 = 1_749_000_000_000;
const T2 = T3 - NIGHT;
const T1 = T3 - 2 * NIGHT;

// Build a full message chain (the archive) for a seeded story.
const chain = (userAsk, story) => [
  { role: "system", content: "You are Yarnia, a warm bedtime storyteller for 4-year-old Lisa. Calm, gentle, nonviolent; avoid thunder and loud noises." },
  { role: "user", content: userAsk },
  { role: "assistant", content: story },
];

const SESSIONS = [
  {
    id: S1,
    createdAt: T1,
    title: "The Glowing Owl",
    summary: "An owl who was afraid of the dark and found a softly glowing friend",
    charactersUsed: ["Pip the owl", "a firefly"],
    continuityNotes: ["Pip the owl was shy of the dark", "a tiny firefly became Pip's glowing friend"],
    messages: chain(
      "Tell Lisa a gentle story about an owl.",
      "Once there was a small owl named Pip who felt shy of the dark. Then a tiny firefly drifted close and glowed like a warm nightlight. Together they watched the quiet stars until Pip's eyes grew heavy and soft.",
    ),
  },
  {
    id: S2,
    createdAt: T2,
    title: "The Blanket Fort",
    summary: "A dragon and an owl built a cozy blanket fort under the stars",
    charactersUsed: ["the gentle dragon", "Pip the owl"],
    continuityNotes: ["the dragon and Pip built a cozy blanket fort", "they watched the stars together before sleep"],
    messages: chain(
      "Tell Lisa a calm story with a dragon and an owl.",
      "A gentle dragon and the little owl Pip gathered the softest blankets they could find. They built a warm, cozy fort and peeked out at the slow, twinkling stars. Snug and sleepy, they whispered goodnight.",
    ),
  },
  {
    id: S3,
    createdAt: T3,
    title: "The Sharing Dragon",
    summary: "A gentle dragon who learned to share his sparkly stones",
    charactersUsed: ["the gentle dragon"],
    continuityNotes: ["the dragon shared his sparkly stones with his forest friends", "sharing made the dragon feel calm and happy"],
    messages: chain(
      "Tell Lisa a soothing story about a dragon.",
      "A gentle dragon kept a little pile of sparkly stones. When his forest friends admired them, he learned how warm it felt to share. He gave one to each friend, then curled up, calm and happy, ready to sleep.",
    ),
  },
];

if (reset) {
  const res = await db.query({ children: { $: { where: { id: LISA } }, sessions: {} } });
  const existing = res.children[0]?.sessions ?? [];
  if (existing.length) {
    await db.transact(existing.map((s) => db.tx.sessions[s.id].delete()));
    console.log(`--reset: deleted ${existing.length} existing session(s) for Lisa`);
  }
}

await db.transact([
  db.tx.children[LISA].update({
    name: "Lisa",
    age: 4,
    favoriteCharacters: ["dragon", "owl"],
    themes: ["friendship", "kindness"],
    fearsToAvoid: ["thunder", "loud noises"],
    createdAt: T1,
  }),
  ...SESSIONS.map((s) =>
    db.tx.sessions[s.id]
      .update({
        title: s.title,
        summary: s.summary,
        messages: s.messages,
        charactersUsed: s.charactersUsed,
        continuityNotes: s.continuityNotes,
        createdAt: s.createdAt,
      })
      .link({ child: LISA }),
  ),
]);

console.log(`seeded child Lisa (${LISA}) with ${SESSIONS.length} sessions`);
