// Session write-back: after a story is told, archive it as a rich "episode" so the child's
// memory grows night over night (see ideation/ella-finn/README.md). Each session stores the
// full message chain (archive) + title + summary + characters + continuityNotes (the recall
// layer). Runs best-effort, after the response (route fires it via executionCtx.waitUntil).
import type { StoryPrompt } from "./prompt";
import type { ConversationTurn } from "./agent";

export type Message = { role: "system" | "user" | "assistant"; content: string };

export type SaveSessionInput = {
  title: string;
  summary: string;
  messages: Message[];
  charactersUsed: string[];
  continuityNotes: string[];
  storyText?: string;
  audioKey?: string;
};

// The full prompt/message chain for this session: the system + user prompt that produced
// the story, plus the story itself as the assistant turn.
export function toMessages(prompt: StoryPrompt, storyText: string): Message[] {
  return [
    { role: "system", content: prompt.system },
    { role: "user", content: prompt.user },
    { role: "assistant", content: storyText },
  ];
}

// Reuses the story generator (deps.generate) to extract the recall layer as JSON.
export function buildRecapPrompt(storyText: string): StoryPrompt {
  return {
    system:
      "You read a children's bedtime story and extract a compact memory record. " +
      "Respond with ONLY a JSON object (no markdown, no commentary) of exactly this shape:\n" +
      '{"title": "a short evocative title, 2 to 5 words", ' +
      '"summary": "one short phrase, 5 to 8 words, describing what happened", ' +
      '"characters": ["each named or notable character"], ' +
      '"continuityNotes": ["2 to 4 short facts to remember for future stories, e.g. \'they found a glowing coin\'"]}',
    user: storyText,
  };
}

export type Recap = {
  title: string;
  summary: string;
  characters: string[];
  continuityNotes: string[];
};

// Robustly parse the recap JSON. Tolerates markdown fences / surrounding prose, missing
// keys, and outright non-JSON output — always returns a usable Recap.
export function parseRecap(raw: string): Recap {
  const firstLine = raw.trim().split(/\r?\n/)[0]?.trim() || "A bedtime story";
  const fallback: Recap = {
    title: firstLine,
    summary: firstLine,
    characters: [],
    continuityNotes: [],
  };

  const match = raw.match(/\{[\s\S]*\}/);
  if (!match) return fallback;

  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(match[0]);
  } catch {
    return fallback;
  }

  const str = (v: unknown, d: string) =>
    typeof v === "string" && v.trim() ? v.trim() : d;
  const arr = (v: unknown) =>
    Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && !!x.trim()).map((x) => x.trim()) : [];

  return {
    title: str(obj.title, fallback.title),
    summary: str(obj.summary, str(obj.title, "a gentle bedtime story")),
    characters: arr(obj.characters),
    continuityNotes: arr(obj.continuityNotes),
  };
}

export type PersistDeps = {
  generate: (prompt: StoryPrompt) => Promise<string>;
  // Returns the id of the created session row, so callers can attach audio to it later.
  saveSession: (childId: string, input: SaveSessionInput) => Promise<string>;
  // Patches the recall layer (title/summary/characters/continuityNotes) onto an already-saved
  // row. Optional: when absent (some tests), recap enrichment is skipped entirely.
  updateSessionRecap?: (
    sessionId: string,
    fields: { title: string; summary: string; charactersUsed: string[]; continuityNotes: string[] },
  ) => Promise<void>;
};

// A cheap, no-LLM recap derived straight from the story text, so the session row can be
// written IMMEDIATELY (a single DB write) instead of waiting on a ~4s Qwen recap call. The
// rich recall layer is filled in asynchronously afterward by enrichSessionRecap.
export function quickRecap(text: string, choice?: string): Recap {
  const clean = text.trim().replace(/\s+/g, " ");
  const firstSentence = (clean.split(/(?<=[.!?])\s/)[0] ?? clean).trim();
  const title = (firstSentence || "A bedtime story").slice(0, 48);
  const summary = (firstSentence || "A bedtime story").slice(0, 80);
  return { title, summary, characters: choice ? [choice] : [], continuityNotes: [] };
}

// The slow part, run AFTER the row already exists: ask the LLM for the rich recall layer and
// patch it onto the row. Best-effort — if it fails the row keeps its quick recap. This is what
// makes the recap cost invisible to the "saving" spinner.
export async function enrichSessionRecap(
  sessionId: string,
  storyText: string,
  deps: PersistDeps,
  fallbackCharacter?: string,
): Promise<void> {
  if (!deps.updateSessionRecap) return;
  try {
    const recap = parseRecap(await deps.generate(buildRecapPrompt(storyText)));
    await deps.updateSessionRecap(sessionId, {
      title: recap.title,
      summary: recap.summary,
      charactersUsed: recap.characters.length
        ? recap.characters
        : fallbackCharacter
          ? [fallbackCharacter]
          : [],
      continuityNotes: recap.continuityNotes,
    });
  } catch (err) {
    console.error("recap enrichment failed (row kept its quick recap):", err);
  }
}

// /story write-back. Writes the row IMMEDIATELY with a quick recap (no LLM on the critical
// path), then enriches the recall layer. Returns the new session id.
export async function persistSession(
  childId: string,
  choice: string,
  prompt: StoryPrompt,
  storyText: string,
  deps: PersistDeps,
  audioKey?: string,
): Promise<string | null> {
  try {
    const quick = quickRecap(storyText, choice);
    const sessionId = await deps.saveSession(childId, {
      title: quick.title,
      summary: quick.summary,
      messages: toMessages(prompt, storyText),
      charactersUsed: quick.characters.length ? quick.characters : [choice],
      continuityNotes: quick.continuityNotes,
      storyText,
      audioKey,
    });
    await enrichSessionRecap(sessionId, storyText, deps, choice);
    return sessionId;
  } catch (err) {
    console.error("session write-back failed:", err);
    return null;
  }
}

// Persists an agent (ElevenLabs voice) conversation as a session, written FAST: the row is
// saved immediately with a quick (no-LLM) recap, so it shows up in history almost as soon as
// the webhook fires. The slow parts — the LLM recall-layer recap (enrichSessionRecap) and the
// mp3 narration (synthesize) — are run AFTER, in parallel, by the caller, and patched onto the
// row. Returns the new session id (so the caller can enrich + attach audio), or null if there
// was nothing to save / it failed.
export async function persistAgentSession(
  childId: string,
  transcript: ConversationTurn[],
  deps: PersistDeps,
  audioKey?: string,
): Promise<string | null> {
  try {
    const agentText = transcript
      .filter((t) => t.role === "agent" && t.message)
      .map((t) => t.message!)
      .join("\n\n");
    if (!agentText) {
      console.error("agent session write-back skipped: empty transcript");
      return null;
    }

    const quick = quickRecap(agentText);
    const messages: Message[] = transcript
      .filter((t) => t.message)
      .map((t) => ({ role: t.role === "agent" ? "assistant" : "user", content: t.message! }));

    return await deps.saveSession(childId, {
      title: quick.title,
      summary: quick.summary,
      messages,
      charactersUsed: quick.characters,
      continuityNotes: quick.continuityNotes,
      storyText: agentText,
      audioKey,
    });
  } catch (err) {
    console.error("agent session write-back failed:", err);
    return null;
  }
}

// Convenience: extract the agent's narration text from a transcript (for enrichment/audio
// after persistAgentSession has written the row).
export function agentStoryText(transcript: ConversationTurn[]): string {
  return transcript
    .filter((t) => t.role === "agent" && t.message)
    .map((t) => t.message!)
    .join("\n\n");
}
