// Session write-back: after a story is told, archive it as a rich "episode" so the child's
// memory grows night over night (see ideation/ELLA-FINN-EXAMPLE.md). Each session stores the
// full message chain (archive) + a title + summary (the light recall layer). Runs best-effort,
// after the response (route fires it via executionCtx.waitUntil), so it adds no latency.
import type { StoryPrompt } from "./prompt";

export type Message = { role: "system" | "user" | "assistant"; content: string };

export type SaveSessionInput = {
  title: string;
  summary: string;
  messages: Message[];
  charactersUsed: string[];
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

// Reuses the story generator (deps.generate) to recap tonight's story into a title + summary.
export function buildRecapPrompt(storyText: string): StoryPrompt {
  return {
    system:
      "You read a children's bedtime story and recap it. Respond in EXACTLY this format, two lines:\n" +
      "Title: <a short evocative title, 2 to 5 words>\n" +
      "Summary: <one short phrase, 5 to 8 words, describing what happened>\n" +
      "No quotes, no extra commentary.",
    user: storyText,
  };
}

// Robustly parse the recap. Falls back gracefully if the model deviates from the format.
export function parseRecap(raw: string): { title: string; summary: string } {
  const strip = (s: string) => s.trim().replace(/^["']|["']$/g, "");
  const title = raw.match(/Title:\s*(.+)/i)?.[1];
  const summary = raw.match(/Summary:\s*(.+)/i)?.[1];
  const firstLine = raw.trim().split(/\r?\n/)[0]?.replace(/^(Title|Summary):\s*/i, "");
  const t = title ? strip(title) : "";
  const s = summary ? strip(summary) : "";
  const fallback = firstLine ? strip(firstLine) : "";
  return {
    title: t || s || fallback || "A bedtime story",
    summary: s || fallback || "a gentle bedtime story",
  };
}

export type PersistDeps = {
  generate: (prompt: StoryPrompt) => Promise<string>;
  saveSession: (childId: string, input: SaveSessionInput) => Promise<void>;
};

export async function persistSession(
  childId: string,
  choice: string,
  prompt: StoryPrompt,
  storyText: string,
  deps: PersistDeps,
): Promise<void> {
  try {
    const { title, summary } = parseRecap(await deps.generate(buildRecapPrompt(storyText)));
    await deps.saveSession(childId, {
      title,
      summary,
      messages: toMessages(prompt, storyText),
      charactersUsed: [choice],
    });
  } catch (err) {
    console.error("session write-back failed:", err);
  }
}
