import React, { useState, useRef, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Animated,
  Platform,
  ActivityIndicator,
} from 'react-native';
import Starfield from '../components/Starfield';
import { colors, fonts } from '../theme';

const CHIPS = ['a dragon', 'an owl', 'a fox', 'a little bear'];

type Props = {
  childName: string;
  onChoice: (choice: string) => void;
};

export default function CoCreationScreen({ childName, onChoice }: Props) {
  const [listening, setListening] = useState(false);
  const [transcript, setTranscript] = useState('');
  const [loading, setLoading] = useState(false);
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const recogRef = useRef<any>(null);

  useEffect(() => {
    if (listening) {
      Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, { toValue: 1.25, duration: 700, useNativeDriver: true }),
          Animated.timing(pulseAnim, { toValue: 1, duration: 700, useNativeDriver: true }),
        ])
      ).start();
    } else {
      pulseAnim.stopAnimation();
      pulseAnim.setValue(1);
    }
  }, [listening]);

  function startListening() {
    if (Platform.OS !== 'web') return;
    const SpeechRecognition =
      (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (!SpeechRecognition) return;

    const recog = new SpeechRecognition();
    recog.lang = 'en-US';
    recog.interimResults = true;
    recog.continuous = false;
    recogRef.current = recog;

    recog.onresult = (e: any) => {
      const t = Array.from(e.results)
        .map((r: any) => r[0].transcript)
        .join('');
      setTranscript(t);
    };

    recog.onend = () => {
      setListening(false);
      if (transcript) handleChoice(transcript);
    };

    recog.start();
    setListening(true);
    setTranscript('');
  }

  function stopListening() {
    recogRef.current?.stop();
    setListening(false);
  }

  function handleChoice(choice: string) {
    setLoading(true);
    onChoice(choice);
  }

  return (
    <View style={styles.container}>
      <Starfield />

      <Text style={styles.question}>
        Who's in tonight's story,{'\n'}{childName}?
      </Text>

      {/* mic button */}
      <TouchableOpacity
        style={styles.micWrap}
        onPress={listening ? stopListening : startListening}
        activeOpacity={0.8}
        disabled={loading}
      >
        <Animated.View style={[styles.micRing, { transform: [{ scale: pulseAnim }] }]} />
        <View style={styles.micButton}>
          <Text style={styles.micIcon}>{listening ? '⏹' : '🎙'}</Text>
        </View>
      </TouchableOpacity>

      {transcript ? (
        <Text style={styles.transcript}>"{transcript}"</Text>
      ) : (
        <Text style={styles.orLabel}>— or pick one —</Text>
      )}

      {/* tap chips */}
      <View style={styles.chips}>
        {CHIPS.map((chip) => (
          <TouchableOpacity
            key={chip}
            style={styles.chip}
            onPress={() => handleChoice(chip)}
            disabled={loading}
            activeOpacity={0.75}
          >
            <Text style={styles.chipText}>{chip}</Text>
          </TouchableOpacity>
        ))}
      </View>

      {loading && <ActivityIndicator color={colors.gold} style={{ marginTop: 32 }} />}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.navy,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 32,
  },
  question: {
    fontFamily: fonts.display,
    fontSize: 26,
    color: colors.cream,
    textAlign: 'center',
    marginBottom: 40,
    lineHeight: 36,
  },
  micWrap: {
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 24,
    width: 88,
    height: 88,
  },
  micRing: {
    position: 'absolute',
    width: 88,
    height: 88,
    borderRadius: 44,
    borderWidth: 2,
    borderColor: colors.gold,
    opacity: 0.4,
  },
  micButton: {
    width: 68,
    height: 68,
    borderRadius: 34,
    backgroundColor: colors.navyLight,
    borderWidth: 1.5,
    borderColor: colors.gold,
    alignItems: 'center',
    justifyContent: 'center',
  },
  micIcon: {
    fontSize: 28,
  },
  transcript: {
    fontFamily: fonts.bodyItalic,
    color: colors.gold,
    fontSize: 15,
    marginBottom: 24,
    textAlign: 'center',
  },
  orLabel: {
    fontFamily: fonts.body,
    color: colors.cream,
    opacity: 0.4,
    fontSize: 13,
    marginBottom: 20,
    letterSpacing: 1,
  },
  chips: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'center',
    gap: 10,
  },
  chip: {
    borderWidth: 1,
    borderColor: colors.gold,
    borderRadius: 24,
    paddingVertical: 8,
    paddingHorizontal: 18,
    opacity: 0.85,
  },
  chipText: {
    fontFamily: fonts.body,
    color: colors.gold,
    fontSize: 14,
  },
});
