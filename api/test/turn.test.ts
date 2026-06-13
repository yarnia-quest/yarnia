import { describe, it, expect, vi } from "vitest";
import { interpretTurn, type TurnDecision } from "../src/turn";

describe("interpretTurn — continue intent", () => {
  it("parses a clean continue response", () => {
    const raw = JSON.stringify({ intent: "continue", resumeAt: 3 });
    const result = interpretTurn(raw, 3, 10);
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(3);
  });

  it("defaults resumeAt to cursor when omitted", () => {
    const raw = JSON.stringify({ intent: "continue" });
    const result = interpretTurn(raw, 5, 10);
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(5);
  });

  it("clamps out-of-range resumeAt to cursor", () => {
    const raw = JSON.stringify({ intent: "continue", resumeAt: 999 });
    const result = interpretTurn(raw, 4, 10);
    expect(result.resumeAt).toBe(4);
  });
});

describe("interpretTurn — answer intent", () => {
  it("parses a clean answer response with say text", () => {
    const raw = JSON.stringify({ intent: "answer", say: "His name is Emilio!", resumeAt: 3 });
    const result = interpretTurn(raw, 3, 10);
    expect(result.intent).toBe("answer");
    expect(result.say).toBe("His name is Emilio!");
    expect(result.resumeAt).toBe(3);
  });

  it("allows answer without say", () => {
    const raw = JSON.stringify({ intent: "answer", resumeAt: 2 });
    const result = interpretTurn(raw, 2, 10);
    expect(result.intent).toBe("answer");
    expect(result.say).toBeUndefined();
  });
});

describe("interpretTurn — revise intent", () => {
  it("parses a clean revise response", () => {
    const raw = JSON.stringify({
      intent: "revise",
      say: "Okay, let me change that.",
      revision: { fromSentence: 2, sentences: ["The dragon was now green.", "He smiled happily."] },
      resumeAt: 2,
    });
    const result = interpretTurn(raw, 5, 10);
    expect(result.intent).toBe("revise");
    expect(result.revision?.fromSentence).toBe(2);
    expect(result.revision?.sentences).toHaveLength(2);
    expect(result.resumeAt).toBe(2);
  });

  it("clamps fromSentence that exceeds storyLength to storyLength", () => {
    const raw = JSON.stringify({
      intent: "revise",
      revision: { fromSentence: 999, sentences: ["A new ending."] },
      resumeAt: 999,
    });
    const result = interpretTurn(raw, 3, 10);
    expect(result.revision?.fromSentence).toBeLessThanOrEqual(10);
  });

  it("clamps negative fromSentence to 0", () => {
    const raw = JSON.stringify({
      intent: "revise",
      revision: { fromSentence: -5, sentences: ["Start fresh."] },
      resumeAt: 0,
    });
    const result = interpretTurn(raw, 3, 10);
    expect(result.revision?.fromSentence).toBe(0);
  });

  it("coerces revise with empty sentences to continue", () => {
    const raw = JSON.stringify({
      intent: "revise",
      revision: { fromSentence: 2, sentences: [] },
      resumeAt: 2,
    });
    const result = interpretTurn(raw, 3, 10);
    // Empty sentences array is invalid; fall back to continue.
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(3);
  });

  it("coerces revise with missing revision field to continue", () => {
    const raw = JSON.stringify({ intent: "revise", resumeAt: 2 });
    const result = interpretTurn(raw, 3, 10);
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(3);
  });
});

describe("interpretTurn — fence stripping", () => {
  it("strips ```json fences before parsing", () => {
    const raw = "```json\n" + JSON.stringify({ intent: "continue", resumeAt: 1 }) + "\n```";
    const result = interpretTurn(raw, 1, 10);
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(1);
  });

  it("strips ``` fences (no language tag) before parsing", () => {
    const raw = "```\n" + JSON.stringify({ intent: "continue", resumeAt: 0 }) + "\n```";
    const result = interpretTurn(raw, 0, 5);
    expect(result.intent).toBe("continue");
  });

  it("strips leading prose before the JSON object", () => {
    const raw = "Sure, here is the JSON:\n" + JSON.stringify({ intent: "continue", resumeAt: 2 });
    const result = interpretTurn(raw, 2, 10);
    expect(result.intent).toBe("continue");
    expect(result.resumeAt).toBe(2);
  });
});

describe("interpretTurn — malformed input", () => {
  it("returns safe default for malformed JSON and logs a warning", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const result = interpretTurn("this is not json at all", 3, 10);
    expect(result).toEqual({ intent: "continue", resumeAt: 3 });
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  it("returns safe default for unknown intent and logs a warning", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const raw = JSON.stringify({ intent: "dance", resumeAt: 2 });
    const result = interpretTurn(raw, 2, 10);
    expect(result).toEqual({ intent: "continue", resumeAt: 2 });
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
});
