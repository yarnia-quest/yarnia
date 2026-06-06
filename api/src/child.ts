// Loads a child's profile + past sessions from InstantDB and maps it to the Child shape
// that buildStoryPrompt consumes. The `query` fn is injected (admin db.query in prod, a
// fake in tests) so the mapping logic is unit-testable with no network.
import type { Child, PastSession } from "./prompt";

// The admin SDK's db.query is strongly typed to the schema; loadChild only needs the
// dynamic query object, so the param is `any` (the result mapping is what we test).
export type InstantQuery = (q: any) => Promise<any>;

// messages (the full chain) is stored but intentionally NOT loaded into the recall layer.
type SessionRow = {
  title?: string;
  summary?: string;
  charactersUsed?: string[];
  continuityNotes?: string[];
  createdAt?: number;
  storyText?: string;
  audioKey?: string;
  shareToken?: string;
};

export async function loadChild(childId: string, query: InstantQuery): Promise<Child | null> {
  const res = await query({
    children: { $: { where: { id: childId } }, sessions: {} },
  });

  const row = res?.children?.[0];
  if (!row) return null;

  const pastSessions: PastSession[] = [...((row.sessions as SessionRow[]) ?? [])]
    .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0))
    .map((s) => ({
      title: s.title,
      summary: s.summary ?? "",
      charactersUsed: s.charactersUsed ?? [],
      continuityNotes: s.continuityNotes ?? [],
      createdAt: s.createdAt,
      storyText: s.storyText,
      audioKey: s.audioKey,
      shareToken: s.shareToken,
    }));

  return {
    name: row.name,
    age: row.age,
    favoriteCharacters: row.favoriteCharacters ?? [],
    themes: row.themes ?? [],
    fearsToAvoid: row.fearsToAvoid ?? [],
    pastSessions,
  };
}
