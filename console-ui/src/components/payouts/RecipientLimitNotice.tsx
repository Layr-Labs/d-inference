import type { RecipientAmountLimits } from "@/lib/api/types";
import { formatBankAmount } from "./bank-withdrawal-format";

export function RecipientLimitNotice({ limits }: { limits?: RecipientAmountLimits }) {
  if (!limits || (!limits.minimum && !limits.maximum)) return null;
  const format = (amount: number) => formatBankAmount(amount, limits.currency, limits.currency_exponent);
  return <p className="text-xs text-text-secondary mb-4">
    Bank deposit limits ({limits.currency.toUpperCase()}):
    {limits.minimum ? ` minimum ${format(limits.minimum)}.` : ""}
    {limits.maximum ? ` maximum ${format(limits.maximum)}.` : ""}
    {limits.currency !== "usd" && " Stripe confirms the conversion from USD when you review."}
  </p>;
}
