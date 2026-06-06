import { useCurrentFrame } from "remotion";
import { cream, gold, navyLight, FPS } from "./theme";

// Port of the _Orb in app/flutter/lib/screens/agent_screen.dart: a soft glowing sphere that
// pulses gold + faster while Yarnia speaks, and rests cream + gentle on the child's turn.
export type OrbMode = "connecting" | "speaking" | "listening";

const SIZE = 380;

export const Orb: React.FC<{ mode: OrbMode }> = ({ mode }) => {
  const frame = useCurrentFrame();
  const phase = frame / FPS;

  // t in [0,1] drives scale + opacity, mirroring the Flutter pulse math per mode.
  let t: number;
  let color: string;
  if (mode === "connecting") {
    t = 0.5 + 0.5 * Math.sin(phase * Math.PI);
    color = navyLight;
  } else if (mode === "speaking") {
    t = 0.5 + 0.5 * Math.sin(phase * Math.PI * 2); // ~1s period, lively
    color = gold;
  } else {
    t = 0.3 + 0.2 * Math.sin(phase * Math.PI); // gentle, ~2s period
    color = cream;
  }

  const scale = 1 + t * 0.18;
  const opacity = 0.5 + t * 0.5;

  return (
    <div
      style={{
        width: SIZE,
        height: SIZE,
        borderRadius: "50%",
        transform: `scale(${scale})`,
        opacity,
        background: `radial-gradient(circle, ${color} 0%, ${hexToRgba(color, 0)} 70%)`,
        boxShadow: `0 0 120px 30px ${hexToRgba(color, opacity * 0.31)}`,
      }}
    />
  );
};

function hexToRgba(hex: string, alpha: number): string {
  const h = hex.replace("#", "");
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
