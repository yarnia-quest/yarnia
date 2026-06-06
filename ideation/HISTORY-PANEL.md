# Plan: History + Settings side panel

## Context

The app currently has no way to see what's been collected about the child or what stories have been told. For the hackathon demo this is useful as a debug view (show judges that memory is actually working) and for real users it adds a sense of "Yarnia knows us." The design should be unobtrusive — a small icon on the greeting or playback screen, not a nav bar. This is purely a Flutter read-only view; no new API endpoints needed (data already exists in InstantDB, already loaded on the API side).

This plan is related to (but separate from) the onboarding plan in `ideation/ONBOARDING-FLOW.md`. It doesn't depend on that work — it works with the current hardcoded child ID and will naturally pick up dynamic child IDs when onboarding is built.

---

## What to build

A slide-up or slide-from-right **panel** (not a full screen) accessible via a small icon (⋮ or ☰) in the top-right corner of **GreetingScreen** and **PlaybackScreen**. It has two tabs:

### Tab 1 — History
- List of past sessions, newest first
- Each entry: title + date + characters used
- Tap to expand: shows summary + continuityNotes

### Tab 2 — Profile / Debug
- Child name, age, favorite characters, themes, fears to avoid
- Current dynamic variables (as sent to the ElevenLabs agent): child_name, session_state, last_story, active_story_series, greeting
- This doubles as a debug view — shows exactly what the agent knows going into tonight's session

---

## Data source

The Flutter app queries InstantDB directly using the public `INSTANT_APP_ID` — no API hop needed. Guest auth users own their data; permissions are owner-scoped. Dynamic variables (what the agent knows tonight) still come from `GET /agent/session?childId=...` since that requires the admin token to load the child.

---

## Implementation

### 1. InstantDB schema — add `userId` to children (`instant/instant.schema.ts`)

Add `userId: i.string().indexed().optional()` to the `children` entity. This is the InstantDB `auth.id` (guest or named account). Links ownership so permission rules work.

### 2. InstantDB permissions — open owner-scoped reads/creates (`instant/instant.perms.ts`)

```
children:
  view:   "auth.id == data.userId"
  create: "auth.id != null"   // any guest or named user can create their child
  update: "auth.id == data.userId"
  delete: "false"

sessions:
  view:   "auth.id != null"   // readable if authenticated; sessions link to child for scoping
  create: "false"             // only the Worker writes sessions (admin token)
  update: "false"
  delete: "false"
```

Guest auth is persistent on-device. Publishing/sharing may eventually require upgrading to a named account — out of scope for now.

### 3. Flutter — InstantDB client init (new `lib/services/instant_service.dart`)

Thin wrapper:
- `init(@instantdb/core)` with the public app ID (hardcoded constant, not a secret)
- `signInAnonymously()` — creates or restores guest session, returns `userId`
- `getUserId()` — returns stored userId
- `queryChild(userId)` — `db.queryOnce({ children: { $: { where: { userId } }, sessions: {} } })`

### 4. Flutter — `ProfilePanel` widget (new `lib/widgets/profile_panel.dart`)

`showModalBottomSheet` with two tabs (navy/gold/cream theme):
- **History tab** — `ListView` of sessions newest-first: title, date, characters. Tap to expand summary + continuityNotes.
- **Profile/Debug tab** — child name, age, interests, fears. Plus dynamic variables section loaded from `GET /agent/session` response (already fetched in AgentScreen; pass it down or re-fetch).

Queries InstantDB directly on open. Loading spinner while fetching. Errors shown inline.

### 2. Flutter — `ProfilePanel` widget (new file: `lib/widgets/profile_panel.dart`)

A `DraggableScrollableSheet` or `showModalBottomSheet` containing:
- Two-tab layout (`TabBar` + `TabBarView`) styled in navy/gold/cream
- **History tab**: `ListView` of session cards (title, date, characters). Expandable to show summary + continuityNotes.
- **Profile tab**: Simple key-value rows for child profile fields + dynamic variables section.

Fetches data from `GET /child/:childId` on open. Shows a loading spinner while fetching. Errors shown inline (not swallowed).

### 3. Flutter — trigger icon on GreetingScreen + PlaybackScreen

Both screens get a small `IconButton` (use `Icons.menu` or `Icons.more_vert`) in the top-right corner via a `Stack` + `Positioned`. Tapping it calls `showModalBottomSheet(context, builder: (_) => ProfilePanel(...))`.

Changes to:
- `lib/screens/greeting_screen.dart` — add icon to existing `Stack`
- `lib/screens/playback_screen.dart` — same

Both already use `Stack` + `Positioned.fill` so the icon placement is straightforward.

### 4. Styling

Consistent with existing theme:
- Panel background: `navyLight` (`#1C1E3A`)
- Tab indicator: `gold`
- Text: `cream` (labels), `gold` (values/highlights)
- Session cards: subtle border in `cream.withAlpha(30)`
- Fonts: `TextStyle(fontFamily: 'serif')`

---

## Files to touch

| File | Change |
|------|--------|
| `instant/instant.schema.ts` | Add `userId` field to `children` entity |
| `instant/instant.perms.ts` | Owner-scoped view/create for children; authenticated read for sessions |
| `app/flutter/lib/services/instant_service.dart` | New — guest auth + direct InstantDB queries |
| `app/flutter/lib/widgets/profile_panel.dart` | New — modal panel with History + Profile tabs |
| `app/flutter/lib/screens/greeting_screen.dart` | Add menu icon (top-right) to trigger panel |
| `app/flutter/lib/screens/playback_screen.dart` | Same |
| `app/flutter/lib/main.dart` | Pass `childId` + `apiBase` to screens that open panel |

---

## Verification

1. `npm test` in `api/` — all tests pass including new `/child/:childId` test
2. Run Flutter on Pixel: greeting screen shows menu icon top-right
3. Tap icon → panel slides up with two tabs
4. History tab shows Lisa's 3 seeded sessions (title, date, characters)
5. Profile tab shows name=Lisa, age=4, favorites=dragon+owl, fears=thunder etc.
6. Profile tab debug section shows dynamic variables matching what `/agent/session` returns
7. Panel dismisses on swipe down or tap outside
