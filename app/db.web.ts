// Web: use the proper browser SDK (not the RN one which needs AsyncStorage)
import { init } from "@instantdb/react";

const db = init({ appId: process.env.EXPO_PUBLIC_INSTANT_APP_ID ?? "" });

export default db;
