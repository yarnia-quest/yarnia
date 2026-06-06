import { describe, it, expect } from "vitest";
import { createRateLimiter } from "../src/ratelimit";

describe("createRateLimiter (fixed window)", () => {
  it("allows up to the limit, then blocks within the window", () => {
    let t = 1000;
    const rl = createRateLimiter({ limit: 3, windowMs: 1000, now: () => t });
    expect(rl.check("ip").allowed).toBe(true);
    expect(rl.check("ip").allowed).toBe(true);
    expect(rl.check("ip").allowed).toBe(true);
    const blocked = rl.check("ip");
    expect(blocked.allowed).toBe(false);
    expect(blocked.retryAfterMs).toBeGreaterThan(0);
  });

  it("resets after the window elapses", () => {
    let t = 0;
    const rl = createRateLimiter({ limit: 1, windowMs: 100, now: () => t });
    expect(rl.check("k").allowed).toBe(true);
    expect(rl.check("k").allowed).toBe(false);
    t = 101;
    expect(rl.check("k").allowed).toBe(true);
  });

  it("tracks keys independently", () => {
    let t = 0;
    const rl = createRateLimiter({ limit: 1, windowMs: 100, now: () => t });
    expect(rl.check("a").allowed).toBe(true);
    expect(rl.check("b").allowed).toBe(true);
    expect(rl.check("a").allowed).toBe(false);
  });
});
