# Yarnia

> Open the app. Screen goes off. It talks to you.

An audio-first companion for the moments that matter — bedtime, wind-down, presence. No feed. No scroll. Just a voice in the dark that knows what you need.

## What it does

You open Yarnia. The screen turns off. A voice greets you based on the time, your history, and the moment. It offers:

- **Bedtime stories** — personalized for your child, with remembered characters and preferences
- **Adult wind-down stories** — fantasy, calm, narrative
- **Ambient soundscapes** — rain, ocean, forest, fire
- **Guided relaxation** — short, conversational, not preachy
- **Novel suggestions** — *"You usually like the forest. A lot of people loved this ocean meditation this week — want to try it?"*

It remembers. It adapts. It knows when to shut up.

## The pitch

Every consumer app in 2026 is optimizing for your attention. Yarnia optimizes for your presence. The phone becomes a voice in the dark instead of a screen stealing your night.

## Why this works

**The buyer**: a parent at 8pm, kid in bed, trying to get them to sleep. Not "families broadly." That person exists every single night. You can picture them.

**The price**: €8/month. Below the "do I really need this" threshold — Spotify is €10, Calm is €8. A number you can say out loud without hesitation.

**The gap**: no competitor combines all three.
- Calm: you stare at it
- Spotify Sleep: not personalized
- ChatGPT: general assistant, requires typing, not a bedtime ritual

**The moat**: the memory layer — it knows your kid. After 3 uses it knows Lisa likes dragons, gets scared of thunder, and fell asleep faster when the story had a cat in it. That data — preferences, what worked, what didn't — becomes harder to leave the longer you use it. Switching to ChatGPT means starting over.

## Stack

- **Frontend**: Flutter (Dart)
- **DB / Auth / Realtime / Storage**: InstantDB
- **Voice / TTS**: ElevenLabs
- **Story generation**: OpenAI or Qwen (hackathon sponsors)
- **Backend**: Cloudflare Worker (thin layer — calls LLM + ElevenLabs, uploads audio to InstantDB, returns URL)

## Hackathon scope (June 6, 2026)

**The demo arc:**

1. Open app → screen dims → voice greets you
2. Agent asks what you need tonight — story, soundscape, or something else
3. Conversational co-creation — agent asks back: "any ideas? a forest? a city? two characters?" — rough summary approval before generating: *"how about an owl and a cat lost in Hamburg?"*
4. Story generated + narrated via ElevenLabs
5. Session saved — replayable, shareable link
6. Send to grandma — she opens the link, hears the story

**The pitch moment:**

At the end of the hackathon demo, say out loud:
> *"Yarnia, we're about to pitch you to some judges. Give us a one-minute intro."*

It introduces itself. Live. That's the demo.

**Must ship:**
- [ ] Voice greeting on open
- [ ] Conversational intent + co-creation loop
- [ ] LLM story generation + ElevenLabs narration
- [ ] Session saved to InstantDB
- [ ] Shareable link

**Stretch:**
- [ ] Ambient soundscapes via ElevenLabs
- [ ] Memory layer (preferences per child)
- [ ] Public publishing

## Team

- Burhan Yasar
- Cansin Yildiz
---

*Built at AI BEAVERS x Mollie Founder Hackathon, Hamburg, June 6 2026*
