// Assembles out/yarnia-realapp-demo.mp4 from a real-app Playwright capture + the committed
// dub clips. This is the reproducible version of the ffmpeg recipe that used to live only as
// prose in README.md (steps 4-5). Run it after capture/record-realapp.mjs has produced a webm.
//
// Pipeline (all deterministic, derived from the measured dub-clip durations so the output is
// always 49.6s like the shipped video):
//   1. Trim the capture's boot + 2x upscale the webm -> vid.mp4 (780x1688, 30fps, silent).
//   2. Slice vid.mp4 into state windows: pre-roll (before the orb), the GOLD orb window
//      ("Yarnia is speaking") and the CREAM orb window ("Your turn...").
//   3. Build a state-matched visual track by concatenating: pre-roll + gold(greeting) +
//      cream(kid, looped) + gold(story, looped), so each voice plays only over its matching orb.
//   4. Lay the three dub clips on at their offsets (adelay + amix) and mux onto the visual track.
//
// The orb is a turn-state indicator, so keeping audio and orb color in sync is the whole point:
// Yarnia's voice only over gold, the child's only over cream, and the long story loops the gold
// window (same color, so the only seam is the orb's own pulse, never a state jump).
//
// Usage:
//   node scripts/build-realapp-demo.mjs [webm]
// Env overrides (all optional):
//   WEBM       path to the capture webm (default: newest /tmp/ywcap/videos/*.webm)
//   MARKS      path to capture marks.json (default: /tmp/ywcap/marks.json) - used for orb timing
//   OUT        output path (default: out/yarnia-realapp-demo.mp4)
//   FFMPEG     ffmpeg binary (default: ffmpeg)
//   FFPROBE    ffprobe binary (default: ffprobe)
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const videoDir = resolve(here, ".."); // video/
const publicDir = resolve(videoDir, "public");

const FFMPEG = process.env.FFMPEG || "ffmpeg";
const FFPROBE = process.env.FFPROBE || "ffprobe";
const OUT = process.env.OUT || resolve(videoDir, "out", "yarnia-realapp-demo.mp4");
const MARKS = process.env.MARKS || "/tmp/ywcap/marks.json";

// --- Capture-shape constants (vid.mp4 timeline, i.e. after the boot trim). These describe the
// current app flow; if the UI/agent timing moves, adjust here (see README "Real-app capture"). ---
const BOOT_TRIM = 5; // seconds of Flutter boot to skip at the head of the webm
const CAPTURE_LEN = 25; // seconds of capture to keep (covers onboarding -> orb)
const SCALE = "780:1688"; // 2x the 390x844 capture viewport
const FPS = 30;
const GOLD_LEN = 9.1; // length of the captured GOLD ("Yarnia speaking") window
const CREAM_GAP = 0.2; // gap between the gold window ending and cream starting in the capture
const CREAM_LEN = 3.5; // length of the captured CREAM ("Your turn") window
// Small silences between dubbed turns + an outro tail, tuned to match the shipped 49.6s cut.
const GAP_GREETING_KID = 0.45;
const GAP_KID_STORY = 0.31;
const TAIL = 1.0;

const ms = (s) => Math.round(s * 1000);

function run(bin, args) {
  return execFileSync(bin, args, { stdio: ["ignore", "pipe", "pipe"] }).toString();
}
function ff(args) {
  run(FFMPEG, ["-y", "-hide_banner", "-loglevel", "error", ...args]);
}
function probeDuration(file) {
  const out = run(FFPROBE, [
    "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file,
  ]);
  const d = parseFloat(out.trim());
  if (!Number.isFinite(d)) throw new Error(`could not probe duration of ${file}`);
  return d;
}

