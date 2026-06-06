import React, { useMemo } from 'react';
import { View, StyleSheet } from 'react-native';

const STAR_COUNT = 80;

function seededRandom(seed: number) {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return (s >>> 0) / 0xffffffff;
  };
}

export default function Starfield() {
  const stars = useMemo(() => {
    const rand = seededRandom(42);
    return Array.from({ length: STAR_COUNT }, (_, i) => ({
      id: i,
      top: `${rand() * 100}%`,
      left: `${rand() * 100}%`,
      size: rand() * 2 + 1,
      opacity: rand() * 0.6 + 0.2,
    }));
  }, []);

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {stars.map((s) => (
        <View
          key={s.id}
          style={{
            position: 'absolute',
            top: s.top as any,
            left: s.left as any,
            width: s.size,
            height: s.size,
            borderRadius: s.size / 2,
            backgroundColor: '#fff',
            opacity: s.opacity,
          }}
        />
      ))}
    </View>
  );
}
