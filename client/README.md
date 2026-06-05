# client — Yarnia app (Expo / React Native)

Built **June 6** (the product). The screen-off bedtime UI: greets the child, light co-creation, ElevenLabs narration, "send to grandma" share. Talks to `server/` and persists to InstantDB.

- Build plan + scope + demo script: `ideation/YARNIA.md`
- Config/secrets: repo-root `.env` (mirrored to GitHub repo secrets for CI). Never hardcode the InstantDB admin token here; the public `INSTANT_APP_ID` is fine client-side.
