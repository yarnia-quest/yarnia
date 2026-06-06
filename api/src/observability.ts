// Minimal observability: structured JSON logs for errors and product analytics events, plus
// optional fire-and-forget forwarding to a webhook (e.g. a logging/analytics collector or a
// Sentry-compatible relay) when configured. Kept dependency-free and injectable so it costs
// nothing in tests and never throws into the request path.

export type Telemetry = {
  error: (event: string, detail?: Record<string, unknown>) => void;
  track: (event: string, props?: Record<string, unknown>) => void;
};

export type TelemetryOpts = {
  errorWebhook?: string;
  analyticsWebhook?: string;
  fetch?: typeof fetch;
  // Lets the caller schedule the POST so it doesn't block the response (Workers waitUntil).
  defer?: (p: Promise<unknown>) => void;
};

export function createTelemetry(opts: TelemetryOpts = {}): Telemetry {
  const doFetch = opts.fetch ?? fetch;
  const defer = opts.defer ?? (() => {});

  const post = (url: string, payload: unknown) => {
    try {
      defer(
        doFetch(url, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(payload),
        }).catch(() => {}),
      );
    } catch {
      /* never let telemetry break the request */
    }
  };

  return {
    error(event, detail = {}) {
      const record = { level: "error", event, ts: Date.now(), ...detail };
      console.error(JSON.stringify(record));
      if (opts.errorWebhook) post(opts.errorWebhook, record);
    },
    track(event, props = {}) {
      const record = { level: "info", event, ts: Date.now(), ...props };
      console.log(JSON.stringify(record));
      if (opts.analyticsWebhook) post(opts.analyticsWebhook, record);
    },
  };
}
