// Yarnia marketing worker: serves the static landing page (Static Assets) and forwards
// incoming email for hi@yarnia.quest to the team inbox.
// Docs: https://developers.cloudflare.com/workers/static-assets/
//       https://developers.cloudflare.com/email-routing/email-workers/
interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return env.ASSETS.fetch(request);
  },

  async email(message: ForwardableEmailMessage): Promise<void> {
    await Promise.all([
      message.forward("burhanyasar@gmail.com"),
      message.forward("cansinyildiz@gmail.com"),
    ]);
  },
};
