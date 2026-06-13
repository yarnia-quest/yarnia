// Orchestration core for a bedtime story: load child -> build safety+memory prompt ->
// generate. Dependencies are injected so the flow is unit-testable with fakes; the route
// wires real ones (loadChild over InstantDB admin, generateStory over Nebula).
import { buildStoryPrompt, type Child, type StoryPrompt } from "./prompt";
import { isStorySafe, safeFallbackStory } from "./safety";
import { quotaState } from "./usage";

export type StoryDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  generate: (prompt: StoryPrompt) => Promise<string>;
};

export type CreateStoryResult =
  | { ok: true; text: string; prompt: StoryPrompt }
  | { ok: false; reason: "child_not_found" }
  | { ok: false; reason: "subscription_required" };

export async function createStory(
  childId: string,
  choice: string,
  deps: StoryDeps,
  language?: string,
): Promise<CreateStoryResult> {
  const child = await deps.loadChild(childId);
  if (!child) return { ok: false, reason: "child_not_found" };

  // Free tier: a few stories, then a subscription is required.
  if (!quotaState(child.pastSessions.length, child.subscribed === true).allowed) {
    return { ok: false, reason: "subscription_required" };
  }

  const prompt = buildStoryPrompt(child, choice, language);
  let text = await deps.generate(prompt);

  // Output moderation (defense in depth on top of the prompt-level guardrail). If the draft
  // trips the safety check, regenerate once with a reinforced instruction, then fall back to a
  // guaranteed-safe story. A kids product must never narrate unsafe content.
  if (!isStorySafe(text)) {
    const stricter: StoryPrompt = {
      system:
        prompt.system +
        " Absolutely no violence, weapons, blood, death, frightening imagery, profanity, or any " +
        "other content unsuitable for a young child. Keep it gentle, warm, and soothing.",
      user: prompt.user,
    };
    text = await deps.generate(stricter);
    if (!isStorySafe(text)) text = safeFallbackStory(child.name);
  }

  return { ok: true, text, prompt };
}
