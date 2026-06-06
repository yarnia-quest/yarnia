// Pure prompt assembly for the bedtime story. No I/O, no API calls — kept pure so the
// demo-critical logic (content-safety guardrail + per-child memory) is fully testable.
// Data model follows ideation/YARNIA.md.

export type PastSession = {
  summary: string;
  charactersUsed: string[];
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
  const { name, age, fearsToAvoid, pastSessions } = child;

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
  if (pastSessions.length > 0) {
    const last = pastSessions[pastSessions.length - 1];
    userParts.push(
      `Remember ${name} from before: last time the story was "${last.summary}" (featuring ${last.charactersUsed.join(", ")}). Acknowledge that you remember, and keep continuity without repeating it.`,
    );
  }

  return { system, user: userParts.join(" ") };
}
