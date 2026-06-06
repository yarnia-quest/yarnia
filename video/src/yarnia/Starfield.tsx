import { random, useCurrentFrame, useVideoConfig, AbsoluteFill } from "remotion";
import { FPS } from "./theme";

// Port of app/flutter/lib/widgets/starfield.dart: 80 softly twinkling stars on the night sky.
// Star fields are deterministic via Remotion's seeded random() so every render is identical.
const STAR_COUNT = 80;

const STARS = Array.from({ length: STAR_COUNT }, (_, i) => ({
  x: random(`x-${i}`),
  y: random(`y-${i}`),
  size: random(`s-${i}`) * 2 + 0.8,
  opacity: random(`o-${i}`) * 0.6 + 0.2,
  phase: random(`p-${i}`),
}));

export const Starfield: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  // 3-second twinkle cycle, matching the Flutter AnimationController.
  const t = (frame / (3 * FPS)) % 1;

  return (
    <AbsoluteFill>
      {STARS.map((s, i) => {
        const twinkle = (Math.sin((t + s.phase) * 2 * Math.PI) + 1) / 2;
        const opacity = s.opacity * (0.4 + 0.6 * twinkle);
        return (
          <div
            key={i}
            style={{
              position: "absolute",
              left: s.x * width,
              top: s.y * height,
              width: s.size * 1.6,
              height: s.size * 1.6,
              borderRadius: "50%",
              backgroundColor: "white",
              opacity,
            }}
          />
        );
      })}
    </AbsoluteFill>
  );
};
