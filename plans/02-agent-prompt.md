# Plan: Agent prompt quality

## Why
Current `buildAgentTurnSystem` is thin — it works but lacks structure. The ElevenLabs prompt in `ideation/elevenlabs-prompt.md` is the reference: returning vs first_time distinction, one-question-at-a-time rule, structured steps, safety guardrail.

## Changes needed

### `api/src/prompt.ts` — `buildAgentTurnSystem(child, language)`
- Derive `sessionState`: `child.pastSessions.length > 0 ? 'returning' : 'first_time'`
- **Returning**: "You know {name} from past nights. Last time: {lastStory}. Recall ONE warm detail warmly — never retell it."
- **First time**: "This is your first night with {name}. Give a warm first welcome. Do NOT invent a past story."
- Structured goal steps (numbered, explicit):
  1. Greet. If returning, nod to last story. If first time, simple magical welcome.
  2. Choose tonight's story. Offer familiar characters/themes if known, else two cozy options.
  3. When you have a clear premise, start your reply with `READY:` + one-line premise.
- "Ask only ONE short question at a time, then wait."
- Safety: "Every reply must be gentle, calm, and age-appropriate. If asked for something scary or intense, softly turn it into a cozy version."
- Auto-cap: "After 2 exchanges without a READY:, choose a cozy default and emit it as READY: yourself."

### `app/flutter/lib/services/story_utils.dart` — `buildAgentSystem()`
Mirror the same structure (offline fallback). Slightly more compact due to context window limits.

### Tests
- `api/test/agent-turn.test.ts`: add returning/first_time distinction tests
- `app/flutter/test/story_logic_test.dart`: update `buildAgentSystem` group

## Reference
See `ideation/elevenlabs-prompt.md` for the full ElevenLabs prompt. Port the *structure* and *rules*, not the ElevenLabs-specific tooling (end_call, session_state variable syntax).
