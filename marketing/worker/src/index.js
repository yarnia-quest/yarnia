// Yarnia signup Worker — receives {email} from the landing page and writes it to InstantDB.
// The admin token is read from env (set as a Cloudflare secret), never hardcoded.
import { init, lookup } from "@instantdb/admin";

const corsHeaders = (origin) => ({
  "Access-Control-Allow-Origin": origin || "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
});

const json = (obj, status, origin) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(origin) },
  });

export default {
  async fetch(request, env) {
    const origin = request.headers.get("Origin");
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders(origin) });
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405, origin);

    let email = "";
    try {
      const body = await request.json();
      email = String(body.email || "").trim().toLowerCase();
    } catch {
      return json({ error: "bad request" }, 400, origin);
    }

    // Basic email shape check (defense in depth; the form also validates).
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json({ error: "invalid email" }, 422, origin);
    }

    const db = init({ appId: env.INSTANT_APP_ID, adminToken: env.INSTANT_ADMIN_TOKEN });
    try {
      // Upsert by email (email is a unique attr) so duplicate signups don't error.
      await db.transact(
        db.tx.signups[lookup("email", email)].update({
          email,
          createdAt: Date.now(),
          source: "landing",
        })
      );
    } catch (err) {
      return json({ error: "store failed" }, 500, origin);
    }
    return json({ ok: true }, 200, origin);
  },
};
