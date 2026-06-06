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
};

export async function persistSession(
  childId: string,
  choice: string,
  prompt: StoryPrompt,
  storyText: string,
  deps: PersistDeps,
  audioKey?: string,
): Promise<void> {
  try {
    const recap = parseRecap(await deps.generate(buildRecapPrompt(storyText)));
    await deps.saveSession(childId, {
      title: recap.title,
      summary: recap.summary,
      messages: toMessages(prompt, storyText),
      charactersUsed: recap.characters.length ? recap.characters : [choice],
      continuityNotes: recap.continuityNotes,
      storyText,
      audioKey,
    });
  } catch (err) {
    console.error("session write-back failed:", err);
  }
}

// Persists an agent (ElevenLabs voice) conversation as a session. The transcript
// is already available from the ElevenLabs API; we extract the agent's story turns,
// run the same recap pass as the /story flow, and save to InstantDB.
// Returns the new session id (so the caller can attach audio afterward), or null if there
// was nothing to save / it failed. Audio is intentionally NOT done here: the row is written
// fast (recap + DB write) and the slow mp3 synthesis is attached separately, so a story shows
// up in history quickly instead of waiting on TTS.
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

    const recap = parseRecap(await deps.generate(buildRecapPrompt(agentText)));
    const messages: Message[] = transcript
      .filter((t) => t.message)
      .map((t) => ({ role: t.role === "agent" ? "assistant" : "user", content: t.message! }));

    return await deps.saveSession(childId, {
      title: recap.title,
      summary: recap.summary,
      messages,
      charactersUsed: recap.characters,
      continuityNotes: recap.continuityNotes,
      storyText: agentText,
      audioKey,
    });
  } catch (err) {
    console.error("agent session write-back failed:", err);
    return null;
  }
}