function newestWebm() {
  const dir = "/tmp/ywcap/videos";
  if (!existsSync(dir)) return null;
  const webms = readdirSync(dir)
    .filter((f) => f.endsWith(".webm"))
    .map((f) => resolve(dir, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return webms[0] || null;
}

const webm = process.argv[2] || process.env.WEBM || newestWebm();
if (!webm || !existsSync(webm)) {
  throw new Error(
    `No capture webm found. Run capture/record-realapp.mjs first, or pass a path / set WEBM. (looked for ${webm})`,
  );
}

// Orb appearance in the vid.mp4 timeline. Prefer the captured mark when present; the capture logs
// orbAppear relative to navigation start, and vid.mp4 drops the first BOOT_TRIM seconds.
let orbAt = 12.2;
if (existsSync(MARKS)) {
  try {
    const m = JSON.parse(readFileSync(MARKS, "utf8"));
    const a = parseFloat(m?.marks?.orbAppear);
    if (Number.isFinite(a)) orbAt = Math.max(0, a - BOOT_TRIM);
  } catch {
    /* fall back to the default */
  }
}

const greetingDur = probeDuration(resolve(publicDir, "realapp-greeting.mp3"));
const kidDur = probeDuration(resolve(publicDir, "realapp-kid.mp3"));
const storyDur = probeDuration(resolve(publicDir, "realapp-story.mp3"));

// Audio offsets on the final timeline (derived, so the cut always matches the clip lengths).
const greetingAt = orbAt;
const kidAt = greetingAt + greetingDur + GAP_GREETING_KID;
const storyAt = kidAt + kidDur + GAP_KID_STORY;
const total = storyAt + storyDur + TAIL;

// Source windows inside vid.mp4.
const goldSrc = orbAt; // GOLD starts when the orb appears
const creamSrc = orbAt + GOLD_LEN + CREAM_GAP;

// Visual segment target durations.
const prerollLen = greetingAt; // 0 -> orb
const goldGreetingLen = kidAt - greetingAt; // gold under the greeting
const creamKidLen = storyAt - kidAt; // cream under the kid (looped)
const goldStoryLen = total - storyAt; // gold under the story (looped)

const tmp = "/tmp/ywbuild";
rmSync(tmp, { recursive: true, force: true });
mkdirSync(tmp, { recursive: true });
const T = (n) => resolve(tmp, n);

const V = ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-r", String(FPS), "-an"];

console.log(
  `orb@${orbAt.toFixed(2)}s  greeting@${greetingAt.toFixed(2)} kid@${kidAt.toFixed(2)} story@${storyAt.toFixed(2)}  total=${total.toFixed(2)}s`,
);

// 1. Boot trim + upscale -> silent vid.mp4.
ff(["-ss", String(BOOT_TRIM), "-i", webm, "-t", String(CAPTURE_LEN),
  "-vf", `scale=${SCALE}:flags=lanczos,fps=${FPS}`, ...V, T("vid.mp4")]);

// 2. Cut the reusable windows (re-encoded identically so concat is seamless).
ff(["-ss", "0", "-i", T("vid.mp4"), "-t", String(prerollLen), ...V, T("preroll.mp4")]);
ff(["-ss", String(goldSrc), "-i", T("vid.mp4"), "-t", String(GOLD_LEN), ...V, T("gold.mp4")]);
ff(["-ss", String(creamSrc), "-i", T("vid.mp4"), "-t", String(CREAM_LEN), ...V, T("cream.mp4")]);

// 3. Build the state-matched segments (loop the short windows to cover the longer turns).
const loops = (target, src) => Math.ceil(target / src); // -stream_loop count
ff(["-i", T("gold.mp4"), "-t", String(goldGreetingLen), ...V, T("seg-greeting.mp4")]);
ff(["-stream_loop", String(loops(creamKidLen, CREAM_LEN)), "-i", T("cream.mp4"),
  "-t", String(creamKidLen), ...V, T("seg-kid.mp4")]);
ff(["-stream_loop", String(loops(goldStoryLen, GOLD_LEN)), "-i", T("gold.mp4"),
  "-t", String(goldStoryLen), ...V, T("seg-story.mp4")]);

// Concatenate the four segments into one silent visual track.
const concatList = ["preroll.mp4", "seg-greeting.mp4", "seg-kid.mp4", "seg-story.mp4"]
  .map((f) => `file '${T(f)}'`).join("\n");
const { writeFileSync } = await import("node:fs");
writeFileSync(T("concat.txt"), concatList);
ff(["-f", "concat", "-safe", "0", "-i", T("concat.txt"), ...V, T("visual.mp4")]);

// 4. Mix the three dub clips at their offsets, then mux onto the visual track.
ff([
  "-i", resolve(publicDir, "realapp-greeting.mp3"),
  "-i", resolve(publicDir, "realapp-kid.mp3"),
  "-i", resolve(publicDir, "realapp-story.mp3"),
  "-filter_complex",
  `[0]adelay=${ms(greetingAt)}|${ms(greetingAt)}[g];` +
    `[1]adelay=${ms(kidAt)}|${ms(kidAt)}[k];` +
    `[2]adelay=${ms(storyAt)}|${ms(storyAt)}[s];` +
    `[g][k][s]amix=inputs=3:normalize=0,apad,atrim=0:${total.toFixed(3)}[a]`,
  "-map", "[a]", "-c:a", "aac", "-b:a", "160k", T("audio.m4a"),
]);

mkdirSync(dirname(OUT), { recursive: true });
ff([
  "-i", T("visual.mp4"), "-i", T("audio.m4a"),
  "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "copy",
  "-movflags", "+faststart", "-shortest", OUT,
]);

console.log(`wrote ${OUT}  (${probeDuration(OUT).toFixed(2)}s)`);
