// Verifies ElevenLabs post-call webhook signatures (HMAC-SHA256). ElevenLabs signs each
// webhook and sends an `ElevenLabs-Signature: t=<unix_secs>,v0=<hex>` header, where the
// signed payload is `${t}.${rawBody}`. We recompute it with the shared secret and compare in
// constant time, and reject stale timestamps to block replay. Pure + injectable clock so the
// route stays a thin wrapper and this logic is unit-testable with no network.
// Docs: https://elevenlabs.io/docs/eleven-agents/workflows/post-call-webhooks

export type SignatureParts = { timestamp: number; v0: string };

// Parses "t=1700000000,v0=abc123" (order-independent) into its parts. Returns null if either
// component is missing or the timestamp isn't a number.
export function parseSignatureHeader(header: string | null | undefined): SignatureParts | null {
  if (!header) return null;
  let timestamp: number | undefined;
  let v0: string | undefined;
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2);
    if (k?.trim() === "t" && v !== undefined) timestamp = Number(v.trim());
    if (k?.trim() === "v0" && v !== undefined) v0 = v.trim();
  }
  if (timestamp === undefined || Number.isNaN(timestamp) || !v0) return null;
  return { timestamp, v0 };
}

// Lowercase hex of an ArrayBuffer.
function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time string compare (avoids leaking match progress via timing).
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type VerifyOpts = {
  // Current unix time in SECONDS (injected so tests are deterministic). Defaults to now.
  nowSecs?: number;
  // Reject signatures whose timestamp is older/newer than this many seconds (replay window).
  toleranceSecs?: number;
};

// True iff the header is present, well-formed, within the freshness window, and the HMAC of
// `${t}.${rawBody}` under `secret` matches v0. Any failure -> false (never throws).
export async function verifyWebhookSignature(
  rawBody: string,
  header: string | null | undefined,
  secret: string,
  opts: VerifyOpts = {},
): Promise<boolean> {
  if (!secret) return false;
  const parsed = parseSignatureHeader(header);
  if (!parsed) return false;

  const nowSecs = opts.nowSecs ?? Math.floor(Date.now() / 1000);
  const tolerance = opts.toleranceSecs ?? 30 * 60; // 30 minutes, per ElevenLabs guidance
  if (Math.abs(nowSecs - parsed.timestamp) > tolerance) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${parsed.timestamp}.${rawBody}`),
  );
  return timingSafeEqual(toHex(mac), parsed.v0.toLowerCase());
}
