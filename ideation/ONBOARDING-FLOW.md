# Onboarding flow — new user guest auth + intake agent

## Goal

New users who open the app for the first time should be greeted, introduced to Yarnia, and have a short voice conversation that collects enough to personalize their first story. No forms. No typing. Just talking.

Returning users skip all of this and go straight to the story agent.

---

## Architecture decision: two agents, not one

The intro/onboarding conversation and the bedtime story conversation have different tones and different jobs. A single agent with branching produces a confused system prompt and an awkward transition mid-session. Two agents, clean handoff.

- **Intro agent** — warm, curious, unhurried. Collects: child's name (or nickname), age, 1-2 favourite characters or themes, one thing to avoid (fears/sensitivities). 3-4 exchanges max. Ends by calling a client tool.
- **Story agent** — same agent we have now (`agent_5201kte23jbef6ethe0448m7x46k`). Receives a fully populated child profile. Picks up as if it already knows the child.

---

## User identity: InstantDB guest auth

InstantDB supports anonymous/guest auth — a persistent identity tied to the device with no sign-up required. The guest token is stored locally and survives app restarts.

On first launch the app calls `db.auth.signInAnonymously()`. On subsequent launches it uses the stored token. The child record in InstantDB is linked to that guest user's ID.

When/if the user later wants to sign up (email), InstantDB supports upgrading a guest to a named account while preserving their data.

---

## Flow

```
App launch
  │
  ├─ Has guest auth token? ──No──► db.auth.signInAnonymously() → store token
  │
  ├─ Has child profile linked to this user? ──Yes──► Story agent (existing flow)
  │
  └─ No child profile ──►  Intro agent
                              │
                              │  (voice conversation, 3-4 exchanges)
                              │
                              └─ client tool: onboardingComplete(name, age, interests, fears)
                                    │
                                    ├─ POST /child  →  create child in InstantDB
                                    ├─ store childId locally
                                    └─ transition to Story agent
```

---

## Work breakdown

### 1. ElevenLabs dashboard — intro agent

Create a new agent ("Yarnia Intro"). Suggested system prompt:

> You are Yarnia, a warm and magical bedtime storyteller meeting a child for the very first time. Your job is to learn just enough to tell them a wonderful story tonight. Keep it short and cosy — 3 or 4 questions at most. Ask their name, how old they are, what kinds of characters or adventures they love, and if there is anything scary they would rather not hear about. Once you know enough, call the onboardingComplete tool. Do not start telling the story yet.

First message: `Hello! I'm Yarnia, your bedtime storyteller. I'm so glad you found me. What's your name?`

Client tool to register: `onboardingComplete` with parameters:
- `child_name` (string)
- `child_age` (string)
- `favorite_characters` (string)
- `fears_to_avoid` (string)

### 2. API — new endpoints

**`GET /intro/session`**
- No childId required
- Returns signed URL for the intro agent + its agentId
- Same pattern as `/agent/session` but for the intro agent

**`POST /child`**
- Body: `{ userId, name, age, favoriteCharacters, fearsToAvoid }`
- `userId` is the InstantDB guest user ID (passed from the app — not a secret)
- Creates the child record in InstantDB, returns `childId`
- Links the child to the guest user so we can look them up on next launch

**`GET /child?userId=...`**
- Looks up the child linked to a guest user
- Returns child profile or 404 if none yet
- Called on app launch to decide which flow to enter

### 3. Flutter — new screen + auth

**`InstantAuthService`** (new utility)
- Wraps InstantDB guest auth
- `signInAnonymously()` — creates or restores guest session, returns userId
- `getUserId()` — returns stored userId

**`IntroScreen`** (new screen)
- Runs intro agent via `ConversationClient`
- Passes `clientTools: { 'onboardingComplete': OnboardingTool() }`
- `OnboardingTool.execute()`:
  1. Calls `POST /child` with collected data
  2. Stores returned `childId` locally
  3. Calls `widget.onComplete(childId)`

**`main.dart` changes**
- On launch: call `GET /child?userId=...`
  - 200 → go to greeting screen (existing flow, use returned childId)
  - 404 → go to `IntroScreen`
- Replace hardcoded `_demoChildId` with the dynamically resolved childId

### 4. State the app needs to persist locally

- `userId` (InstantDB guest token / user ID)
- `childId` (once onboarding completes)

Use `shared_preferences` Flutter package for both. Small, no auth complexity.

---

## New env vars needed

```
ELEVENLABS_INTRO_AGENT_ID=agent_...   # the new intro agent
```

---

## What stays the same

- The story agent and its prompt — no changes
- `/agent/session` endpoint — no changes
- All existing screens (Greeting, Agent, Playback) — no changes to logic, just `_demoChildId` becomes dynamic

---

## Open questions

- Should the intro agent also ask for the child's age verbally, or infer it from the conversation? (Age matters for content safety — explicit is safer.)
- Guest-to-named-account upgrade path: out of scope for hackathon, note for post-event.
- Multi-child households (siblings): out of scope for now, one child per device.
