# Plan: Conversational story engine + device-aware TTS strategy

> **On approval, first action:** copy this file to `yarnia/plans/conversational-engine.md` (project-local per global rules) and work from there. `~/.claude/plans/` is only the plan-mode scratch location.
>
> **Branch:** continue on `sustainable` (post-hackathon pivot). Do NOT switch to `main`.
>
> **Testing is mandatory (global rule):** backend changes are TDD on Vitest (`cd api && npm test`); app changes must pass `cd app/flutter && flutter analyze` clean and be verified on the connected Pixel 9 Pro (`flutter run -d "Pixel 9 Pro"`). There is no device-free way to test TTS/STT/mic — say so, don't skip.
>
> **Error handling (global rule):** every `catch` logs at warning+ or rethrows. Never swallow. Applies to all new download/turn/VAD code.

## Context

Yarnia reads a generated bedtime story aloud, sentence by sentence, on-device (Pocket/Piper TTS via sherpa-onnx, Whisper/system STT, Nebula `Qwen3-8B` for text). Two gaps surfaced on-device:

1. **No conversation.** The story plays straight through with no way for the child to interrupt, ask a question, or change the story. The old ElevenLabs path *did* listen but cut the story on any background noise — the exact failure we must not reproduce. Desired behavior: the child interrupts, Yarnia **finishes its current sentence**, pauses, listens, then either **answers** a question, **continues**, or **revises the story (even an earlier part) and re-reads from there** — all off a sentence-level checkpoint so "go back" is just lowering a cursor.
2. **Model reach.** The 400 MB Pocket FR model is too big; lower-end phones (Huawei P20 Pro) are too slow for Pocket at all. Add Piper as a light option, detect device capability to **recommend** the right engine, and flag the DE/FR/ES Pocket models as "HuggingFace upload pending."

Target posture: **off-screen, hands-free**. Button + finish-sentence is the reliable core; VAD-based hands-free interrupt is the goal we build toward.

## Settled architecture decisions

