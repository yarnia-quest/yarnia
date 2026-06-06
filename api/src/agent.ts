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
  // Ready-to-speak opener. The "if we know the child" branch lives here (ElevenLabs first
  // messages can't do conditionals) — the dashboard first message is just {{greeting}}.
  greeting: string;
};

export function toDynamicVariables(child: Child | null): DynamicVariables {
  // Anonymous: streaming voice may start before we know who is listening. Empty name signals
  // "unknown" so the agent's first job is to ask; safety stays on with a neutral fears default.
  if (!child) {
    return {
      child_name: "",
      child_age: "",
      favorite_characters: "",
      fears_to_avoid: "nothing in particular",
      last_story: "",
      session_state: "first_time",
      active_story_series: "",
      last_series_episode: "",
      greeting: "Hello! It's Yarnia, your bedtime storyteller. I'm so happy you're here. What's your name?",
    };
  }

  const sessions = child.pastSessions;
  const last = sessions[sessions.length - 1];

  // A "series" = characters that recur across 2+ past sessions (the Ella-and-Finn pattern).
  const counts = new Map<string, number>();
  for (const s of sessions) {
    for (const c of s.charactersUsed ?? []) counts.set(c, (counts.get(c) ?? 0) + 1);
  }
  const recurring = [...counts.entries()].filter(([, n]) => n >= 2).map(([c]) => c);
  const hasSeries = recurring.length > 0;

  // Branch the opener here, since the ElevenLabs first-message field can't: returning
  // children get the memory moment; first-timers get a warm welcome with no false memory.
  const greeting = last
    ? `Hello again, ${child.name}. It's Yarnia. I remember our story about ${last.summary}. Are you all cozy and ready for a new one tonight?`
    : `Hello ${child.name}. It's Yarnia, and I'm so glad you're here. Shall we find a cozy story for tonight?`;

  return {
    child_name: child.name,
    child_age: String(child.age),
    favorite_characters: child.favoriteCharacters.join(" and ") || "all kinds of friends",
    fears_to_avoid: child.fearsToAvoid.join(", ") || "nothing in particular",
    last_story: last ? last.summary : "a brand new adventure",
    session_state: sessions.length ? "returning" : "first_time",
    active_story_series: hasSeries ? recurring.join(" and ") : "",
    last_series_episode: hasSeries && last ? last.summary : "",
    greeting,
  };
}

// Fetches a LiveKit JWT token so the Flutter SDK can start a conversation with a
// private agent. Uses the /token endpoint (not the old get-signed-url WebSocket endpoint)
// because the elevenlabs_agents Flutter SDK (0.6.1+) uses LiveKit as transport and needs
// a LiveKit JWT, not a WebSocket URL.
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
    `${baseUrl}/v1/convai/conversation/token?agent_id=${encodeURIComponent(agentId)}`,
    { headers: { "xi-api-key": opts.apiKey } },
  );

  if (!res.ok) {
    throw new Error(`ElevenLabs token request failed: ${res.status}`);
  }

  const data = (await res.json()) as { token?: string };
  if (!data.token) {
    throw new Error("ElevenLabs returned no token");
  }
  return data.token;
}

// Orchestrates an agent session: load the child if we know one, render dynamic variables,
// and fetch a signed URL. childId is OPTIONAL — streaming voice can start anonymously (we may
// not know who is listening until they speak), in which case the agent greets and asks the
// name. Signing is best-effort: a public agent connects with agentId + variables alone, so a
// signing failure degrades to signedUrl:null. A given-but-unknown childId is still a 404.
export type AgentSessionDeps = {
  loadChild: (childId: string) => Promise<Child | null>;
  agentId: string;
  getSignedUrl: (agentId: string) => Promise<string>;
};

export type AgentSessionResult =
  | { ok: true; agentId: string; dynamicVariables: DynamicVariables; signedUrl: string | null }
  | { ok: false; reason: "child_not_found" };

export async function createAgentSession(
  childId: string | undefined,
  deps: AgentSessionDeps,
): Promise<AgentSessionResult> {
  let child: Child | null = null;
  if (childId) {
    child = await deps.loadChild(childId);
    if (!child) return { ok: false, reason: "child_not_found" };
  }

  const dynamicVariables = toDynamicVariables(child);

  let signedUrl: string | null = null;
  try {
    signedUrl = await deps.getSignedUrl(deps.agentId);
  } catch (err) {
    console.error("get-signed-url failed; client can connect publicly with agentId:", err);
  }

  return { ok: true, agentId: deps.agentId, dynamicVariables, signedUrl };
}
