// Orchestration core for a bedtime story: load child -> build safety+memory prompt ->
// generate. Dependencies are injected so the flow is unit-testable with fakes; the route
// wires real ones (loadChild over InstantDB admin, generateStory over Qwen).
import { buildStoryPrompt, type Child, type StoryPrompt } from "./prompt";

export type StoryDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  generate: (prompt: StoryPrompt) => Promise<string>;
};

export type CreateStoryResult =
  | { ok: true; text: string }
  | { ok: false; reason: "child_not_found" };

export async function createStory(
  childId: string,
  choice: string,
  deps: StoryDeps,
): Promise<CreateStoryResult> {
  const child = await deps.loadChild(childId);
  if (!child) return { ok: false, reason: "child_not_found" };

  const prompt = buildStoryPrompt(child, choice);
  const text = await deps.generate(prompt);
  return { ok: true, text };
}
