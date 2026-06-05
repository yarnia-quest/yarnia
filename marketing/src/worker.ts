// Yarnia marketing worker: serves the static landing page (Static Assets) and nothing else.
// The waitlist signup is written CLIENT-SIDE from the page via @instantdb/core (guest, create-only
// permission), so this worker holds NO secret. The admin token lives only in schema-migration CI.
// Docs: https://developers.cloudflare.com/workers/static-assets/
interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return env.ASSETS.fetch(request);
  },
};
