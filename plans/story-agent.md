# Plan: Conversational storytelling agent (on-device)

> Status as of 2026-06-14: Phases 0-3 implemented in code, APK built. Device (pixie:5555) was unreachable for install. Deploy when reconnected.

## What was built

### Phase 0 — Proved on-device generation
- Qwen2.5-1.5B generates stories in ~90s on Pixel 9 Pro.
- `flutter_gemma` / MediaPipe backend, model at `/sdcard/Android/data/.../pushed-llm/`.
- `LocalLlm.instance.generate()` streams tokens; `_generateAndSpeak()` calls it.

### Phase 1 — Greeting audio fix + agent infrastructure
**Root cause of silent greeting:** `ConcatenatingAudioSource` with a single item on just_audio 0.9.44 never emits `ProcessingState.completed`. Fixed in `_speakLine()` by switching to `AudioSource.uri` (single file source) per chunk + 30s timeout as safety net. TTS prewarm fires at `initState()` via `_prewarmTts()` so the 1.75s cold start happens before the greeting.

**Agent infrastructure added to `LocalLlm`:**
- `startChat(String system, {int maxTokens})` — creates `InferenceChat` with the agent system prompt.
- `chatTurn(String userMessage)` — streams one turn from the chat session.
- `closeChat()` — closes and nulls the active chat.

### Phase 2 — Conversational loop
Flow: local greeting (fast, local) → if on-device model active → `_startConversation()` → listen → `_doConverseTurn()` → parse `READY: <premise>` or JSON → speak reply → if ready, generate story; if chatting, listen again. Max 3 turns then force-generate.

**Files changed:**
- `app/flutter/lib/services/local_llm.dart`: added `startChat`, `chatTurn`, `closeChat`
- `app/flutter/lib/screens/story_screen.dart`:
  - `_State.conversing` added to enum (Yarnia speaking during conversation)
  - `_conversationMode`, `_agentTurns` fields
  - `_startSession()`: routes to `_startConversation()` when model active
  - `_startConversation()`, `_agentSystem()`, `_skipConversation()`, `_defaultStoryTopic()` — new
  - `_doConverseTurn()`, `_parseAgentResponse()`, `_defaultReadyLine()` — new
  - `_stopListeningAndGenerate()`: routes to `_doConverseTurn()` when `_conversationMode`
  - `_ConversationView` widget with audio bars + Skip button
  - `_ListeningView` case: shows "Just tell me a story →" backstop when `_conversationMode`
  - `_restart()`: clears `_conversationMode`, `_agentTurns`, closes chat

**Agent system prompt format:** Uses `READY: <premise>` as the transition signal (more reliable than strict JSON for 1.5B models). Falls back to JSON parse if model uses that. Strips `<think>` tags.

### Phase 3 — On-device interrupt handling
**Files added:**
- `app/flutter/lib/services/turn_decision.dart` (new) — Dart port of `api/src/turn.ts` plus `buildLocalTurnPrompt()`.

**Files changed:**
- `app/flutter/lib/screens/story_screen.dart`:
  - `_sendTurn()` now tries `_sendTurnLocal()` (on-device LLM) first, falls back to `_sendTurnApi()`.
  - `_applyTurnDecision()` replaces the inline switch.
  - `_defaultReviseLine()` for i18n revision acknowledgement.

## Key constraints to remember
- `ConcatenatingAudioSource` with single item never completes → use `AudioSource.uri` in `_speakLine`.
- `TextResponse.token` (not `.text`) — flutter_gemma 0.13.6.
- On-device LLM token budget: `ekv1280` = 1280 tokens KV cache. Keep agent turns short.
- `pixie:5555` is ADB over WiFi. Device must be on the same network.

## Pending / NOT done
- Phase 1 LLM greeting: kept local greeting (fast, always works). LLM greeting would need a `chatTurn('')` call after `startChat()`, before `_startListening()`. Deferred.
- `POST /agent/context` API endpoint: child's age/fears are not passed to the local turn prompt (only name + language available offline). Add when the API is reachable.
- Testing on device: all the above is code-only; not yet verified to work end-to-end.
- Story persist after conversational generation: `_persistStory` is called with `storyBrief` as the `choice` when coming from conversation mode. This is correct but uses the brief not the full transcript.
