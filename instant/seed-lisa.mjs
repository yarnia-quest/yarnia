// Seeds the demo child "Lisa" with 3 prior sessions, so the live demo opens with the
// memory moment ("I remember the dragon who learned to share..."). Idempotent: fixed ids
// + .update() upsert, so re-running just refreshes the same rows.
//
// Run: `node instant/seed-lisa.mjs` (reads INSTANT_APP_ID + INSTANT_ADMIN_TOKEN from api/.env).
// "Lisa" is fictional demo data, not a real child.
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

// Fixed UUIDs so re-seeding is idempotent.
const LISA = "11111111-1111-4111-8111-111111111111";
const S1 = "22222222-2222-4222-8222-222222222221";
const S2 = "22222222-2222-4222-8222-222222222222";
const S3 = "22222222-2222-4222-8222-222222222223";

// Three nights, oldest -> newest (last is the most recent the story will reference).
const NIGHT = 86_400_000;
const T3 = 1_749_000_000_000;
const T2 = T3 - NIGHT;
const T1 = T3 - 2 * NIGHT;

await db.transact([
  db.tx.children[LISA].update({
    name: "Lisa",
    age: 4,
    favoriteCharacters: ["dragon", "owl"],
    themes: ["friendship", "kindness"],
    fearsToAvoid: ["thunder", "loud noises"],
    createdAt: T1,
  }),
  db.tx.sessions[S1]
    .update({
      summary: "An owl who was afraid of the dark and found a softly glowing friend",
      charactersUsed: ["owl"],
      createdAt: T1,
    })
    .link({ child: LISA }),
  db.tx.sessions[S2]
    .update({
      summary: "A dragon and an owl built a cozy blanket fort under the stars",
      charactersUsed: ["dragon", "owl"],
      createdAt: T2,
    })
    .link({ child: LISA }),
  db.tx.sessions[S3]
    .update({
      summary: "A gentle dragon who learned to share his sparkly stones",
      charactersUsed: ["dragon"],
      createdAt: T3,
    })
    .link({ child: LISA }),
]);

console.log(`seeded child Lisa (${LISA}) with 3 sessions`);
