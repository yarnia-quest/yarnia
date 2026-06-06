// Per-child auth tokens. A childId alone used to be a bearer credential (anyone who learned
// an id could read that child's history or generate stories on the owner's quota). Now each
// child gets an unguessable token at creation; only its SHA-256 hash is stored, and child-
// scoped routes require the matching token. Children with no stored hash (created before this
// existed) are treated as legacy and allowed, so nothing breaks for existing profiles.

// 256 bits of randomness, hex-encoded — the secret handed to the client once at onboarding.
export function generateChildToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// SHA-256 hex of the token. Only the hash is persisted, so a DB leak never reveals tokens.
export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time-ish comparison of two equal-length hex strings (both are our own SHA-256 hex).
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// True when the presented token authorizes access to the child.
// - storedHash null/undefined (legacy child): allowed (backward compatible).
// - storedHash present: requires a token whose hash matches.
export async function verifyChildToken(
  storedHash: string | null | undefined,
  presentedToken: string | null | undefined,
): Promise<boolean> {
  if (!storedHash) return true; // legacy child, no token set
  if (!presentedToken) return false;
  return safeEqual(storedHash, await hashToken(presentedToken));
}
