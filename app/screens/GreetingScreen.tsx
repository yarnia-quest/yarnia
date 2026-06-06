import React, { useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Animated,
  TouchableOpacity,
  Dimensions,
} from 'react-native';
import { useKeepAwake } from 'expo-keep-awake';
import Starfield from '../components/Starfield';
import { colors, fonts } from '../theme';

const { width } = Dimensions.get('window');

type Props = {
  childName: string;
  onBegin: () => void;
};

export default function GreetingScreen({ childName, onBegin }: Props) {
  useKeepAwake();

  const moonScale = useRef(new Animated.Value(0.7)).current;
  const fadeIn = useRef(new Animated.Value(0)).current;
  const textFade = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.sequence([
      Animated.parallel([
        Animated.spring(moonScale, { toValue: 1, friction: 6, useNativeDriver: true }),
        Animated.timing(fadeIn, { toValue: 1, duration: 1200, useNativeDriver: true }),
      ]),
      Animated.timing(textFade, { toValue: 1, duration: 800, delay: 200, useNativeDriver: true }),
    ]).start();
  }, []);

  return (
    <View style={styles.container}>
      <Starfield />

      <Animated.View style={[styles.moon, { transform: [{ scale: moonScale }], opacity: fadeIn }]}>
        <Text style={styles.moonEmoji}>🌙</Text>
      </Animated.View>

      <Animated.View style={[styles.textBlock, { opacity: textFade }]}>
        <Text style={styles.greeting}>Good night, {childName}.</Text>
        <Text style={styles.sub}>Ready for tonight's story?</Text>
      </Animated.View>

      <Animated.View style={{ opacity: textFade }}>
        <TouchableOpacity style={styles.button} onPress={onBegin} activeOpacity={0.8}>
          <Text style={styles.buttonText}>Begin</Text>
        </TouchableOpacity>
      </Animated.View>
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
  moon: {
    marginBottom: 32,
  },
  moonEmoji: {
    fontSize: width < 400 ? 72 : 96,
  },
  textBlock: {
    alignItems: 'center',
    marginBottom: 48,
  },
  greeting: {
    fontFamily: fonts.display,
    fontSize: 28,
    color: colors.cream,
    textAlign: 'center',
    marginBottom: 10,
  },
  sub: {
    fontFamily: fonts.body,
    fontSize: 16,
    color: colors.gold,
    textAlign: 'center',
    opacity: 0.85,
  },
  button: {
    borderWidth: 1.5,
    borderColor: colors.gold,
    borderRadius: 40,
    paddingVertical: 14,
    paddingHorizontal: 52,
  },
  buttonText: {
    fontFamily: fonts.body,
    color: colors.gold,
    fontSize: 16,
    letterSpacing: 1.5,
  },
});
