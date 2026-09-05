export function formatBankAmount(amount: number, currency: string, exponent: number) {
  return new Intl.NumberFormat(undefined, { style: "currency", currency: currency.toUpperCase() }).format(amount / 10 ** exponent);
}

export function validBankAmount(amount: string): boolean {
  const parts = amount.split(".");
  return parts.length <= 2 && /^\d{1,7}$/.test(parts[0]) && (parts.length === 1 || /^\d{1,2}$/.test(parts[1]));
}

export function bankConfirmationLabel(loading: boolean, pending: boolean, reviewing: boolean, expired: boolean): string {
  if (loading) return "Processing…";
  if (pending) return "Check withdrawal";
  if (reviewing) return "Confirm withdrawal";
  if (expired) return "Refresh estimate";
  return "Review withdrawal";
}
