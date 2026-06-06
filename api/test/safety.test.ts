import { describe, it, expect, vi } from "vitest";
import { isStorySafe, safeFallbackStory } from "../src/safety";
import { createStory } from "../src/story";

describe("isStorySafe (output moderation)", () => {
  it("passes a gentle bedtime story", () => {
    expect(isStorySafe("The little owl and the cat shared warm cocoa and drifted to sleep.")).toBe(true);
  });
  it("flags violence / gore", () => {
    expect(isStorySafe("He grabbed the knife and stabbed him; there was blood everywhere.")).toBe(false);
  });
  it("flags profanity", () => {
    expect(isStorySafe("What the fuck is happening here")).toBe(false);
  });
  it("safeFallbackStory is itself safe and names the child", () => {
    const s = safeFallbackStory("Lisa");
    expect(isStorySafe(s)).toBe(true);
    expect(s).toContain("Lisa");
  });
});

const child = { name: "Lisa", age: 4, favoriteCharacters: [], themes: [], fearsToAvoid: [], pastSessions: [] };
const deps = (generate: (p: unknown) => Promise<string>) => ({
  loadChild: async () => child,
  generate,
  synthesize: async () => "AUDIO",
});

describe("createStory content-safety flow", () => {
  it("regenerates once when the first draft is unsafe and returns the safe retry", async () => {
    const generate = vi
      .fn()
      .mockResolvedValueOnce("He stabbed the villain and there was blood everywhere.")
      .mockResolvedValueOnce("The owl and the cat shared cocoa and fell asleep.");
    const r = await createStory("c", "a dragon", deps(generate));
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.text).toContain("cocoa");
    expect(generate).toHaveBeenCalledTimes(2);
  });

  it("falls back to a safe story when the retry is still unsafe", async () => {
    const generate = vi.fn().mockResolvedValue("blood and a knife and gore");
    const r = await createStory("c", "x", deps(generate));
    expect(r.ok).toBe(true);
    if (r.ok) expect(isStorySafe(r.text)).toBe(true);
  });

  it("leaves a safe first draft untouched (no extra generate call)", async () => {
    const generate = vi.fn().mockResolvedValue("A cozy story about a sleepy fox under the stars.");
    const r = await createStory("c", "a fox", deps(generate));
    expect(generate).toHaveBeenCalledTimes(1);
    if (r.ok) expect(r.text).toContain("fox");
  });
});