- **Checkpoint = sentence index.** Story held as `List<String> _sentences` + `int _cursor`. Narration is a resumable loop `_narrateFrom(cursor)`. Continue = resume at `_cursor`; go back = lower `_cursor`; revise an earlier part = splice `_sentences` from index *k*, set `_cursor = k`. No timestamps, no separate store.
- **One LLM call per interrupt, structured JSON (no tool-calling).** Qwen3-8B has no reliable tool-calling; JSON is robust. Backend stays stateless (full story sent each turn — it's small), matching the existing `/story` pattern.
- **Interrupt is layered:** Phase 2 = button + finish-current-sentence (deterministic, zero false cuts). Phase 2b = hands-free VAD reusing the existing Silero-VAD `AsrSession`, with hardware echo cancellation, built to beat ElevenLabs' false-cut problem.
- **Turn routed through `api/`** (new `POST /story/turn`) so LLM I/O is logged via existing `telemetry` and `isStorySafe` runs on revised sentences.

---

## Phase 0 — Model housekeeping (trivial, do first)

### 0.1 `app/flutter/lib/services/settings_service.dart`
- Above `pocketDe`/`pocketFr`/`pocketEs` (lines 37–60), the `hfRepo: null` lines already carry `// TODO: upload to HuggingFace`. Make them explicit and greppable:
  `hfRepo: null, // TODO(hf-upload): publish this Pocket export to HuggingFace, then set hfRepo to enable in-app download`
- Leave `canDownload` (line 81) as-is — it already returns false when `hfRepo == null`, so DE/FR/ES correctly show non-downloadable. The 400 MB FR (`pocketFr`, line 45) is therefore already gated; it will be superseded by Piper FR in Phase 3.

### 0.2 `app/flutter/lib/screens/settings_screen.dart`
- In the TTS `_StatusChip` / `_EngineTile` branch that currently renders "Coming soon" for `!isInstalled && !canDownload`, change the label for Pocket DE/FR/ES to **"Uploading to HuggingFace soon"** (a `caption`-styled `Text`, not a tappable chip). Keep "Download →" for `canDownload`, "On device" for installed, "Default" for system.

### 0.3 Verify
`flutter analyze` clean; settings screen shows the new caption for DE/FR/ES and an unchanged "Download →" for Pocket EN.

---

## Phase 1 — Checkpoint narration core (frontend only, no LLM change)

All edits in **`app/flutter/lib/screens/story_screen.dart`**.

### 1.1 State machine
- Extend the enum (line 21): `enum _State { listening, thinking, narrating, paused, done }`.
- Add fields near line 66:
  ```dart
  List<String> _sentences = [];
  int _cursor = 0;            // index of the NEXT sentence to speak
  bool _interruptPending = false;
  ```

### 1.2 Build the sentence list once, then narrate from cursor
- In `_generateAndSpeak` (line 221), after getting `storyText` (line 238) and before `_speakStory`, set:
  ```dart
  _sentences = splitSentences(storyText);   // splitSentences is in tts_session.dart:146
  _cursor = 0;
  ```
- Replace `_speakStory(storyText)` call (line 244) with `await _narrateFrom(0);`.

### 1.3 `_narrateFrom(int from)` — the single resumable loop
Replace `_speakStory`/`_speakSystem`/`_speakPocket` (lines 251–312) with a cursor-driven version. Keep `_refWavForEngine` (314–325) unchanged.

- `Future<void> _narrateFrom(int from)`:
  - `_cursor = from; _interruptPending = false;`
  - `setState(() => _state = _State.narrating);`
  - dispatch on `widget.settings.effectiveEngine`: `_narrateSystemFrom()` or `_narratePocketFrom(engine)`.
  - After the loop returns: if `_interruptPending` → `_enterPaused()` (Phase 2 hook; in Phase 1 just `setState(() => _state = _State.paused)`); else if `_cursor >= _sentences.length` → `setState(() => _state = _State.done)`.

- `_narrateSystemFrom()` (adapt 261–273): set language/rate once, then
  ```dart
  while (_cursor < _sentences.length && !_interruptPending) {
    if (!mounted) return;
    final sentence = _sentences[_cursor];
    setState(() => _currentSentence = sentence);
    final completer = Completer<void>();
    _systemTts.setCompletionHandler(() => completer.complete());
    await _systemTts.speak(sentence);
    await completer.future;
    _cursor++;                          // advance AFTER the sentence finishes = checkpoint
  }
  ```

- `_narratePocketFrom(TtsEngine engine)` (adapt 275–312): the key change is feeding sentences from `_cursor` onward through a controllable stream so we can stop after the current sentence. Use `TtsSession.speakStream(Stream<String> sentences, {String? refWavPath})` (tts_session.dart:200) instead of `speak(text)`:
  ```dart
  final remaining = _sentences.sublist(_cursor);
  final controller = StreamController<String>();
  // feed sentences, but stop feeding once an interrupt is pending
  () async {
    for (final s in remaining) {
      if (_interruptPending) break;
      controller.add(s);
    }
    await controller.close();
  }();
  final playlist = ConcatenatingAudioSource(children: []);
  bool playerStarted = false;
  await for (final chunk in session.speakStream(controller.stream, refWavPath: refWavPath)) {
    if (!mounted) return;
    setState(() => _currentSentence = chunk.text);
    await playlist.add(AudioSource.uri(Uri.file(chunk.wavPath)));
    if (!playerStarted) { await _player.setAudioSource(playlist); unawaited(_player.play()); playerStarted = true; }
    _cursor++;                          // advance as each chunk is queued/played
    if (_interruptPending) { session.cancel(); break; }   // cancel() is tts_session.dart:254
  }
  ```
  Keep the existing `catch` → fall back to `_narrateSystemFrom()` (preserve the log line at 308). NOTE: chunk-vs-playback timing means `_cursor` here tracks "synthesized", which is acceptable for a checkpoint; if precise "spoken" position matters, advance `_cursor` off `_player.currentIndex` instead — implementer's call, document whichever is chosen.

### 1.4 Interrupt button in the narrating view
- `_NarratingView` (508) currently takes only `sentence`. Add `final VoidCallback onInterrupt;` and render a small pause/interrupt control below the sentence (a circular button mirroring `_ListeningView`'s mic, e.g. a ⏸ glyph). Wire it in `build` (line 361): `_NarratingView(sentence: _currentSentence, onInterrupt: _requestInterrupt)`.
- `void _requestInterrupt() { setState(() => _interruptPending = true); }` — the loop in 1.3 observes it, finishes the in-flight sentence, and transitions to `paused`.

### 1.5 Paused view (Phase 1: pure resume)
- Add a `_PausedView` (clone `_DoneView` styling) with two actions: **"Continue"** → `_narrateFrom(_cursor)`; **"Start over"** → `_restart()` (327). Wire `_State.paused` in the `build` switch (349).

### 1.6 Verify (on device)
Start a story → tap interrupt mid-paragraph → the current sentence completes, audio stops at the boundary → Continue resumes from the next sentence (no repeat/skip) for **both** System TTS and Pocket. `flutter analyze` clean.

---

## Phase 2 — Conversation turn (backend + app)

### Backend — `api/` (TDD: write the failing test first, then implement)

#### 2.1 `api/src/turn.ts` (new) — pure parser, mirrors `story.ts`/`safety.ts` style
```ts
export type TurnDecision = {
  intent: "continue" | "answer" | "revise";
  say?: string;                                              // short spoken line before resuming
  revision?: { fromSentence: number; sentences: string[] };  // present iff intent === "revise"
  resumeAt: number;                                          // sentence index to resume from
};

// Tolerant parse: strip ``` fences / leading prose, JSON.parse, validate shape.
// On any failure, log a warning and return a safe default: { intent: "continue", resumeAt: cursor }.
export function interpretTurn(raw: string, cursor: number): TurnDecision { ... }
```
Validation rules: `intent` must be one of the three; if `revise`, require `revision.sentences` non-empty and `0 <= fromSentence <= storyLength` (clamp; pass `storyLength` in as an arg); `resumeAt` defaults to `cursor` (or `fromSentence` for revise) when missing/out of range.

#### 2.2 `api/src/prompt.ts` — add `buildTurnPrompt`
Add next to `buildStoryPrompt` (reuse `Child`, `LANGUAGE_NAMES`):
```ts
export function buildTurnPrompt(
  child: Child, sentences: string[], cursor: number, utterance: string, language?: string
): StoryPrompt
```
- **system**: the same safety preamble lines as `buildStoryPrompt` (44–48), then: "Here is the bedtime story so far, as numbered sentences:" + the sentences joined as `0: ...\n1: ...`, then "You are paused right after sentence `${cursor - 1}` (about to read sentence `${cursor}`)." then the JSON contract: respond with ONLY a JSON object matching `{intent, say?, revision?{fromSentence,sentences[]}, resumeAt}`, no prose/markdown; explain each field; give ONE worked example for each intent. Reinforce that revised sentences must obey the same gentle/age-appropriate rules. Append the language line (80–83) if non-English.
- **user**: `The child just said: "${utterance}". Decide what to do and respond with the JSON object only.`

#### 2.3 `api/src/index.ts` — `POST /story/turn`
Add after the `/story` route (ends line 404), same shape:
- Parse body `{ childId, sentences: string[], cursor: number, utterance: string, language? }`; `childId`+`sentences` required (400 otherwise). `sanitizeChoice` the `utterance`.
- `const deps = makeDeps(c.env);` `requireChildToken` (308) gate; rate-limit via the existing `storyLimiter` (363).
- `const child = await deps.loadChild(childId);` → 404 if null.
- `const prompt = buildTurnPrompt(child, sentences, cursor, utterance, language);`
- `const raw = await deps.generate(prompt);` then `const decision = interpretTurn(raw, cursor, sentences.length);`
- If `decision.revision`, run `isStorySafe(decision.revision.sentences.join(" "))` (import from `./safety`); if unsafe, drop the revision → coerce to `{ intent: "continue", resumeAt: cursor }` (do NOT narrate unsafe content) and `telemetry.error("story_turn_unsafe", { childId })`.
- `telemetry.track("story_turn", { childId, intent: decision.intent, language: language ?? "en" });`
- `return c.json(decision);`

#### 2.4 Tests (`api/test/`, match `story.test.ts` `appWith`/`post` harness, lines 1–55)
- `turn.test.ts` (unit on `interpretTurn`): parses clean continue/answer/revise; strips ```json fences; clamps out-of-range `fromSentence`/`resumeAt`; malformed JSON → `{intent:"continue", resumeAt:cursor}` (assert a warning is logged).
- `prompt.test.ts` (extend): `buildTurnPrompt` includes numbered sentences, the current-position line, the JSON contract, and (for `language:"de"`) the German line.
- Route test (in `story.test.ts` or new `turn.route.test.ts`): `POST /story/turn` with a faked `generate` returning each intent → asserts the JSON response; faked `generate` returning a violent revision → response coerced to `continue`. Run `npm test`.

### App — `app/flutter/lib/screens/story_screen.dart`

#### 2.5 Capture an utterance on pause
- Replace the Phase-1 `_enterPaused()` stub: on pause, instead of just showing buttons, **open the mic and capture one utterance**, reusing existing STT plumbing:
  - whisper path: `_startWhisperMic()` (166) then after a short listen window `_asrSession!.flush()` + 300 ms wait (mirrors `_stopListeningAndGenerate`, 200–211), read `_transcript`.
  - system path: `_speech.listen(...)` (156) with the existing `onResult`.
- Keep a manual fallback in `_PausedView`: a "Type / tap to talk" affordance and a plain **Continue** button so a silent pause still resumes.

#### 2.6 `_sendTurn(String utterance)` → apply decision
```dart
final res = await http.post(Uri.parse('${widget.apiBase}/story/turn'),
  headers: {...widget.apiHeaders, 'content-type': 'application/json'},
  body: jsonEncode({
    'childId': widget.childId,
    'sentences': _sentences,
    'cursor': _cursor,
    'utterance': utterance,
    'language': widget.settings.language,
  }));
// parse decision; on non-200 or parse failure: log warning, _narrateFrom(_cursor)
```
Apply:
- **continue**: if `say` non-empty, speak it (a one-shot `_speakLine(say)` helper: system TTS or a one-sentence `TtsSession`), then `_narrateFrom(decision.resumeAt)`.
- **answer**: `_speakLine(say)`, then a brief "shall I continue?" — re-open mic briefly OR show a Continue button; on yes → `_narrateFrom(decision.resumeAt)`.
- **revise**: splice — `_sentences.replaceRange(decision.revision.fromSentence, _sentences.length, decision.revision.sentences);` `_speakLine(say ?? "Okay, I changed that part — let me read it again.");` then `_narrateFrom(decision.revision.fromSentence);` (re-reads the revised section, including going back before the old cursor).

#### 2.7 Verify (on device)
Mid-story interrupt → "make the dragon green" → Yarnia confirms and re-reads from the dragon sentence changed; → "what's his name?" → answers, asks to continue, resumes from cursor; → "keep going" → resumes cleanly. `flutter analyze` clean; `npm test` green.

---

## Phase 2b — Hands-free VAD interrupt (off-screen goal; experimental)

Builds on Phase 2's handling; only the *trigger* changes. All in `story_screen.dart` + `RecordConfig`.

- During `_narrateFrom`, keep the mic open feeding `_asrSession` (Silero VAD already runs in `asr_session.dart`). On an `AsrSegment` (handler `_onAsrEvent`, 121) with a **meaningful** transcript (non-empty, above a min word/duration threshold) → `setState(() => _interruptPending = true)` and **reuse that segment text as the utterance** (skip the Phase-2 re-listen, pass it straight to `_sendTurn`).
- **Echo cancellation (the hard part — mic hears Yarnia's own TTS):** enable Android hardware AEC in `RecordConfig` (173) — `echoCancel: true, noiseSuppress: true`, and on Android prefer the voice-communication audio source if exposed by `record` v7. Document iOS behavior (AVAudioSession voiceChat mode). If hardware AEC is insufficient: gate VAD so segments overlapping active playback are ignored and require sustained speech (debounce) — this is what must beat ElevenLabs.
- **Fallback** if pure VAD is too trigger-happy: during playback accept only segments containing an interrupt keyword ("stop", "wait", "yarnia"); allow free speech only once paused.
- Keep the Phase-1 button as the always-available manual path. Make hands-free a settings toggle (default off until tuned).

**Verify:** play a story across a noisy room → no false cut; speak a real request → finishes sentence, pauses, processes; confirm Yarnia's own voice does not self-trigger.

---

## Phase 3 — Device-aware model strategy

### 3.1 Piper as the light engine — `settings_service.dart` + `settings_screen.dart`
- The `TtsEngineKind` worker already supports `piperEn/piperDe/piperTr` (`tts_session.dart`). Add `piperEn` (and a Piper FR/DE) entries to the `TtsEngine` enum with real `hfRepo` + `modelFiles` (the espeak-ng VITS file set: model `.onnx`, `tokens.txt`, `espeak-ng-data/`) so they download via the existing `_downloadEngine` flow (settings_screen.dart:68). Map `kind` (settings_service.dart:83) for the new entries. Provide a Piper FR to replace the 400 MB Pocket FR (then hide/remove `pocketFr`).
- Add `_pocketFiles`-style `const _piperFiles` for the Piper file list.

### 3.2 Device capability detection
- Add `device_info_plus` to `pubspec.yaml`. New helper `lib/services/device_class.dart`: `enum DeviceClass { strong, weak }` from `Platform.numberOfProcessors` + RAM (`AndroidDeviceInfo`/`IosDeviceInfo`). Heuristic: Pixel 9 → strong (Pocket fine even at 400 MB); P20-Pro-class → weak (Piper/System only). Log the classification.

### 3.3 Recommendation + smart default
- In `settings_screen.dart`, add a **"Recommended"** badge on the engine matching device class (strong → Pocket; weak → Piper, else System).
- On first run (no saved `ttsEngine` in prefs — `settings_service.dart:157`), seed the default to the recommended engine instead of always `system`.

### 3.4 Verify
Strong device recommends Pocket; emulate/inspect a weak profile → Piper/System recommended; the Piper model downloads via the existing tile flow and narrates in real time.

---

## File-change summary

| File | Phase | Change |
|------|-------|--------|
| `app/flutter/lib/services/settings_service.dart` | 0,3 | TODO comments; Piper enum entries + `kind` map; smart default |
| `app/flutter/lib/screens/settings_screen.dart` | 0,3 | "Uploading soon" caption; Recommended badge; Piper download tiles |
| `app/flutter/lib/screens/story_screen.dart` | 1,2,2b | cursor state machine, interrupt button, paused/conversation, `_sendTurn`, VAD trigger |
| `app/flutter/lib/services/device_class.dart` (new) | 3 | device capability heuristic |
| `app/flutter/pubspec.yaml` | 3 | add `device_info_plus` |
| `api/src/turn.ts` (new) | 2 | `interpretTurn` parser + `TurnDecision` |
| `api/src/prompt.ts` | 2 | `buildTurnPrompt` |
| `api/src/index.ts` | 2 | `POST /story/turn` route |
| `api/test/turn.test.ts` (new), `prompt.test.ts`, `story.test.ts` | 2 | unit + route tests (TDD) |
