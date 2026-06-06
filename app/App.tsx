import 'react-native-get-random-values';
import React, { useState, useCallback } from 'react';
import { View, StyleSheet, ActivityIndicator } from 'react-native';
import {
  useFonts,
  Fraunces_700Bold,
  Fraunces_700Bold_Italic,
} from '@expo-google-fonts/fraunces';
import { Lora_400Regular, Lora_400Regular_Italic } from '@expo-google-fonts/lora';
import { StatusBar } from 'expo-status-bar';

import GreetingScreen from './screens/GreetingScreen';
import CoCreationScreen from './screens/CoCreationScreen';
import PlaybackScreen from './screens/PlaybackScreen';
import { colors } from './theme';

const API_BASE = process.env.EXPO_PUBLIC_API_BASE_URL ?? 'http://localhost:8787';

// Seeded child for demo — matches the "Lisa" seed in InstantDB
const DEMO_CHILD = { id: 'lisa-seed', name: 'Lisa' };

type Screen = 'greeting' | 'cocreation' | 'playback';

type StoryResult = {
  text: string | null;
  audio: string | null;
  audioUrl: string | null;
};

export default function App() {
  const [fontsLoaded] = useFonts({
    Fraunces_700Bold,
    Fraunces_700Bold_Italic,
    Lora_400Regular,
    Lora_400Regular_Italic,
  });

  const [screen, setScreen] = useState<Screen>('greeting');
  const [story, setStory] = useState<StoryResult | null>(null);

  const handleChoice = useCallback(async (choice: string) => {
    setScreen('playback');
    try {
      const res = await fetch(`${API_BASE}/story`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ childId: DEMO_CHILD.id, choice }),
      });
      const data = await res.json();
      setStory({
        text: data.text ?? null,
        audio: data.audio ?? null,
        audioUrl: data.audioUrl ?? null,
      });
    } catch (e) {
      setStory({ text: null, audio: null, audioUrl: null });
    }
  }, []);

  const handleRestart = useCallback(() => {
    setStory(null);
    setScreen('greeting');
  }, []);

  if (!fontsLoaded) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.gold} />
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <StatusBar style="light" />
      {screen === 'greeting' && (
        <GreetingScreen
          childName={DEMO_CHILD.name}
          onBegin={() => setScreen('cocreation')}
        />
      )}
      {screen === 'cocreation' && (
        <CoCreationScreen
          childName={DEMO_CHILD.name}
          onChoice={handleChoice}
        />
      )}
      {screen === 'playback' && (
        <PlaybackScreen
          childName={DEMO_CHILD.name}
          storyText={story?.text ?? null}
          audioBase64={story?.audio ?? null}
          audioUrl={story?.audioUrl ?? null}
          onRestart={handleRestart}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.navy },
  loading: { flex: 1, backgroundColor: colors.navy, alignItems: 'center', justifyContent: 'center' },
});
