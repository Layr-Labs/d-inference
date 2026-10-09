import type { BankWithdrawalQuote } from "@/lib/api";
import { validBankAmount } from "./bank-withdrawal-format";

// This contains the original confirmation identity, never a Stripe credential
// or full bank details. Account scoping prevents another login from replaying it.
function recoveryKey(accountId: string): string {
  if (!accountId) throw new Error("Reload your payout details before withdrawing.");
  return `darkbloom:bank-withdrawal:v1:${accountId}`;
}

function validQuote(value: unknown): value is BankWithdrawalQuote {
  if (!value || typeof value !== "object") return false;
  const q = value as Partial<BankWithdrawalQuote>;
  return typeof q.id === "string" && q.id.length > 0 && q.id.length < 100
    && typeof q.amount_usd === "string" && validBankAmount(q.amount_usd)
    && typeof q.fee_usd === "string"
    && typeof q.currency === "string" && /^[a-z]{3}$/i.test(q.currency)
    && typeof q.destination_amount === "number" && Number.isSafeInteger(q.destination_amount) && q.destination_amount > 0
    && typeof q.currency_exponent === "number" && [0, 2, 3].includes(q.currency_exponent)
    && typeof q.expires_at === "string" && Number.isFinite(Date.parse(q.expires_at))
    && typeof q.destination_last4 === "string" && typeof q.eta === "string";
}

export function loadBankConfirmation(accountId: string): BankWithdrawalQuote | null {
  try {
    const saved = localStorage.getItem(recoveryKey(accountId));
    if (!saved) return null;
    const quote: unknown = JSON.parse(saved);
    if (!validQuote(quote)) throw new Error("Invalid saved confirmation");
    return quote;
  } catch {
    throw new Error("We could not read your saved withdrawal. Please retry before starting another withdrawal.");
  }
}

export function saveBankConfirmation(accountId: string, quote: BankWithdrawalQuote): void {
  const previous = loadBankConfirmation(accountId);
  if (previous && previous.id !== quote.id) throw new Error("Check your existing withdrawal before starting another.");
  if (!validQuote(quote)) throw new Error("Reload your withdrawal estimate before confirming.");
  try {
    localStorage.setItem(recoveryKey(accountId), JSON.stringify(quote));
  } catch {
    throw new Error("We could not save your withdrawal confirmation. No new withdrawal was submitted. Please try again.");
  }
}

export function clearBankConfirmation(accountId: string, quoteId: string): void {
  if (loadBankConfirmation(accountId)?.id === quoteId) {
    localStorage.removeItem(recoveryKey(accountId));
  }
}
