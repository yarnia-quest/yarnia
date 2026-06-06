// Native (iOS/Android): uses MMKV for fast local storage
import { init } from "@instantdb/react-native-mmkv";

const db = init({ appId: process.env.EXPO_PUBLIC_INSTANT_APP_ID ?? "" });

export default db;
