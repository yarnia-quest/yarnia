// Output moderation for the kids bedtime product (defense in depth).
//
// The PRIMARY content-safety guardrail is the system prompt (api/src/prompt.ts): it instructs
// age-appropriate content and to avoid the child's named fears. This module is a second layer
// that scans the *generated* text for clearly age-inappropriate content. If it trips, the
// caller (createStory) regenerates once with a reinforced instruction and, failing that, swaps
// in a safe canned story. It is intentionally conservative (better a needless regenerate than
// an unsafe story) and is NOT a substitute for a full moderation API in production.

const UNSAFE_PATTERNS: RegExp[] = [
  /\bblood(y|shed)?\b/i,
  /\bgore\b|\bgory\b/i,
  /\bkill(s|ed|ing)?\b|\bmurder/i,
  /\bstab(s|bed|bing)?\b/i,
  /\bgun(s)?\b|\bshoot(s|ing)?\b|\bshot\b/i,
  /\bknife\b|\bblade\b|\bweapon/i,
  /\bcorpse\b|\bdead body\b/i,
  /\bsuicide\b|\bself[- ]?harm\b/i,
  /\bsex(ual|y)?\b|\bnaked\b|\bporn/i,
  /\bf+u+c+k|\bshit\b|\bbitch\b|\bbastard\b|\basshole\b|\bdamn\b/i,
  /\bcocaine\b|\bheroin\b|\bmeth(amphetamine)?\b/i,
];

// True when the text contains no clearly age-inappropriate content.
export function isStorySafe(text: string): boolean {
  return !UNSAFE_PATTERNS.some((re) => re.test(text));
}

// A guaranteed-safe, soothing fallback used only when generation keeps producing unsafe text.
export function safeFallbackStory(name: string): string {
  const who = name?.trim() || "a sleepy little one";
  return (
    `Once upon a time, ${who} curled up under a soft blanket of stars. ` +
    `A gentle owl hooted goodnight, the moon hummed a quiet tune, and warm dreams drifted in ` +
    `like little boats on a calm, calm sea. Goodnight, ${who}. Sleep tight.`
  );
}
