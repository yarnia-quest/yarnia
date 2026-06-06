import { describe, it, expect, vi } from "vitest";
import { createStory } from "../src/story";
import type { Child, StoryPrompt } from "../src/prompt";

const lisa: Child = {
  name: "Lisa",
  age: 4,
  favoriteCharacters: ["dragon"],
  themes: ["friendship"],
  fearsToAvoid: ["thunder"],
  pastSessions: [{ summary: "a dragon who shared", charactersUsed: ["dragon"] }],
};

describe("createStory (orchestration)", () => {
  it("loads child, builds prompt, generates, synthesizes, returns text + audio", async () => {
    const loadChild = vi.fn(async () => lisa);
    const generate = vi.fn(async () => "Once upon a time, Lisa...");
    const synthesize = vi.fn(async () => "BASE64AUDIO");

    const res = await createStory("lisa-1", "dragon", { loadChild, generate, synthesize });

    expect(loadChild).toHaveBeenCalledWith("lisa-1");
    const prompt = generate.mock.calls[0][0] as StoryPrompt;
    expect(prompt.system).toContain("thunder"); // safety from the child's fears
    expect(prompt.user.toLowerCase()).toContain("dragon"); // tonight's choice
    expect(synthesize).toHaveBeenCalledWith("Once upon a time, Lisa..."); // narrate the story text
    expect(res).toMatchObject({ ok: true, text: "Once upon a time, Lisa...", audio: "BASE64AUDIO" });
    if (res.ok) expect(res.prompt.system).toContain("Lisa"); // prompt returned for write-back
  });

  it("degrades to audio:null (story still succeeds) when synthesis fails", async () => {
    const res = await createStory("lisa-1", "dragon", {
      loadChild: vi.fn(async () => lisa),
      generate: vi.fn(async () => "A calm story."),
      synthesize: vi.fn(async () => {
        throw new Error("ElevenLabs request failed: 401");
      }),
    });
    expect(res).toMatchObject({ ok: true, text: "A calm story.", audio: null });
  });

  it("returns child_not_found and never generates or synthesizes when child is missing", async () => {
    const generate = vi.fn();
    const synthesize = vi.fn();
    const res = await createStory("nope", "dragon", {
      loadChild: vi.fn(async () => null),
      generate,
      synthesize,
    });
    expect(res).toEqual({ ok: false, reason: "child_not_found" });
    expect(generate).not.toHaveBeenCalled();
    expect(synthesize).not.toHaveBeenCalled();
  });
});
