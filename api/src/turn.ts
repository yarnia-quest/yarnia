// Turn interpreter for the conversational story engine.
// Parses the LLM's JSON response for POST /story/turn into a typed TurnDecision.
// No I/O — pure parser so it is fully testable.

export type TurnDecision = {
  intent: "continue" | "answer" | "revise";
  say?: string;                                              // short spoken line before resuming
  revision?: { fromSentence: number; sentences: string[] }; // present iff intent === "revise"
  resumeAt: number;                                          // sentence index to resume from
};

const VALID_INTENTS = new Set(["continue", "answer", "revise"]);

// Tolerant parse: strips ``` fences / leading prose, JSON.parses, validates shape.
// On any failure, logs a warning and returns a safe default: { intent: "continue", resumeAt: cursor }.
export function interpretTurn(raw: string, cursor: number, storyLength: number): TurnDecision {
  const safe: TurnDecision = { intent: "continue", resumeAt: cursor };

  let cleaned = raw.trim();

  // Strip ``` fences (with or without language tag).
  cleaned = cleaned.replace(/^```[a-z]*\s*/i, "").replace(/\s*```\s*$/, "").trim();

  // Strip leading prose before the first '{'.
  const braceIdx = cleaned.indexOf("{");
  if (braceIdx > 0) {
    cleaned = cleaned.slice(braceIdx);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned);
  } catch (err) {
    console.warn(`interpretTurn: failed to parse JSON response: ${err}. Raw: ${raw.slice(0, 200)}`);
    return safe;
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    console.warn(`interpretTurn: expected a JSON object, got: ${typeof parsed}`);
    return safe;
  }

  const obj = parsed as Record<string, unknown>;
  const intent = obj.intent;

  if (typeof intent !== "string" || !VALID_INTENTS.has(intent)) {
    console.warn(`interpretTurn: unknown intent "${intent}", falling back to continue`);
    return safe;
  }

  const validIntent = intent as TurnDecision["intent"];
  const say = typeof obj.say === "string" && obj.say.length > 0 ? obj.say : undefined;

  // Validate and clamp resumeAt.
  let resumeAt: number = cursor;
  if (typeof obj.resumeAt === "number" && obj.resumeAt >= 0 && obj.resumeAt <= storyLength) {
    resumeAt = Math.floor(obj.resumeAt);
  }

  // Validate revision for revise intent.
  if (validIntent === "revise") {
    const rev = obj.revision;
    if (
      typeof rev !== "object" ||
      rev === null ||
      !Array.isArray((rev as Record<string, unknown>).sentences) ||
      ((rev as Record<string, unknown>).sentences as unknown[]).length === 0
    ) {
      console.warn("interpretTurn: revise intent missing valid revision.sentences, falling back to continue");
      return { intent: "continue", resumeAt: cursor };
    }

    const revObj = rev as Record<string, unknown>;
    let fromSentence = typeof revObj.fromSentence === "number" ? Math.floor(revObj.fromSentence) : cursor;
    // Clamp fromSentence to [0, storyLength].
    fromSentence = Math.max(0, Math.min(storyLength, fromSentence));

    const sentences = (revObj.sentences as unknown[])
      .filter((s): s is string => typeof s === "string")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);

    if (sentences.length === 0) {
      console.warn("interpretTurn: revise.sentences all empty after filtering, falling back to continue");
      return { intent: "continue", resumeAt: cursor };
    }

    // For revise, resumeAt defaults to fromSentence if not specified.
    const revResumeAt =
      typeof obj.resumeAt === "number" && obj.resumeAt >= 0 && obj.resumeAt <= storyLength
        ? Math.floor(obj.resumeAt)
        : fromSentence;

    return {
      intent: "revise",
      say,
      revision: { fromSentence, sentences },
      resumeAt: revResumeAt,
    };
  }

  return { intent: validIntent, say, resumeAt };
}
