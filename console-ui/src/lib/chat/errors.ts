// User-facing copy for upstream chat failures. Split out of stream.ts so the
// mapping is unit-testable on its own (see __tests__/chat-error-message.test.ts).

/** The OpenAI-shaped error object the coordinator returns on a failure. */
export type UpstreamError = { message?: string; code?: string };

/**
 * Self-route outcomes the coordinator names with a stable code. These are
 * deterministic states of the caller's own machine, so the console explains the
 * machine rather than echoing the API copy.
 */
const SELF_ROUTE_COPY: Record<string, string> = {
  no_linked_machine:
    "No machine linked to your account — run `darkbloom login` on your Mac, then try again.",
  machine_offline:
    "Your machine is offline — start your Darkbloom node and try again. (Free-only self-route won't fall back to the paid network.)",
  model_not_loaded:
    "This model isn't loaded on your machine — load it on your node, then try again.",
  machine_busy: "Your machine is busy — try again in a moment.",
};

/** Server copy leads lower-case; the console renders it as a sentence. */
function asSentence(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** Map an upstream failure (status + error object + raw body) to display copy. */
export function chatErrorMessage(
  status: number,
  rawBody: string,
  error?: UpstreamError,
): string {
  const code = error?.code ?? "";
  if (SELF_ROUTE_COPY[code]) {
    return SELF_ROUTE_COPY[code];
  }
  const detail = (error?.message ?? "").trim();
  if (status === 503 && (detail || rawBody).includes("queue timeout")) {
    return "All providers are busy — please try again in a moment";
  }
  if (status === 402) {
    // Every coordinator 402 already names the actual blocker and its fix: an
    // exhausted per-key spend cap, a prompt that outruns the balance, or — with
    // "My Machine" on — a machine that couldn't take the request while the
    // balance couldn't fund the paid fallback. Collapsing all of those into
    // "buy credits" points most of them at a page that cannot help.
    return detail
      ? asSentence(detail)
      : "Insufficient credits — buy credits in Billing to continue";
  }
  return `Request failed (${status}): ${detail || rawBody}`;
}
