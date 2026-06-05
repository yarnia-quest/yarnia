// Permissions. The signup Worker writes with the admin token (which bypasses perms),
// so clients get NO access to signups (emails are not publicly readable/writable).
// Docs: https://www.instantdb.com/docs/permissions
import type { InstantRules } from "@instantdb/core";

const rules = {
  signups: {
    allow: {
      view: "false",
      create: "false",
      update: "false",
      delete: "false",
    },
  },
} satisfies InstantRules;

export default rules;
