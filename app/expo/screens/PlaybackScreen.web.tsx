import React, { useEffect, useRef, useState } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  TouchableOpacity,
  ScrollView,
} from 'react-native';
import { useKeepAwake } from 'expo-keep-awake';
import Starfield from '../components/Starfield';
import { colors, fonts } from '../theme';

type Props = {
  storyText: string | null;
  audioBase64: string | null;
  audioUrl: string | null;
  childName: string;
  onRestart: () => void;
};

export default function PlaybackScreen({
  storyText,
  audioBase64,
  audioUrl,
  childName,
  onRestart,
}: Props) {
  useKeepAwake();

  const dimAnim = useRef(new Animated.Value(0)).current;
  const textFade = useRef(new Animated.Value(0)).current;
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [shared, setShared] = useState(false);

  useEffect(() => {
    Animated.sequence([
      Animated.timing(dimAnim, { toValue: 1, duration: 1500, useNativeDriver: true }),
      Animated.timing(textFade, { toValue: 1, duration: 800, useNativeDriver: true }),
    ]).start();

    playAudio();

    return () => {
      audioRef.current?.pause();
    };
  }, []);

  function playAudio() {
    let src: string | null = null;
    if (audioBase64) src = `data:audio/mpeg;base64,${audioBase64}`;
    else if (audioUrl) src = audioUrl;
    if (!src) return;

    const audio = new window.Audio(src);
    audioRef.current = audio;
    audio.play().catch(() => {});
  }

  async function handleShare() {
    const msg = `Yarnia told ${childName} a bedtime story tonight. 🌙`;
    try {
      await navigator.share?.({ title: 'Yarnia', text: msg, url: 'https://yarnia.quest' });
      setShared(true);
    } catch (_) {}
  }

  return (
    <Animated.View style={[styles.container, { opacity: dimAnim }]}>
      <Starfield />

      <Text style={styles.moonSmall}>🌙</Text>

      <Animated.View style={[styles.textWrap, { opacity: textFade }]}>
        <ScrollView
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.scrollContent}
        >
          <Text style={styles.storyText}>
            {storyText ?? 'Once upon a time, in a land between the last yawn and the first dream…'}
          </Text>
        </ScrollView>
      </Animated.View>

      <Animated.View style={[styles.actions, { opacity: textFade }]}>
        <TouchableOpacity style={styles.shareButton} onPress={handleShare} activeOpacity={0.8}>
          <Text style={styles.shareText}>{shared ? 'Sent ✓' : 'Send to grandma'}</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={onRestart} activeOpacity={0.6}>
          <Text style={styles.again}>Another night →</Text>
        </TouchableOpacity>
      </Animated.View>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.navy,
    alignItems: 'center',
    paddingHorizontal: 32,
    paddingTop: 60,
    paddingBottom: 40,
  },
  moonSmall: { fontSize: 36, marginBottom: 20, opacity: 0.7 },
  textWrap: { flex: 1, width: '100%', maxWidth: 560 },
  scrollContent: { paddingBottom: 16 },
  storyText: {
    fontFamily: fonts.bodyItalic,
    fontSize: 17,
    color: colors.cream,
    lineHeight: 28,
    textAlign: 'center',
    opacity: 0.9,
  },
  actions: { alignItems: 'center', gap: 16, marginTop: 24 },
  shareButton: {
    borderWidth: 1.5,
    borderColor: colors.gold,
    borderRadius: 40,
    paddingVertical: 12,
    paddingHorizontal: 36,
  },
  shareText: { fontFamily: fonts.body, color: colors.gold, fontSize: 15, letterSpacing: 1 },
  again: { fontFamily: fonts.body, color: colors.cream, opacity: 0.4, fontSize: 13 },
});
