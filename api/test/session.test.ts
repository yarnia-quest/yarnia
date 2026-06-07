import { describe, it, expect, vi } from "vitest";
import {
  buildRecapPrompt,
  parseRecap,
  toMessages,
  persistSession,
  persistAgentSession,
  enrichSessionRecap,
  quickRecap,
  agentStoryText,
} from "../src/session";
import type { StoryPrompt } from "../src/prompt";

const prompt: StoryPrompt = { system: "SYS", user: "USR" };

describe("quickRecap (no-LLM, instant)", () => {
  it("derives a title/summary from the first sentence and uses the choice as the character", () => {
    const r = quickRecap("Mira and the fox crossed the river. Then they slept.", "a fox");
    expect(r.title).toBe("Mira and the fox crossed the river.");
    expect(r.summary).toBe("Mira and the fox crossed the river.");
    expect(r.characters).toEqual(["a fox"]);
    expect(r.continuityNotes).toEqual([]);
  });

  it("caps long titles and tolerates empty text", () => {
    expect(quickRecap("x".repeat(200)).title.length).toBeLessThanOrEqual(48);
    expect(quickRecap("").title).toBe("A bedtime story");
  });
});

describe("persistAgentSession (fast write, no LLM on the critical path)", () => {
  it("writes the row from the transcript WITHOUT calling the LLM, returning the id", async () => {
    const generate = vi.fn(async () => "should-not-be-called");
    const saveSession = vi.fn(async () => "sess-A");
    const transcript = [
      { role: "user" as const, message: "tell me about an owl" },
      { role: "agent" as const, message: "Once there was an owl. She loved the moon." },
    ];
    const id = await persistAgentSession("lisa-1", transcript, { generate, saveSession });
    expect(id).toBe("sess-A");
    expect(generate).not.toHaveBeenCalled(); // recap is off the critical path now
    expect(saveSession).toHaveBeenCalledWith(
      "lisa-1",
      expect.objectContaining({
        title: "Once there was an owl.",
        storyText: "Once there was an owl. She loved the moon.",
        charactersUsed: [],
        messages: [
          { role: "user", content: "tell me about an owl" },
          { role: "assistant", content: "Once there was an owl. She loved the moon." },
        ],
      }),
    );
  });

  it("returns null for an empty transcript", async () => {
    const saveSession = vi.fn(async () => "x");
    const id = await persistAgentSession("lisa-1", [{ role: "user", message: "hi" }], {
      generate: vi.fn(),
      saveSession,
    });
    expect(id).toBeNull();
    expect(saveSession).not.toHaveBeenCalled();
  });
});

describe("agentStoryText", () => {
  it("joins only the agent turns", () => {
    expect(
      agentStoryText([
        { role: "user", message: "hi" },
        { role: "agent", message: "part one" },
        { role: "agent", message: "part two" },
      ]),
    ).toBe("part one\n\npart two");
  });
});

describe("enrichSessionRecap", () => {
  it("runs the LLM recap and patches it onto the row", async () => {
    const generate = vi.fn(async () => '{"title":"The Owl","summary":"an owl and the moon","characters":["owl"],"continuityNotes":["owl loves the moon"]}');
    const updateSessionRecap = vi.fn(async () => {});
    await enrichSessionRecap("sess-A", "the story", { generate, saveSession: vi.fn(), updateSessionRecap });
    expect(updateSessionRecap).toHaveBeenCalledWith("sess-A", {
      title: "The Owl",
      summary: "an owl and the moon",
      charactersUsed: ["owl"],
      continuityNotes: ["owl loves the moon"],
    });
  });

  it("is a no-op when no update sink is provided", async () => {
    const generate = vi.fn(async () => "{}");
    await enrichSessionRecap("sess-A", "t", { generate, saveSession: vi.fn() });
    expect(generate).not.toHaveBeenCalled();
  });
});

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

describe("persistSession (fast write + async enrich)", () => {
  it("writes the row IMMEDIATELY with a quick (no-LLM) recap, then enriches the recall layer", async () => {
    const generate = vi.fn(
      async () =>
        '{"title":"The Sleepy Dragon","summary":"a dragon who learned to share","characters":["dragon"],"continuityNotes":["the dragon shared his sparkly stones with friends"]}',
    );
    const saveSession = vi.fn(async () => "sess-1");
    const updateSessionRecap = vi.fn(async () => {});
    const callOrder: string[] = [];
    saveSession.mockImplementation(async () => {
      callOrder.push("save");
      return "sess-1";
    });
    generate.mockImplementation(async () => {
      callOrder.push("generate");
      return '{"title":"The Sleepy Dragon","summary":"a dragon who learned to share","characters":["dragon"],"continuityNotes":["the dragon shared his sparkly stones with friends"]}';
    });

    const id = await persistSession("lisa-1", "dragon", prompt, "Lisa met a dragon. It was kind.", {
      generate,
      saveSession,
      updateSessionRecap,
    });

    expect(id).toBe("sess-1");
    // The row is saved BEFORE any LLM call (recap is off the critical path).
    expect(callOrder[0]).toBe("save");
    // The immediate write carries a quick recap derived from the text (no LLM), with the
    // chosen character as the fallback, plus the full message chain + story text.
    expect(saveSession).toHaveBeenCalledWith("lisa-1", {
      title: "Lisa met a dragon.",
      summary: "Lisa met a dragon.",
      messages: [
        { role: "system", content: "SYS" },
        { role: "user", content: "USR" },
        { role: "assistant", content: "Lisa met a dragon. It was kind." },
      ],
      charactersUsed: ["dragon"],
      continuityNotes: [],
      storyText: "Lisa met a dragon. It was kind.",
    });
    // The rich recap is patched onto the saved row afterward.
    expect(updateSessionRecap).toHaveBeenCalledWith("sess-1", {
      title: "The Sleepy Dragon",
      summary: "a dragon who learned to share",
      charactersUsed: ["dragon"],
      continuityNotes: ["the dragon shared his sparkly stones with friends"],
    });
  });

  it("enrichment falls back to the chosen character when the recap extracts none", async () => {
    const generate = vi.fn(async () => '{"title":"T","summary":"s","characters":[],"continuityNotes":[]}');
    const saveSession = vi.fn(async () => "sess-2");
    const updateSessionRecap = vi.fn(async () => {});
    await persistSession("lisa-1", "owl", prompt, "story", { generate, saveSession, updateSessionRecap });
    expect(updateSessionRecap).toHaveBeenCalledWith(
      "sess-2",
      expect.objectContaining({ charactersUsed: ["owl"] }),
    );
  });

  it("skips the LLM entirely when no recap-update sink is wired (still writes the row fast)", async () => {
    const generate = vi.fn(async () => "{}");
    const saveSession = vi.fn(async () => "sess-3");
    const id = await persistSession("lisa-1", "owl", prompt, "story", { generate, saveSession });
    expect(id).toBe("sess-3");
    expect(saveSession).toHaveBeenCalledOnce();
    expect(generate).not.toHaveBeenCalled(); // no enrichment sink -> no LLM cost
  });

  it("swallows errors so it never breaks the request it runs after", async () => {
    const saveSession = vi.fn(async () => {
      throw new Error("InstantDB write failed");
    });
    await expect(
      persistSession("lisa-1", "dragon", prompt, "t", { generate: vi.fn(async () => "{}"), saveSession }),
    ).resolves.toBeNull();
  });
});
