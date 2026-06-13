import { describe, it, expect } from "vitest";
import { buildStoryPrompt, buildTurnPrompt, type Child } from "../src/prompt";

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

  it("gently steers toward the child's themes when set", () => {
    const { user } = buildStoryPrompt(lisa, "dragon");
    // Lisa's theme is "friendship" — it should surface as a soft preference for the story.
    expect(user.toLowerCase()).toContain("friendship");
  });

  it("omits theme guidance entirely when no themes are set", () => {
    const noThemes: Child = { ...lisa, themes: [] };
    const { user } = buildStoryPrompt(noThemes, "dragon");
    expect(user.toLowerCase()).not.toContain("theme");
  });

  it("injects recent episode notes as optional context, not forced continuity (the moat)", () => {
    const { user } = buildStoryPrompt(lisa, "dragon");
    // The past story surfaces as a recall note the model can use...
    expect(user).toContain("A dragon who learned to share");
    // ...but framed as optional ("may gently weave in"), so a standalone story is
    // equally valid. We deliberately do NOT force the old "acknowledge that you
    // remember / keep continuity" instruction.
    expect(user).toMatch(/may|gently|if it (feels|fits)|standalone/i);
    expect(user.toLowerCase()).not.toContain("acknowledge that you remember");
  });

  it("surfaces stored continuity facts so callbacks can be specific", () => {
    const withNotes: Child = {
      ...lisa,
      pastSessions: [
        {
          title: "Sharing Stones",
          summary: "A dragon who learned to share",
          charactersUsed: ["dragon"],
          continuityNotes: ["the dragon shared his sparkly stones"],
        },
      ],
    };
    const { user } = buildStoryPrompt(withNotes, "dragon");
    expect(user).toContain("the dragon shared his sparkly stones");
  });

  it("includes several recent episodes (titles + characters) when history exists", () => {
    const multi: Child = {
      ...lisa,
      pastSessions: [
        { title: "Sharing Stones", summary: "A dragon who learned to share", charactersUsed: ["dragon"] },
        { title: "The Quiet Owl", summary: "An owl who found a calm tree", charactersUsed: ["owl"] },
      ],
    };
    const { user } = buildStoryPrompt(multi, "dragon");
    expect(user).toContain("A dragon who learned to share");
    expect(user).toContain("An owl who found a calm tree");
    expect(user).toContain("Sharing Stones");
  });

  it("caps injected notes to the most recent few to keep the prompt small", () => {
    const many: Child = {
      ...lisa,
      pastSessions: Array.from({ length: 8 }, (_, i) => ({
        summary: `Story number ${i}`,
        charactersUsed: ["dragon"],
      })),
    };
    const { user } = buildStoryPrompt(many, "dragon");
    // The newest are kept; the oldest are dropped.
    expect(user).toContain("Story number 7");
    expect(user).not.toContain("Story number 0");
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

// ── buildTurnPrompt ──────────────────────────────────────────────────────────

describe("buildTurnPrompt", () => {
  const sentences = [
    "Once upon a time there was a dragon.",
    "The dragon loved to fly.",
    "One day the dragon met a rabbit.",
    "They became the best of friends.",
  ];

  it("includes numbered sentences in the system prompt", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 2, "make the dragon green");
    expect(system).toContain("0: Once upon a time");
    expect(system).toContain("1: The dragon loved to fly");
    expect(system).toContain("2: One day the dragon");
    expect(system).toContain("3: They became the best");
  });

  it("includes the current cursor position line", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 2, "make the dragon green");
    expect(system).toMatch(/paused right after sentence 1/i);
    expect(system).toMatch(/about to read sentence 2/i);
  });

  it("includes the JSON contract with all three intent examples", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 2, "what is his name?");
    expect(system).toContain("continue");
    expect(system).toContain("answer");
    expect(system).toContain("revise");
    expect(system).toMatch(/\{.*intent/s);
  });

  it("puts the utterance in the user message", () => {
    const { user } = buildTurnPrompt(lisa, sentences, 2, "make the dragon fly faster");
    expect(user).toContain("make the dragon fly faster");
    expect(user).toMatch(/child just said/i);
  });

  it("includes the German language instruction when language is 'de'", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 1, "mach den Drachen grün", "de");
    expect(system.toLowerCase()).toContain("german");
  });

  it("does not include a language instruction for English (default)", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 1, "make the dragon green");
    expect(system.toLowerCase()).not.toContain("english");
  });

  it("includes the safety preamble from buildStoryPrompt", () => {
    const { system } = buildTurnPrompt(lisa, sentences, 1, "what happens next");
    expect(system.toLowerCase()).toContain("age-appropriate");
    expect(system).toContain("thunder"); // fears
  });
});
