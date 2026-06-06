// Session write-back: after a story is told, summarize it and persist a new session so the
// child's memory grows night over night. Runs best-effort, after the response (the route
// fires it via executionCtx.waitUntil), so it never adds latency or breaks /story.
import type { StoryPrompt } from "./prompt";

// Reuses the story generator (deps.generate) with a summarization prompt — no new client.
export function buildSummaryPrompt(storyText: string): StoryPrompt {
  return {
    system:
      "You summarize a children's bedtime story into ONE short phrase (5 to 8 words) describing what happened, like 'a gentle dragon who learned to share'. Reply with ONLY the phrase: no quotes, no trailing punctuation.",
    user: storyText,
  };
}

export type PersistDeps = {
  generate: (prompt: StoryPrompt) => Promise<string>;
  saveSession: (
    childId: string,
    input: { summary: string; charactersUsed: string[] },
  ) => Promise<void>;
};

export async function persistSession(
  childId: string,
  choice: string,
  storyText: string,
  deps: PersistDeps,
): Promise<void> {
  try {
    const summary = (await deps.generate(buildSummaryPrompt(storyText))).trim();
    await deps.saveSession(childId, { summary, charactersUsed: [choice] });
  } catch (err) {
    console.error("session write-back failed:", err);
  }
}
