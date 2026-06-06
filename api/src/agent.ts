// Maps a child's memory into the ElevenLabs Agent's {{...}} dynamic variables (see
// infra/elevenlabs-agent.md). Pure, so the mapping is unit-testable. The Worker reads the
// child (admin-only) and hands these to the client, which starts the conversation with them.
import type { Child } from "./prompt";

// Every variable is derivable from the child's stored data (no parent model, no client
// input). session_state + the series fields support the agent's returning-vs-first-time
// and recurring-journey behavior. See infra/elevenlabs-agent.md.
export type DynamicVariables = {
  child_name: string;
  child_age: string;
  favorite_characters: string;
  fears_to_avoid: string;
  last_story: string;
  session_state: "first_time" | "returning";
  active_story_series: string;
  last_series_episode: string;
};

export function toDynamicVariables(child: Child): DynamicVariables {
  const sessions = child.pastSessions;
  const last = sessions[sessions.length - 1];

  // A "series" = characters that recur across 2+ past sessions (the Ella-and-Finn pattern).
  const counts = new Map<string, number>();
  for (const s of sessions) {
    for (const c of s.charactersUsed ?? []) counts.set(c, (counts.get(c) ?? 0) + 1);
  }
  const recurring = [...counts.entries()].filter(([, n]) => n >= 2).map(([c]) => c);
  const hasSeries = recurring.length > 0;

  return {
    child_name: child.name,
    child_age: String(child.age),
    favorite_characters: child.favoriteCharacters.join(" and ") || "all kinds of friends",
    fears_to_avoid: child.fearsToAvoid.join(", ") || "nothing in particular",
    last_story: last ? last.summary : "a brand new adventure",
    session_state: sessions.length ? "returning" : "first_time",
    active_story_series: hasSeries ? recurring.join(" and ") : "",
    last_series_episode: hasSeries && last ? last.summary : "",
  };
}

// Fetches a signed WebSocket URL so the browser client can start a conversation with a
// private agent. fetch is injectable for testing. Docs: ElevenLabs convai get-signed-url.
const DEFAULT_BASE_URL = "https://api.elevenlabs.io";

export type SignedUrlOpts = {
  apiKey: string;
  baseUrl?: string;
  fetch?: typeof fetch;
};

export async function getSignedUrl(agentId: string, opts: SignedUrlOpts): Promise<string> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;

  const res = await doFetch(
    `${baseUrl}/v1/convai/conversation/get-signed-url?agent_id=${encodeURIComponent(agentId)}`,
    { headers: { "xi-api-key": opts.apiKey } },
  );

  if (!res.ok) {
    throw new Error(`ElevenLabs signed-url request failed: ${res.status}`);
  }

  const data = (await res.json()) as { signed_url?: string };
  if (!data.signed_url) {
    throw new Error("ElevenLabs returned no signed_url");
  }
  return data.signed_url;
}

// Orchestrates an agent session: load the child (admin-only), render their dynamic
// variables, and fetch a signed URL. Signing is best-effort — a public agent can connect
// with agentId + variables alone, so a signing failure degrades to signedUrl:null.
export type AgentSessionDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
};

export type AgentSessionResult =
  | { ok: true; agentId: string; dynamicVariables: DynamicVariables; signedUrl: string | null }
  | { ok: false; reason: "child_not_found" };

export async function createAgentSession(
  childId: string,
  deps: AgentSessionDeps,
): Promise<AgentSessionResult> {
  const child = await deps.loadChild(childId);
  if (!child) return { ok: false, reason: "child_not_found" };

  const dynamicVariables = toDynamicVariables(child);

  let signedUrl: string | null = null;
  try {
    signedUrl = await deps.getSignedUrl(deps.agentId);
  } catch (err) {
    console.error("get-signed-url failed; client can connect publicly with agentId:", err);
  }

  return { ok: true, agentId: deps.agentId, dynamicVariables, signedUrl };
}
