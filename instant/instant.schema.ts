// InstantDB schema (shared app: Marketing waitlist + the Yarnia product).
// Push: `npx instant-cli@latest push schema --app <INSTANT_APP_ID> --token <admin>` (CI does this).
// Docs: https://www.instantdb.com/docs/modeling-data
import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    signups: i.entity({
      email: i.string().unique().indexed(),
      createdAt: i.number(),
      source: i.string().optional(),
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
