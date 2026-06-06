# Product flow — end to end

The full Yarnia experience as one connected flow. Every piece feeds the next.

```
guest auth → onboarding agent → child saved → story agent → story generated → saved to history → history panel reads it
```

---

## 1. Identity: InstantDB guest auth

On first launch the app signs in anonymously via InstantDB (`db.auth.signInAnonymously()`). This creates a persistent guest identity tied to the device — no sign-up, no form. The `userId` (InstantDB `auth.id`) is stored locally via `shared_preferences` and reused on every subsequent launch.

Guest accounts can later be upgraded to a named account (email) without losing data — out of scope for the hackathon.

---

## 2. InstantDB schema + permissions

**Schema change** — add `userId` to `children` entity (`instant/instant.schema.ts`):
```ts
children: i.entity({
  ...existing fields...
  userId: i.string().indexed().optional(),
})
```

**Permissions** (`instant/instant.perms.ts`):
```ts
children: {
  view:   "auth.id == data.userId",   // owner only
  create: "auth.id != null",          // any guest or named user
  update: "auth.id == data.userId",
  delete: "false",
},
sessions: {
  view:   "auth.id != null",          // any authenticated user (sessions carry no PII beyond story text)
  create: "false",                    // Worker only (admin token)
  update: "false",
  delete: "false",
},
```

The Flutter app queries InstantDB directly using the public `INSTANT_APP_ID` — no API hop for reads. The Worker uses the admin token for writes (story sessions) and reads that require cross-user data.

---

## 3. App launch routing

On startup `main.dart`:
1. `signInAnonymously()` → get `userId`
2. Query InstantDB: `children where userId == auth.id`
3. **Child found** → load `childId`, go to Greeting screen (existing flow)
4. **No child** → go to Intro screen (onboarding)

Replaces the current hardcoded `_demoChildId`.

---

## 4. Onboarding — intro agent (new users only)

A separate ElevenLabs agent, short and warm. 3-4 exchanges max.

**ElevenLabs dashboard — create "Yarnia Intro" agent:**

System prompt:
> You are Yarnia, a warm and magical bedtime storyteller meeting a child for the very first time. Your job is to learn just enough to tell them a wonderful story tonight. Keep it short and cosy — 3 or 4 questions at most. Ask their name, how old they are, what kinds of characters or adventures they love, and if there is anything scary they would rather not hear about. Once you know enough, call the onboardingComplete tool. Do not start telling the story yet.

First message: `Hello! I'm Yarnia, your bedtime storyteller. I'm so glad you found me. What's your name?`

Client tool `onboardingComplete` parameters: `child_name`, `child_age`, `favorite_characters`, `fears_to_avoid`.

**API — `GET /intro/session`**: same pattern as `/agent/session`, returns signed URL for the intro agent. New env var: `ELEVENLABS_INTRO_AGENT_ID`.

**API — `POST /child`**: creates child in InstantDB with `userId` set, returns `childId`.
Body: `{ userId, name, age, favoriteCharacters, fearsToAvoid }`

**Flutter — `IntroScreen`** (new screen):
- Runs intro agent via `ConversationClient`
- `clientTools: { 'onboardingComplete': OnboardingTool() }`
- `OnboardingTool.execute()`: calls `POST /child` → stores `childId` → calls `widget.onComplete(childId)`

---

## 5. Story agent (existing, wired to story generation)

Currently `onDone` restarts to greeting — it needs to trigger story generation.

**Fix in `main.dart`**: when `AgentScreen.onDone` fires, call `POST /story` with the `childId` and transition to `PlaybackScreen`. The story endpoint uses the child's profile to generate and narrate; no explicit "choice" needed (the agent conversation already shaped tonight's context).

```
agent ends → POST /story { childId } → PlaybackScreen (text + audio)
```

This also triggers the session write-back (already wired in the Worker via `waitUntil`) — so tonight's story is saved to history automatically.

---

## 6. Playback (existing)

No changes needed. Already handles base64 audio, wakelock, share button.

---

## 7. History + profile panel

Accessible via a small `⋮` icon in the top-right of Greeting and Playback screens. Slides up as a modal bottom sheet. Two tabs:

**History tab** — past sessions newest-first. Each card: title, date, characters used. Tap to expand: summary + continuity notes.

**Profile/Debug tab** — child name, age, interests, fears. Plus the dynamic variables section (what the agent knows tonight) from the last `/agent/session` response.

Flutter queries InstantDB directly (guest auth token + owner-scoped permissions). No extra API call for the read path.

---

## Files to create / modify

| File | Change |
|------|--------|
| `instant/instant.schema.ts` | Add `userId` to `children` |
| `instant/instant.perms.ts` | Owner-scoped children; auth-gated sessions |
| `api/src/index.ts` | Add `GET /intro/session` + `POST /child` routes |
| `api/src/agent.ts` | Support intro agent ID alongside story agent ID |
| `api/test/index.test.ts` | Tests for new routes |
| `app/flutter/lib/main.dart` | Guest auth on launch, routing by child presence, agent→story wiring |
| `app/flutter/lib/screens/intro_screen.dart` | New — intro agent + onboardingComplete tool |
| `app/flutter/lib/services/instant_service.dart` | New — guest auth + direct InstantDB reads |
| `app/flutter/lib/widgets/profile_panel.dart` | New — history + profile modal panel |
| `app/flutter/lib/screens/greeting_screen.dart` | Add `⋮` icon to trigger panel |
| `app/flutter/lib/screens/playback_screen.dart` | Same |
| `app/flutter/pubspec.yaml` | Add `shared_preferences` + `instantdb` Flutter package if available |

---

## New env vars

```
ELEVENLABS_INTRO_AGENT_ID=agent_...
```

---

## What stays the same

- Story agent prompt and ID — no changes
- `/agent/session` endpoint — no changes
- Greeting, Agent, Playback screen logic — minor additions only (icon, wiring)
- All existing tests — should still pass
