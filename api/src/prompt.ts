// Pure prompt assembly for the bedtime story. No I/O, no API calls — kept pure so the
// demo-critical logic (content-safety guardrail + per-child memory) is fully testable.
// Data model follows ideation/YARNIA.md.

// The light recall layer loaded into prompts (NOT the full message archive — that stays
// in InstantDB and is not injected, to keep prompts small). See ideation/ella-finn/README.md.
export type PastSession = {
  title?: string;
  summary: string;
  charactersUsed: string[];
  continuityNotes?: string[];
  createdAt?: number;
};

export type Child = {
  name: string;
  age: number;
  favoriteCharacters: string[];
  themes: string[];
  fearsToAvoid: string[];
  pastSessions: PastSession[];
};

export type StoryPrompt = {
  system: string;
  user: string;
};

// The content-safety guardrail + memory injection. system = the constraints Yarnia must
// always honor; user = tonight's specific ask (child, chosen character, what to remember).
export function buildStoryPrompt(child: Child, choice: string): StoryPrompt {
  const { name, age, themes, fearsToAvoid, pastSessions } = child;

  const safety = [
    `You are Yarnia, a warm, calm bedtime storyteller for a ${age}-year-old child named ${name}.`,
    `Every story must be strictly age-appropriate for a ${age}-year-old: gentle, soothing, and nonviolent.`,
    `No violence, no peril, no scary or startling moments. The tone winds the child DOWN toward sleep.`,
  ];
  if (fearsToAvoid.length > 0) {
    safety.push(
      `This child has specific fears. You MUST avoid these entirely: ${fearsToAvoid.join(", ")}.`,
    );
  }
  const system = safety.join(" ");

  const userParts = [
    `Tell ${name} a short bedtime story.`,
    `Tonight ${name} chose this to be in the story: ${choice}.`,
  ];
  if (themes.length > 0) {
    // Themes are the child's gentle preferences (e.g. friendship, courage). Soft steer,
    // not a mandate — the chosen character above still leads the story.
    userParts.push(
      `${name} especially loves stories about ${themes.join(", ")}; gently lean that way if it fits naturally.`,
    );
  }
  if (pastSessions.length > 0) {
    // Recall layer: list the few most recent episodes (newest last) as notes the model
    // MAY draw on. Framed as optional so both modes work — serial callbacks when they
    // fit naturally (Ella-Finn style), or a fresh standalone story otherwise. We do not
    // force continuity; forcing it makes every story feel like a recap.
    const recent = pastSessions.slice(-MAX_RECALL_NOTES);
    const notes = recent.map(formatRecallNote).join(" ");
    userParts.push(
      `Notes from ${name}'s recent bedtime stories (most recent last): ${notes}`,
      `You MAY gently weave in a familiar character or a small callback if it feels natural and soothing, but a fresh standalone story is equally welcome. Never force a reference and never retell a past story.`,
    );
  }

  return { system, user: userParts.join(" ") };
}

// How many recent episodes to surface in the prompt. Keeps prompts small; the full
// archive stays in InstantDB.
const MAX_RECALL_NOTES = 3;

// One episode rendered as a short recall note, e.g. '"Sharing Stones": A dragon who
// learned to share (dragon) [the dragon shared his sparkly stones]'. Title, characters,
// and continuity facts are all optional; the facts make any callback specific.
function formatRecallNote(s: PastSession): string {
  const title = s.title ? `"${s.title}": ` : "";
  const characters = s.charactersUsed.length > 0 ? ` (${s.charactersUsed.join(", ")})` : "";
  const facts = s.continuityNotes?.length ? ` [${s.continuityNotes.join("; ")}]` : "";
  return `- ${title}${s.summary}${characters}${facts}`;
}
