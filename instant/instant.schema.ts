// InstantDB schema (shared app: Marketing waitlist + the Yarnia product).
// Push: `npx instant-cli@latest push schema --app <INSTANT_APP_ID> --token <admin>` (CI does this).
// Docs: https://www.instantdb.com/docs/modeling-data
import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    // Instant Storage auto-creates $files on db.storage.uploadFile (story narration mp3s).
    // Required in the schema to query file urls. Created only via uploadFile, never transact;
    // url is read-only. See https://www.instantdb.com/docs/storage
    $files: i.entity({
      path: i.string().unique().indexed(),
      url: i.string(),
    }),
    signups: i.entity({
      email: i.string().unique().indexed(),
      createdAt: i.number(),
      source: i.string().optional(),
    }),
    // Public counter — no PII. One record per signup, viewable by anyone.
    // The marketing page creates one tick per signup (same transaction), and reads
    // the length to show the live waitlist count without exposing email addresses.
    signup_ticks: i.entity({
      at: i.number().indexed(),
    }),
    // A child profile — the per-child memory that powers personalized, safe stories.
    children: i.entity({
      name: i.string(),
      age: i.number(),
      favoriteCharacters: i.json(),
      themes: i.json(),
      fearsToAvoid: i.json(),
      createdAt: i.number(),
    }),
    // One bedtime session (an "episode"). Stores the full message chain (the archive,
    // for re-reading / continuing) plus a title + summary (the light recall layer that
    // gets injected into future prompts). See ideation/ELLA-FINN-EXAMPLE.md.
    sessions: i.entity({
      title: i.string().optional(),
      summary: i.string(),
      messages: i.json().optional(), // full prompt/message chain: [{ role, content }, ...]
      charactersUsed: i.json(),
      continuityNotes: i.json().optional(), // carry-forward facts for future episodes
      storyText: i.string().optional(), // full narration text, for re-reading
      audioKey: i.string().optional(), // $files path of the narration mp3 (replay via GET /audio/:key)
      createdAt: i.number().indexed(),
    }),
  },
  links: {
    // A child has many sessions; each session belongs to one child.
    childSessions: {
      forward: { on: "sessions", has: "one", label: "child" },
      reverse: { on: "children", has: "many", label: "sessions" },
    },
  },
  rooms: {},
});

type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;
export type { AppSchema };
export default schema;
