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
  signup_ticks: {
    allow: {
      view: "true",
      create: "true",
      update: "false",
      delete: "false",
    },
  },
  // Child profiles + sessions are private: NO client access. Only the product Worker
  // (api/, @instantdb/admin token) reads/writes them, and the admin token bypasses perms.
  // If the app ever needs client reads, replace with an owner-scoped rule, not `true`.
  children: {
    allow: { view: "false", create: "false", update: "false", delete: "false" },
  },
  sessions: {
    allow: { view: "false", create: "false", update: "false", delete: "false" },
  },
} satisfies InstantRules;

export default rules;
