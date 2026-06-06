import { describe, it, expect } from "vitest";
import { buildStoryPrompt, type Child } from "../src/prompt";
import { generateStory } from "../src/generate";

// LIVE test: calls the real Qwen API. Skipped unless QWEN_API_KEY is set (loaded from
// api/.env by test/setup.integration.ts). Run: `npm run test:integration`.
const apiKey = process.env.QWEN_API_KEY;

const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon", "owl"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder", "loud noises"],
  pastSessions: [{ summary: "A dragon who learned to share", charactersUsed: ["dragon"] }],
};

describe.skipIf(!apiKey)("generateStory — LIVE Qwen call", () => {
  it("returns a real bedtime story for Lisa", async () => {
    const prompt = buildStoryPrompt(lisa, "dragon");
    const text = await generateStory(prompt, { apiKey: apiKey! });
    expect(typeof text).toBe("string");
    expect(text.length).toBeGreaterThan(50);
    // Surface a snippet so we can eyeball tone + that the memory/safety prompt landed.
    console.log("\n----- Qwen story (first 400 chars) -----\n" + text.slice(0, 400) + "\n----------------------------------------\n");
  });
});
