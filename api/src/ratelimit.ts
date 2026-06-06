// Lightweight in-isolate rate limiter (fixed-window). Cloudflare Workers isolates are
// ephemeral and there can be several, so this is best-effort defense-in-depth that throttles
// bursts from a single source; durable enforcement should also use Cloudflare's account-level
// Rate Limiting rules on the api.yarnia.quest route (see infra/README.md). Pure and testable:
// the clock is injectable.

type Hit = { count: number; resetAt: number };

export type RateLimiter = {
  check: (key: string) => { allowed: boolean; remaining: number; retryAfterMs: number };
};

export function createRateLimiter(opts: {
  limit: number;
  windowMs: number;
  now?: () => number;
}): RateLimiter {
  const now = opts.now ?? Date.now;
  const buckets = new Map<string, Hit>();

  return {
    check(key: string) {
      const t = now();
      const existing = buckets.get(key);
      if (!existing || t >= existing.resetAt) {
        buckets.set(key, { count: 1, resetAt: t + opts.windowMs });
        return { allowed: true, remaining: opts.limit - 1, retryAfterMs: 0 };
      }
      if (existing.count >= opts.limit) {
        return { allowed: false, remaining: 0, retryAfterMs: existing.resetAt - t };
      }
      existing.count += 1;
      return { allowed: true, remaining: opts.limit - existing.count, retryAfterMs: 0 };
    },
  };
}
