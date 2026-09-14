package dispatchplan

// applyQuoteDelivery turns a settled probe into its plan mutation + outcome:
// affirmative quote → confirm, everything else → demote. Kept pure of channel
// plumbing so tests pin the mapping directly.
func applyQuoteDelivery[C comparable](plan *Plan[C], d quoteDelivery) QuoteOutcome {
	if d.quote == nil {
		plan.DemoteEntry(d.providerID)
		return QuoteOutcome{ProviderID: d.providerID, SendFailed: true}
	}
	if d.quote.AdmissibleNow {
		plan.ConfirmEntry(d.providerID, d.quote)
	} else {
		plan.DemoteEntry(d.providerID)
	}
	return QuoteOutcome{ProviderID: d.providerID, Quote: d.quote}
}
