/** Map an upstream error (status + message + error code) to user-facing copy. */
export function chatErrorMessage(status: number, msg: string, code?: string): string {
  if (code === "free_tokens_exhausted" || code === "promotion_balance_required") {
    return msg;
  }
  if (code === "no_linked_machine") {
    return "No machine linked to your account — run `darkbloom login` on your Mac, then try again.";
  }
  if (code === "machine_offline") {
    return "Your machine is offline — start your Darkbloom node and try again. (Free-only self-route won't fall back to the paid network.)";
  }
  if (code === "model_not_loaded") {
    return "This model isn't loaded on your machine — load it on your node, then try again.";
  }
  if (code === "machine_busy") {
    return "Your machine is busy — try again in a moment.";
  }
  if (status === 503 && msg.includes("queue timeout")) {
    return "All providers are busy — please try again in a moment";
  }
  if (status === 402) {
    return "Insufficient credits — buy credits in Billing to continue";
  }
  return `Request failed (${status}): ${msg}`;
}
