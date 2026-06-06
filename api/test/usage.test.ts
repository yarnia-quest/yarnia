import { describe, it, expect } from "vitest";
import { estimateStoryCost, quotaState, FREE_STORY_LIMIT } from "../src/usage";

describe("estimateStoryCost", () => {
  it("includes TTS cost only when narrated", () => {
    const text = "a".repeat(4000);
    const withAudio = estimateStoryCost(text, true);
    const noAudio = estimateStoryCost(text, false);
    expect(withAudio.tokens).toBe(1000);
    expect(noAudio.ttsUsd).toBe(0);
    expect(withAudio.ttsUsd).toBeGreaterThan(0);
    expect(withAudio.totalUsd).toBeGreaterThan(noAudio.totalUsd);
  });

  it("scales with length", () => {
    const small = estimateStoryCost("a".repeat(400), true);
    const big = estimateStoryCost("a".repeat(8000), true);
    expect(big.totalUsd).toBeGreaterThan(small.totalUsd);
  });
});

describe("quotaState", () => {
  it("allows up to the free limit, then requires a subscription", () => {
    expect(quotaState(0, false).allowed).toBe(true);
    expect(quotaState(FREE_STORY_LIMIT - 1, false).allowed).toBe(true);
    const blocked = quotaState(FREE_STORY_LIMIT, false);
    expect(blocked.allowed).toBe(false);
    expect(blocked.requiresSubscription).toBe(true);
    expect(blocked.remaining).toBe(0);
  });

  it("is unlimited for subscribers", () => {
    const s = quotaState(9999, true);
    expect(s.allowed).toBe(true);
    expect(s.requiresSubscription).toBe(false);
  });
});
