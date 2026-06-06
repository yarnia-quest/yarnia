// Loads a child's profile + past sessions from InstantDB and maps it to the Child shape
// that buildStoryPrompt consumes. The `query` fn is injected (admin db.query in prod, a
// fake in tests) so the mapping logic is unit-testable with no network.
import type { Child, PastSession } from "./prompt";

export type InstantQuery = (q: unknown) => Promise<any>;

type SessionRow = { summary?: string; charactersUsed?: string[]; createdAt?: number };

export async function loadChild(childId: string, query: InstantQuery): Promise<Child | null> {
  const res = await query({
    children: { $: { where: { id: childId } }, sessions: {} },
  });

  const row = res?.children?.[0];
  if (!row) return null;

  const pastSessions: PastSession[] = [...((row.sessions as SessionRow[]) ?? [])]
    .sort((a, b) => (a.createdAt ?? 0) - (b.createdAt ?? 0))
    .map((s) => ({ summary: s.summary ?? "", charactersUsed: s.charactersUsed ?? [] }));

  return {
    name: row.name,
    age: row.age,
    favoriteCharacters: row.favoriteCharacters ?? [],
    themes: row.themes ?? [],
    fearsToAvoid: row.fearsToAvoid ?? [],
    pastSessions,
  };
}
