// Orchestration core for a bedtime story: load child -> build safety+memory prompt ->
// generate. Dependencies are injected so the flow is unit-testable with fakes; the route
// wires real ones (loadChild over InstantDB admin, generateStory over Qwen).
import { buildStoryPrompt, type Child, type StoryPrompt } from "./prompt";

export type StoryDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  generate: (prompt: StoryPrompt) => Promise<string>;
  synthesize: (text: string) => Promise<string>;
};

export type CreateStoryResult =
  | { ok: true; text: string; audio: string | null; prompt: StoryPrompt }
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

  // Narration is an enhancement: if TTS fails (e.g. ElevenLabs quota/auth), the story
  // still returns with audio:null rather than failing the whole request.
  let audio: string | null = null;
  try {
    audio = await deps.synthesize(text);
  } catch (err) {
    console.error("synthesize failed, returning story without audio:", err);
  }

  return { ok: true, text, audio, prompt };
}
