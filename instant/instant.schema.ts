// InstantDB schema (shared app: Marketing waitlist now, product later).
// Push: `npx instant-cli@latest push schema --app <INSTANT_APP_ID> --token <per_…>` (CI does this).
// Docs: https://www.instantdb.com/docs/modeling-data
import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    signups: i.entity({
      email: i.string().unique().indexed(),
      createdAt: i.number(),
      source: i.string().optional(),
    }),
  },
  links: {},
  rooms: {},
});

type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;
export type { AppSchema };
export default schema;
