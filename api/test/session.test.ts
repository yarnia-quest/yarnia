import { describe, it, expect, vi } from "vitest";
import {
  buildRecapPrompt,
  parseRecap,
  toMessages,
  persistSession,
} from "../src/session";
import type { StoryPrompt } from "../src/prompt";

const prompt: StoryPrompt = { system: "SYS", user: "USR" };

describe("toMessages", () => {
  it("builds the full system/user/assistant chain", () => {
    expect(toMessages(prompt, "the story")).toEqual([
      { role: "system", content: "SYS" },
      { role: "user", content: "USR" },
      { role: "assistant", content: "the story" },
    ]);
  });
});

describe("buildRecapPrompt", () => {
  it("passes the story and asks for structured JSON with all recall fields", () => {
    const p = buildRecapPrompt("a dragon shared his stones");
    expect(p.user).toContain("a dragon shared his stones");
    expect(p.system).toMatch(/json/i);
    expect(p.system).toMatch(/title/i);
    expect(p.system).toMatch(/summary/i);
    expect(p.system).toMatch(/characters/i);
    expect(p.system).toMatch(/continuityNotes/i);
  });
});

describe("parseRecap", () => {
  it("parses a clean JSON object", () => {
    const r = parseRecap(
      '{"title":"The Sharing Dragon","summary":"a dragon who learned to share","characters":["dragon","owl"],"continuityNotes":["the dragon shared his sparkly stones"]}',
    );
    expect(r).toEqual({
      title: "The Sharing Dragon",
      summary: "a dragon who learned to share",
      characters: ["dragon", "owl"],
      continuityNotes: ["the dragon shared his sparkly stones"],
    });
  });

  it("extracts JSON even when wrapped in markdown fences or prose", () => {
    const r = parseRecap(
      'Here you go:\n```json\n{"title":"The Owl","summary":"a brave owl","characters":["owl"],"continuityNotes":["the owl found a glowing friend"]}\n```',
    );
    expect(r.title).toBe("The Owl");
    expect(r.continuityNotes).toEqual(["the owl found a glowing friend"]);
  });

  it("coerces missing keys to safe defaults", () => {
    const r = parseRecap('{"title":"Just a Title"}');
    expect(r.title).toBe("Just a Title");
    expect(r.summary).toBeTruthy();
    expect(r.characters).toEqual([]);
    expect(r.continuityNotes).toEqual([]);
  });

  it("falls back to defaults on non-JSON text", () => {
    const r = parseRecap("A gentle dragon adventure");
    expect(r.title).toBe("A gentle dragon adventure");
    expect(r.summary).toBeTruthy();
    expect(r.characters).toEqual([]);
    expect(r.continuityNotes).toEqual([]);
  });
});

describe("persistSession (write-back, best-effort)", () => {
  it("recaps the story and saves a rich session incl. continuity notes", async () => {
    const generate = vi.fn(
      async () =>
        '{"title":"The Sleepy Dragon","summary":"a dragon who learned to share","characters":["dragon"],"continuityNotes":["the dragon shared his sparkly stones with friends"]}',
    );
    const saveSession = vi.fn(async () => "sess-1");
    await persistSession("lisa-1", "dragon", prompt, "the full story text", { generate, saveSession });

    expect(saveSession).toHaveBeenCalledWith("lisa-1", {
      title: "The Sleepy Dragon",
      summary: "a dragon who learned to share",
      messages: [
        { role: "system", content: "SYS" },
        { role: "user", content: "USR" },
        { role: "assistant", content: "the full story text" },
      ],
      charactersUsed: ["dragon"],
      continuityNotes: ["the dragon shared his sparkly stones with friends"],
      storyText: "the full story text",
    });
  });

  it("falls back to the chosen character when the recap extracts none", async () => {
    const generate = vi.fn(async () => '{"title":"T","summary":"s","characters":[],"continuityNotes":[]}');
    const saveSession = vi.fn(async () => "sess-2");
    await persistSession("lisa-1", "owl", prompt, "story", { generate, saveSession });
    expect(saveSession).toHaveBeenCalledWith(
      "lisa-1",
      expect.objectContaining({ charactersUsed: ["owl"] }),
    );
  });

  it("swallows errors so it never breaks the request it runs after", async () => {
    const saveSession = vi.fn(async () => {
      throw new Error("InstantDB write failed");
    });
    await expect(
      persistSession("lisa-1", "dragon", prompt, "t", { generate: vi.fn(async () => "{}"), saveSession }),
    ).resolves.toBeUndefined();
  });
});
