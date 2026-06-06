import { describe, it, expect } from "vitest";
import { parseSignatureHeader, verifyWebhookSignature } from "../src/webhook";

const SECRET = "whsec_test_secret";

// Produce a genuine ElevenLabs-style signature so we verify against the real HMAC, not a
// reimplementation of our own code.
async function sign(body: string, timestamp: number, secret = SECRET): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `t=${timestamp},v0=${hex}`;
}

describe("parseSignatureHeader", () => {
  it("parses t and v0 in any order", () => {
    expect(parseSignatureHeader("t=1700000000,v0=abcd")).toEqual({ timestamp: 1700000000, v0: "abcd" });
    expect(parseSignatureHeader("v0=abcd,t=1700000000")).toEqual({ timestamp: 1700000000, v0: "abcd" });
  });

  it("returns null for missing parts or junk", () => {
    expect(parseSignatureHeader("")).toBeNull();
    expect(parseSignatureHeader(null)).toBeNull();
    expect(parseSignatureHeader("t=1700000000")).toBeNull(); // no v0
    expect(parseSignatureHeader("v0=abcd")).toBeNull(); // no t
    expect(parseSignatureHeader("t=notanumber,v0=abcd")).toBeNull();
  });
});

describe("verifyWebhookSignature", () => {
  const body = JSON.stringify({ type: "post_call_transcription", data: { conversation_id: "c1" } });
  const ts = 1_700_000_000;

  it("accepts a valid, fresh signature", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body, header, SECRET, { nowSecs: ts })).toBe(true);
  });

  it("rejects a tampered body", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body + "x", header, SECRET, { nowSecs: ts })).toBe(false);
  });

  it("rejects a wrong secret", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body, header, "whsec_other", { nowSecs: ts })).toBe(false);
  });

  it("rejects a stale timestamp (replay outside the window)", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body, header, SECRET, { nowSecs: ts + 31 * 60 })).toBe(false);
  });

  it("accepts within the freshness window", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body, header, SECRET, { nowSecs: ts + 5 * 60 })).toBe(true);
  });

  it("rejects when there is no secret or no header", async () => {
    const header = await sign(body, ts);
    expect(await verifyWebhookSignature(body, header, "", { nowSecs: ts })).toBe(false);
    expect(await verifyWebhookSignature(body, null, SECRET, { nowSecs: ts })).toBe(false);
  });
});
