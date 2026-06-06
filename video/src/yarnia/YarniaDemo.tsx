import {
  AbsoluteFill,
  Audio,
  Sequence,
  interpolate,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { cream, gold, navy } from "./theme";
import { Starfield } from "./Starfield";
import { Orb, OrbMode } from "./Orb";
import { Caption } from "./Caption";
import { segments, INTRO, outroFrom, OUTRO, storyEnd } from "./timeline";

const serif = "Georgia, 'Times New Roman', serif";

// The full Yarnia demo: greeting -> memory recall -> a calm story beat -> auto-sleep goodnight
// -> brand outro. The visuals recreate the real app (starfield + pulsing orb + soft captions).
export const YarniaDemo: React.FC = () => {
  const frame = useCurrentFrame();

  // Orb state follows whoever is speaking: gold + lively for Yarnia, gentle cream on the
  // child's turn (and during the quiet gaps).
  let orbMode: OrbMode = "listening";
  for (const s of segments) {
    if (frame >= s.from && frame < s.from + s.dur) {
      orbMode = s.speaker === "yarnia" ? "speaking" : "listening";
    }
  }

  // The whole scene dims gently to black for the outro (the child has drifted off).
  const outroDim = interpolate(frame, [outroFrom, outroFrom + 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ backgroundColor: navy }}>
      <Starfield />

      {/* Intro: the greeting screen — moon + "Good night, Mira." */}
      <Sequence durationInFrames={INTRO + 12} name="intro">
        <Intro />
      </Sequence>

      {/* The orb appears once the conversation begins and fades before the outro. */}
      <Sequence from={INTRO} durationInFrames={storyEnd - INTRO + 30} name="orb">
        <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
          <Orb mode={orbMode} />
        </AbsoluteFill>
      </Sequence>

      {/* Each spoken line: audio + a synced caption. */}
      {segments.map((s) => (
        <Sequence key={s.id} from={s.from} durationInFrames={s.dur} name={s.id}>
          <Audio src={staticFile(`${s.id}.mp3`)} />
          <Caption text={s.text} speaker={s.speaker} durationInFrames={s.dur} />
        </Sequence>
      ))}

      {/* Dim to night for the ending. */}
      <AbsoluteFill style={{ backgroundColor: navy, opacity: outroDim * 0.96, pointerEvents: "none" }} />

      {/* Outro: brand + tagline. */}
      <Sequence from={outroFrom} durationInFrames={OUTRO} name="outro">
        <Outro />
      </Sequence>
    </AbsoluteFill>
  );
};

const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const fade = interpolate(frame, [0, 18, INTRO - 8, INTRO + 12], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const moonScale = interpolate(frame, [0, 24], [0.7, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", opacity: fade }}>
      <div style={{ fontSize: 200, transform: `scale(${moonScale})` }}>🌙</div>
      <div style={{ height: 48 }} />
      <div style={{ fontFamily: serif, fontSize: 60, fontWeight: 700, color: cream }}>
        Good night, Mira.
      </div>
      <div style={{ height: 16 }} />
      <div style={{ fontFamily: serif, fontSize: 32, color: gold }}>
        Your story is waiting in Yarnia.
      </div>
    </AbsoluteFill>
  );
};

const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const fade = interpolate(frame, [0, 24], [0, 1], { extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", opacity: fade }}>
      <div style={{ fontSize: 120 }}>🌙</div>
      <div style={{ height: 28 }} />
      <div style={{ fontFamily: serif, fontSize: 76, fontWeight: 700, color: cream, letterSpacing: 1 }}>
        Yarnia
      </div>
      <div style={{ height: 20 }} />
      <div style={{ fontFamily: serif, fontSize: 34, color: gold, textAlign: "center", maxWidth: 760, lineHeight: 1.4 }}>
        Bedtime stories that remember your child.
      </div>
    </AbsoluteFill>
  );
};
