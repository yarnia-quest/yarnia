import manifestRaw from "./manifest.json";
import { FPS } from "./theme";

// Layout constants (frames @30fps).
export const INTRO = 84; // ~2.8s: moon + "Good night, Mira." (the greeting screen)
export const GAP = 12; // ~0.4s pause between turns
export const TAIL = 24; // beat after the last "night night" before the outro
export const OUTRO = 138; // ~4.6s: logo + tagline

export type Speaker = "yarnia" | "kid";
export type Segment = {
  id: string;
  speaker: Speaker;
  text: string;
  from: number; // absolute start frame
  dur: number; // frames
};

type ManifestEntry = { id: string; speaker: string; text: string; durationInSeconds: number };
const manifest = manifestRaw as ManifestEntry[];

// Lay each speech clip back-to-back after the intro, with a small gap between turns.
export const segments: Segment[] = (() => {
  let cursor = INTRO;
  return manifest.map((m) => {
    const dur = Math.ceil(m.durationInSeconds * FPS);
    const seg: Segment = { id: m.id, speaker: m.speaker as Speaker, text: m.text, from: cursor, dur };
    cursor += dur + GAP;
    return seg;
  });
})();

export const storyEnd = segments.length
  ? segments[segments.length - 1].from + segments[segments.length - 1].dur
  : INTRO;
export const outroFrom = storyEnd + TAIL;
export const totalFrames = outroFrom + OUTRO;
