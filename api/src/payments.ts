// Mollie payments: create a hosted checkout for the EUR 8/month Yarnia subscription.
// Docs: https://docs.mollie.com/reference/v2/payments-api/create-payment
// `fetch` is injectable so the flow is unit-testable with no key and no real charge.

export type CheckoutOpts = {
  apiKey: string;
  amount?: string; // decimal string, e.g. "8.00"
  description?: string;
  redirectUrl: string;
  webhookUrl?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
};

export type CheckoutResult = { checkoutUrl: string; paymentId: string };

const DEFAULT_BASE_URL = "https://api.mollie.com";

export async function createCheckout(opts: CheckoutOpts): Promise<CheckoutResult> {
  const doFetch = opts.fetch ?? fetch;
  const baseUrl = opts.baseUrl ?? DEFAULT_BASE_URL;

  const body: Record<string, unknown> = {
    amount: { currency: "EUR", value: opts.amount ?? "8.00" },
    description: opts.description ?? "Yarnia — monthly bedtime stories",
    redirectUrl: opts.redirectUrl,
  };
  if (opts.webhookUrl) body.webhookUrl = opts.webhookUrl;

  const res = await doFetch(`${baseUrl}/v2/payments`, {
    method: "POST",
    headers: { authorization: `Bearer ${opts.apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`Mollie payment failed: ${res.status}${detail ? ` (${detail.slice(0, 200)})` : ""}`);
  }

  const data = (await res.json()) as { id?: string; _links?: { checkout?: { href?: string } } };
  const checkoutUrl = data?._links?.checkout?.href;
  if (!checkoutUrl) throw new Error("Mollie response missing checkout url");
  return { checkoutUrl, paymentId: data.id ?? "" };
}
