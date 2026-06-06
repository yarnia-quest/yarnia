import { describe, it, expect } from "vitest";
import app from "../src/index";

// LIVE: drives the real POST /story route end-to-end (InstantDB admin + Qwen) against
// seeded Lisa. Env is passed as Hono bindings (app.request's 3rd arg). Skipped without keys.
// Run: `npm run test:integration`.
const LISA = "11111111-1111-4111-8111-111111111111";
const env = {
  INSTANT_APP_ID: process.env.INSTANT_APP_ID ?? "",
  INSTANT_ADMIN_TOKEN: process.env.INSTANT_ADMIN_TOKEN ?? "",
  QWEN_API_KEY: process.env.QWEN_API_KEY ?? "",
};
const ready = !!(env.INSTANT_APP_ID && env.INSTANT_ADMIN_TOKEN && env.QWEN_API_KEY);

function post(body: unknown) {
  return app.request(
    "/story",
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
    env,
  );
}

describe.skipIf(!ready)("POST /story — LIVE (InstantDB + Qwen)", () => {
  it("returns a memory-aware story for seeded Lisa", async () => {
    const res = await post({ childId: LISA, choice: "dragon" });
    expect(res.status).toBe(200);
    const json = (await res.json()) as { status: string; text: string; audio: string };
    expect(json.status).toBe("ok");
    expect(json.text.length).toBeGreaterThan(50);
    // Story text always returns. Audio is best-effort: a data URI when ElevenLabs serves
    // us, or null when it does not (e.g. free-tier disabled). Both are valid; warn on null.
    if (json.audio === null) {
      console.warn("\n[!] audio is null — ElevenLabs did not return narration (check the key/tier).\n");
    } else {
      expect(json.audio).toMatch(/^data:audio\/mpeg;base64,/);
      expect(json.audio.length).toBeGreaterThan(1000);
    }
    console.log("\n----- POST /story live -----\ntext:", json.text.slice(0, 160));
    console.log("audio:", json.audio ? `${json.audio.length} base64 chars` : "null", "\n");
  });

  it("404s for an unknown child", async () => {
    const res = await post({ childId: "00000000-0000-4000-8000-000000000000" });
    expect(res.status).toBe(404);
  });
});
