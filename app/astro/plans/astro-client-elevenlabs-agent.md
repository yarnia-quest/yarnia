# Plan: Yarnia Astro Client — ElevenLabs Agent Integration

## Context

The current Astro client uses `POST /story` with manual chip selection and Web Speech API for co-creation, then plays back a base64 audio blob. This misses the product's core UX:

- **Screen-off, voice-first** — the screen should go dark; the voice takes over
- **The memory moment** — the agent greets Lisa by name and references last night's story ("Another dragon story? I'll keep the thunder out."). This is the demo hook that wins the room.
- **The API already has `/agent/session`** — returns a signed ElevenLabs WebSocket URL + child's dynamic variables. The client should use it.

The ElevenLabs conversational agent handles the ENTIRE experience in one voice session: greeting by name (with memory injected), one co-creation question, full story narration, goodbye. The chip UI + Web Speech fallback stays for when mic isn't available.

The user confirmed: "we will use ElevenLabs" and "client can directly connect" — meaning `/agent/session` gives the client a signed URL, then the client opens a WebSocket directly to ElevenLabs. Server is only needed for the bootstrap (loads child memory, fetches signed URL).

---

## What changes

### 1. Add `@elevenlabs/react` to package.json

```json
"@elevenlabs/react": "^0.15.0"
```

This provides `useConversation` hook — the only thing needed on the client side.

### 2. New `AgentScreen.tsx` component

Handles the full ElevenLabs agent session:

```
On mount:
  → fetch GET /agent/session?childId=lisa-seed
  → get { agentId, dynamicVariables, signedUrl }
  → useConversation().startSession({ signedUrl }) OR { agentId, dynamicVariables }

Visuals (screen is near-black):
  → large soft pulsing orb: gold when agent is speaking, cream when child's turn
  → tiny status line: "Yarnia is speaking…" / "Your turn…"
  → very subtle "end" button bottom-center

On session end:
  → transition to a soft "The end ✨" moment
  → "Another night →" restart
```

Key `useConversation` API:
- `conversation.startSession({ signedUrl })` — preferred (server already fetched it)
- `conversation.startSession({ agentId, dynamicVariables })` — fallback if signedUrl is null
- `conversation.status` — "connecting" | "connected" | "disconnected"
- `conversation.isSpeaking` — drives the orb animation

### 3. Restructure `YarniaApp.tsx`

New screen flow:

```
greeting → connecting → agent → done
                ↓ (fallback if agent fails)
           cocreation → loading → playback
```

- **greeting**: same as now (Hello Lisa, Begin button)
- **connecting**: new — full dark screen, soft spinner, "Preparing your story…" (fires `/agent/session` call)
- **agent**: new AgentScreen — dim overlay, pulsing orb, voice takes over
- **done**: "The end ✨" + "Another night →"
- **fallback path**: if `/agent/session` fails or mic permission denied → fall through to current chip UI → `POST /story` → playback

### 4. Screen dimming

When entering `connecting` or `agent` screens, a near-black overlay (`rgba(0,0,0,0.88)`) fades in over 1.5s. Starfield stays visible beneath (opacity: 0.3). This is the "screen-off" product moment.

Add to `index.astro` global styles:
```css
.dim-overlay {
  position: fixed; inset: 0;
  background: rgba(18, 19, 42, 0.88);
  transition: opacity 1.5s ease;
  pointer-events: none;
}
```

### 5. Orb animation (AgentScreen)

Single centered element. CSS only.

```css
.orb {
  width: 120px; height: 120px;
  border-radius: 50%;
  background: radial-gradient(circle, var(--color-gold), transparent);
  animation: breathe 2s ease-in-out infinite;
}
.orb--listening {
  background: radial-gradient(circle, var(--color-cream), transparent);
  animation: breathe 3s ease-in-out infinite;
}
@keyframes breathe {
  0%, 100% { transform: scale(1); opacity: 0.6; }
  50% { transform: scale(1.15); opacity: 1; }
}
```

---

## Files to modify

| File | Change |
|------|--------|
| `app/astro/package.json` | add `@elevenlabs/react` |
| `app/astro/src/components/YarniaApp.tsx` | new screen states: connecting, agent, done; fallback path kept |
| `app/astro/src/components/AgentScreen.tsx` | **new** — full ElevenLabs agent session component |
| `app/astro/src/pages/index.astro` | add dim-overlay + orb CSS |
| `app/astro/src/styles/global.css` | minor (no font changes needed) |

---

## What stays

- Chip fallback (dragon/owl/fox/bear) — used when agent fails or mic denied
- `POST /story` path — fallback narration
- `db.ts` with `@instantdb/react` — ready for future use (signups, etc.)
- Starfield, fonts, brand colours — unchanged

---

## Verification

1. `cd app/astro && npm install && npx astro dev`
2. Open `http://localhost:4321` — Greeting screen shows "Hello, Lisa"
3. Click Begin → dim overlay fades in → "Preparing your story…"
4. Agent connects → orb pulses gold → hear: *"Hello Lisa, I remember you loved dragons last time…"*
5. Child speaks a choice → orb shifts to cream (listening)
6. Story plays → orb pulses as agent speaks
7. Session ends → "The end ✨" → "Another night →"
8. Kill the API to test fallback → chips appear instead
