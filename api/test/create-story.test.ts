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
  it("loads child, builds prompt, generates, returns text + prompt", async () => {
    const loadChild = vi.fn(async () => lisa);
    const generate = vi.fn(async () => "Once upon a time, Lisa...");

    const res = await createStory("lisa-1", "dragon", { loadChild, generate });

    expect(loadChild).toHaveBeenCalledWith("lisa-1");
    const prompt = generate.mock.calls[0][0] as StoryPrompt;
    expect(prompt.system).toContain("thunder"); // safety from the child's fears
    expect(prompt.user.toLowerCase()).toContain("dragon"); // tonight's choice
    expect(res).toMatchObject({ ok: true, text: "Once upon a time, Lisa..." });
    if (res.ok) expect(res.prompt.system).toContain("Lisa"); // prompt returned for write-back
  });

  it("returns child_not_found and never generates when child is missing", async () => {
    const generate = vi.fn();
    const res = await createStory("nope", "dragon", {
      loadChild: vi.fn(async () => null),
      generate,
    });
    expect(res).toEqual({ ok: false, reason: "child_not_found" });
    expect(generate).not.toHaveBeenCalled();
  });
});
