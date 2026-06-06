import { describe, it, expect, vi } from "vitest";
import { buildSummaryPrompt, persistSession } from "../src/session";

describe("buildSummaryPrompt", () => {
  it("passes the story as the user content and asks for one short phrase", () => {
    const p = buildSummaryPrompt("Once upon a time, a dragon shared his stones.");
    expect(p.user).toContain("a dragon shared his stones");
    expect(p.system.toLowerCase()).toContain("phrase");
  });
});

describe("persistSession (write-back, best-effort)", () => {
  it("summarizes tonight's story and saves a session for the child", async () => {
    const generate = vi.fn(async () => "  a gentle dragon who learned to share  ");
    const saveSession = vi.fn(async () => {});
    await persistSession("lisa-1", "dragon", "the full story text", { generate, saveSession });

    expect(generate).toHaveBeenCalledOnce();
    expect(saveSession).toHaveBeenCalledWith("lisa-1", {
      summary: "a gentle dragon who learned to share", // trimmed
      charactersUsed: ["dragon"],
    });
  });

  it("swallows errors so it never breaks the request it runs after", async () => {
    const saveSession = vi.fn(async () => {
      throw new Error("InstantDB write failed");
    });
    await expect(
      persistSession("lisa-1", "dragon", "t", { generate: vi.fn(async () => "x"), saveSession }),
    ).resolves.toBeUndefined();
  });
});
