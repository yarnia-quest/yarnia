// Cost + quota accounting for the LLM/TTS calls behind each story. Two concerns:
//  1) Cost visibility: estimate the spend of a story so it can be logged/tracked (the Qwen +
//     ElevenLabs bill is the main variable cost). Pure + unit-testable.
//  2) Quota enforcement: a free tier of N stories per child, after which a subscription is
//     required — so the EUR 8/mo checkout actually gates value instead of "taking money and
//     enforcing nothing".

// Rough public list prices (USD), deliberately conservative so estimates over- rather than
// under-state spend. Tune as real pricing changes; the point is an auditable cost signal.
const QWEN_USD_PER_1K_TOKENS = 0.002; // qwen3.7-max output, approx
const ELEVENLABS_USD_PER_1K_CHARS = 0.30; // multilingual v2, approx
const CHARS_PER_TOKEN = 4; // rough English heuristic

export type CostEstimate = { tokens: number; genUsd: number; ttsUsd: number; totalUsd: number };

// Estimated marginal cost of producing one story (text always; audio only if narrated).
export function estimateStoryCost(text: string, hasAudio: boolean): CostEstimate {
  const chars = text.length;
  const tokens = Math.ceil(chars / CHARS_PER_TOKEN);
  const genUsd = (tokens / 1000) * QWEN_USD_PER_1K_TOKENS;
  const ttsUsd = hasAudio ? (chars / 1000) * ELEVENLABS_USD_PER_1K_CHARS : 0;
  const round = (n: number) => Math.round(n * 10000) / 10000;
  return { tokens, genUsd: round(genUsd), ttsUsd: round(ttsUsd), totalUsd: round(genUsd + ttsUsd) };
}

// Free stories a child gets before a subscription is required.
export const FREE_STORY_LIMIT = 5;

export type QuotaState = { allowed: boolean; used: number; remaining: number; requiresSubscription: boolean };

// Whether another story is allowed given how many the child already has and their plan.
export function quotaState(usedStories: number, subscribed: boolean): QuotaState {
  if (subscribed) {
    return { allowed: true, used: usedStories, remaining: Infinity, requiresSubscription: false };
  }
  const remaining = Math.max(0, FREE_STORY_LIMIT - usedStories);
  return {
    allowed: remaining > 0,
    used: usedStories,
    remaining,
    requiresSubscription: remaining <= 0,
  };
}
