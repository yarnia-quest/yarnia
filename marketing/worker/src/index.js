// Yarnia signup Worker — receives {email} from the landing page and writes it to InstantDB.
// The admin token is read from env (Cloudflare secret), never hardcoded.
// Docs: https://www.instantdb.com/docs/backend  |  https://developers.cloudflare.com/workers/
import { init, lookup } from "@instantdb/admin";

// CORS: open by default; set ALLOWED_ORIGINS (comma-separated) to lock it to e.g. https://yarnia.quest
function corsHeaders(origin, env) {
  const allow = (env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const allowOrigin = allow.length === 0 ? origin || "*" : origin && allow.includes(origin) ? origin : allow[0];
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    Vary: "Origin",
  };
}

const json = (obj, status, headers) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json", ...headers } });

export default {
  async fetch(request, env) {
    const cors = corsHeaders(request.headers.get("Origin"), env);
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

    let email = "";
    try {
      const body = await request.json();
      email = String(body.email || "").trim().toLowerCase();
    } catch {
      return json({ error: "bad request" }, 400, cors);
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "invalid email" }, 422, cors);

    const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
    try {
      // Upsert by the unique `email` attribute so duplicate signups don't error.
      await db.transact([
        db.tx.signups[lookup("email", email)].update({ email, createdAt: Date.now(), source: "landing" }),
      ]);
    } catch (err) {
      return json({ error: "store failed" }, 500, cors);
    }
    return json({ ok: true }, 200, cors);
  },
};
