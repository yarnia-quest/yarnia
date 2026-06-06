import { describe, it, expect } from "vitest";
import { buildStoryPrompt, type Child } from "../src/prompt";

// Seeded child matching ideation/YARNIA.md's data model. "Lisa" is the demo child.
const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon", "owl"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder", "loud noises"],
  pastSessions: [{ summary: "A dragon who learned to share", charactersUsed: ["dragon"] }],
};

describe("buildStoryPrompt", () => {
  it("addresses the child by name and age", () => {
    const { system, user } = buildStoryPrompt(lisa, "dragon");
    expect(user).toContain("Lisa");
    expect(system).toMatch(/4[- ]year/i);
  });

  it("enforces the content-safety guardrail (age-appropriate, nonviolent)", () => {
    const { system } = buildStoryPrompt(lisa, "dragon");
    const s = system.toLowerCase();
    expect(s).toContain("age-appropriate");
    expect(s).toMatch(/no violence|nonviolent|not scary|gentle/);
  });

  it("avoids the child's known fears (safety-as-memory)", () => {
    const { system } = buildStoryPrompt(lisa, "dragon");
    expect(system.toLowerCase()).toContain("avoid");
    expect(system).toContain("thunder");
    expect(system).toContain("loud noises");
  });

  it("injects tonight's chosen character", () => {
    const { user } = buildStoryPrompt(lisa, "dragon");
    expect(user.toLowerCase()).toContain("dragon");
  });

  it("references a prior session so the story remembers the child (the moat)", () => {
    const { user } = buildStoryPrompt(lisa, "dragon");
    expect(user).toMatch(/last time|before|remember/i);
  });

  it("still produces a valid prompt for a child with no history or fears", () => {
    const blank: Child = {
      name: "Max",
      age: 6,
      favoriteCharacters: [],
      themes: [],
      fearsToAvoid: [],
      pastSessions: [],
    };
    const { system, user } = buildStoryPrompt(blank, "robot");
    expect(user).toContain("Max");
    expect(user.toLowerCase()).toContain("robot");
    expect(system).toMatch(/6[- ]year/i);
  });
});
