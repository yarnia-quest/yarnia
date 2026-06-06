import { init } from "@instantdb/react";

const db = init({ appId: import.meta.env.PUBLIC_INSTANT_APP_ID ?? "" });

export default db;
