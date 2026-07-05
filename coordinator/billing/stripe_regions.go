package billing

import "strings"

// Stripe Connect region policy.
//
// Stripe only supports transfers on the payments balance between the United
// States, Canada, the United Kingdom, the EEA, and Switzerland
// (https://docs.stripe.com/connect/account-capabilities). Connected accounts
// in those regions can live under the default `full` service agreement and
// still receive platform transfers.
//
// Accounts in any other country (AU, NZ, JP, …) can NOT receive transfers
// under the `full` agreement — Stripe rejects them with:
//
//	"Funds can't be sent to accounts located in XX when the account is
//	 under the `full` service agreement."
//
// Those accounts must be created under the `recipient` service agreement
// (tos_acceptance[service_agreement]=recipient) with ONLY the `transfers`
// capability — `card_payments` is incompatible with the recipient agreement
// (https://docs.stripe.com/connect/service-agreement-types).
//
// The service agreement is immutable once accepted: fixing an account created
// under the wrong agreement requires creating a NEW account.

// Service agreement values as they appear in the Stripe API.
const (
	ServiceAgreementFull      = "full"
	ServiceAgreementRecipient = "recipient"
)

// fullTransferRegion is the set of countries between which Stripe supports
// platform → connected-account transfers under the `full` service agreement:
// US, CA, UK, CH, and the EEA (EU-27 + IS, LI, NO).
var fullTransferRegion = map[string]bool{
	"US": true, "CA": true, "GB": true, "CH": true,
	// EU-27
	"AT": true, "BE": true, "BG": true, "HR": true, "CY": true, "CZ": true,
	"DK": true, "EE": true, "FI": true, "FR": true, "DE": true, "GR": true,
	"HU": true, "IE": true, "IT": true, "LV": true, "LT": true, "LU": true,
	"MT": true, "NL": true, "PL": true, "PT": true, "RO": true, "SK": true,
	"SI": true, "ES": true, "SE": true,
	// EEA non-EU
	"IS": true, "LI": true, "NO": true,
}

// RequiredServiceAgreement returns the Stripe service agreement a connected
// account in accountCountry must be under so that a platform in
// platformCountry can send it transfers.
//
// Same-country accounts and accounts within the US/CA/UK/EEA/CH transfer
// region use `full`; everything else needs `recipient`.
//
// Both inputs are case-normalized: Stripe returns uppercase ISO codes, but
// the platform country arrives from configuration
// (EIGENINFERENCE_STRIPE_CONNECT_COUNTRY) and could be set lowercase — a
// missed comparison here would silently create normal US/EEA accounts as
// `recipient`, changing their capabilities.
func RequiredServiceAgreement(platformCountry, accountCountry string) string {
	platformCountry = strings.ToUpper(strings.TrimSpace(platformCountry))
	accountCountry = strings.ToUpper(strings.TrimSpace(accountCountry))
	if accountCountry == "" || accountCountry == platformCountry {
		return ServiceAgreementFull
	}
	if fullTransferRegion[platformCountry] && fullTransferRegion[accountCountry] {
		return ServiceAgreementFull
	}
	return ServiceAgreementRecipient
}

// NormalizeServiceAgreement maps the tos_acceptance.service_agreement value
// from a Stripe account API response onto ServiceAgreementFull/Recipient.
//
// Verified against the live API: accounts under the full agreement OMIT the
// field entirely (tos_acceptance only carries date/ip), so an empty value
// means `full` — NOT "unknown". Treating it as unknown would silently skip
// agreement-mismatch detection for exactly the accounts that need it.
func NormalizeServiceAgreement(s string) string {
	if s == "" {
		return ServiceAgreementFull
	}
	return s
}
