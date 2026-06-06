import preact from "@astrojs/preact";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, fontProviders } from "astro/config";

const google = fontProviders.google();

export default defineConfig({
  output: "static",
  integrations: [preact()],
  fonts: [
    {
      name: "Fraunces",
      cssVariable: "--font-fraunces",
      provider: google,
      weights: [400, 700],
      styles: ["normal", "italic"],
    },
    {
      name: "Lora",
      cssVariable: "--font-lora",
      provider: google,
      weights: [400, 700],
      styles: ["normal", "italic"],
    },
  ],
  vite: {
    plugins: [tailwindcss()],
    resolve: {
      alias: {
        react: "preact/compat",
        "react-dom": "preact/compat",
        "react/jsx-runtime": "preact/jsx-runtime",
      },
      dedupe: ["preact", "preact/hooks"],
    },
  },
});
