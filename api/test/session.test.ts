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
  it("passes the story and asks for a Title + Summary", () => {
    const p = buildRecapPrompt("a dragon shared his stones");
    expect(p.user).toContain("a dragon shared his stones");
    expect(p.system).toMatch(/Title:/);
    expect(p.system).toMatch(/Summary:/);
  });
});

describe("parseRecap", () => {
  it("extracts title and summary from the two-line format", () => {
    expect(parseRecap("Title: The Sleepy Dragon\nSummary: a dragon who learned to share")).toEqual({
      title: "The Sleepy Dragon",
      summary: "a dragon who learned to share",
    });
  });

  it("strips surrounding quotes", () => {
    expect(parseRecap('Title: "The Owl"\nSummary: "a brave owl"')).toEqual({
      title: "The Owl",
      summary: "a brave owl",
    });
  });

  it("falls back when only a summary is present", () => {
    const r = parseRecap("Summary: a quiet night");
    expect(r.summary).toBe("a quiet night");
    expect(r.title).toBe("a quiet night");
  });

  it("falls back to sensible defaults on unformatted text", () => {
    const r = parseRecap("A gentle dragon adventure");
    expect(r.title).toBe("A gentle dragon adventure");
    expect(r.summary).toBe("A gentle dragon adventure");
  });
});

describe("persistSession (write-back, best-effort)", () => {
  it("recaps tonight's story and saves a rich session for the child", async () => {
    const generate = vi.fn(async () => "Title: The Sleepy Dragon\nSummary: a dragon who learned to share");
    const saveSession = vi.fn(async () => {});
    await persistSession("lisa-1", "dragon", prompt, "the full story text", { generate, saveSession });

    expect(generate).toHaveBeenCalledOnce();
    expect(saveSession).toHaveBeenCalledWith("lisa-1", {
      title: "The Sleepy Dragon",
      summary: "a dragon who learned to share",
      messages: [
        { role: "system", content: "SYS" },
        { role: "user", content: "USR" },
        { role: "assistant", content: "the full story text" },
      ],
      charactersUsed: ["dragon"],
    });
  });

  it("swallows errors so it never breaks the request it runs after", async () => {
    const saveSession = vi.fn(async () => {
      throw new Error("InstantDB write failed");
    });
    await expect(
      persistSession("lisa-1", "dragon", prompt, "t", { generate: vi.fn(async () => "x"), saveSession }),
    ).resolves.toBeUndefined();
  });
});
