// Permissions for signups: anyone (guest) may CREATE a waitlist row, but nobody can
// view/update/delete via the client. So the marketing page writes directly with the
// public app id (no admin token), and emails stay private. Admin token only used by schema CI.
// Docs: https://www.instantdb.com/docs/permissions
import type { InstantRules } from "@instantdb/core";

const rules = {
  signups: {
    allow: {
      view: "false",
      create: "true",
      update: "false",
      delete: "false",
    },
  },
} satisfies InstantRules;

export default rules;
