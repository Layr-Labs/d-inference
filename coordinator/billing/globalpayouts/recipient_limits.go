package globalpayouts

import (
	"fmt"
	"strings"
)

// Stripe's recipient-side limits in API minor units, checked 2026-09-06:
// https://docs.stripe.com/global-payouts/send-money#recipient-minimums
// Zero means no positive published bound here; Stripe can impose additional bank limits.
type RecipientLimits struct {
	Currency         string `json:"currency"`
	CurrencyExponent int    `json:"currency_exponent"`
	Minimum          int64  `json:"minimum,omitempty"`
	Maximum          int64  `json:"maximum,omitempty"`
}

var countryRecipientLimits = map[string]RecipientLimits{
	"AL": {Minimum: 300000, Maximum: 0},
	"DZ": {Minimum: 100, Maximum: 0},
	"AG": {Minimum: 4, Maximum: 0},
	"AM": {Minimum: 1210000, Maximum: 0},
	"AU": {Minimum: 1, Maximum: 0},
	"AT": {Minimum: 1, Maximum: 0},
	"BS": {Minimum: 2500, Maximum: 0},
	"BH": {Minimum: 5, Maximum: 0},
	"BE": {Minimum: 1, Maximum: 0},
	"BJ": {Minimum: 1, Maximum: 50000000},
	"BT": {Minimum: 250000, Maximum: 0},
	"BA": {Minimum: 5000, Maximum: 0},
	"BW": {Minimum: 100, Maximum: 0},
	"BN": {Minimum: 100, Maximum: 0},
	"BG": {Minimum: 1, Maximum: 0},
	"CA": {Minimum: 1, Maximum: 0},
	"CR": {Minimum: 700, Maximum: 0},
	"HR": {Minimum: 1, Maximum: 0},
	"CY": {Minimum: 1, Maximum: 0},
	"CZ": {Minimum: 1, Maximum: 0},
	"CI": {Minimum: 1, Maximum: 50000000},
	"DK": {Minimum: 1, Maximum: 0},
	"EC": {Minimum: 100, Maximum: 0},
	"SV": {Minimum: 3000, Maximum: 0},
	"EE": {Minimum: 1, Maximum: 0},
	"ET": {Minimum: 100, Maximum: 0},
	"FI": {Minimum: 1, Maximum: 0},
	"FR": {Minimum: 1, Maximum: 0},
	"GM": {Minimum: 190000, Maximum: 0},
	"DE": {Minimum: 1, Maximum: 0},
	"GR": {Minimum: 1, Maximum: 0},
	"GT": {Minimum: 100, Maximum: 0},
	"GY": {Minimum: 630000, Maximum: 0},
	"HK": {Minimum: 2000, Maximum: 0},
	"HU": {Minimum: 1, Maximum: 0},
	"IS": {Minimum: 1, Maximum: 0},
	"IN": {Minimum: 0, Maximum: 1000000000},
	"ID": {Minimum: 1, Maximum: 100000000000},
	"IE": {Minimum: 1, Maximum: 0},
	"IL": {Minimum: 1, Maximum: 100000000},
	"IT": {Minimum: 1, Maximum: 0},
	"JM": {Minimum: 0, Maximum: 0},
	"JO": {Minimum: 10, Maximum: 0},
	"KE": {Minimum: 2000, Maximum: 100000000},
	"KW": {Minimum: 1000, Maximum: 0},
	"LV": {Minimum: 1, Maximum: 0},
	"LI": {Minimum: 1, Maximum: 0},
	"LT": {Minimum: 1, Maximum: 0},
	"LU": {Minimum: 1, Maximum: 0},
	"MG": {Minimum: 13230000, Maximum: 0},
	"MY": {Minimum: 13300, Maximum: 0},
	"MT": {Minimum: 1, Maximum: 0},
	"MU": {Minimum: 1, Maximum: 0},
	"MX": {Minimum: 1, Maximum: 0},
	"MD": {Minimum: 50000, Maximum: 0},
	"MN": {Minimum: 10500000, Maximum: 0},
	"MA": {Minimum: 1, Maximum: 999999999},
	"MZ": {Minimum: 160000, Maximum: 0},
	"NA": {Minimum: 50000, Maximum: 0},
	"NL": {Minimum: 1, Maximum: 0},
	"NZ": {Minimum: 1, Maximum: 0},
	"MK": {Minimum: 150000, Maximum: 0},
	"NO": {Minimum: 1, Maximum: 1000000000},
	"OM": {Minimum: 5, Maximum: 0},
	"PK": {Minimum: 400, Maximum: 0},
	"PA": {Minimum: 5000, Maximum: 0},
	"PE": {Minimum: 5, Maximum: 31000000},
	"PH": {Minimum: 1, Maximum: 0},
	"PL": {Minimum: 1, Maximum: 0},
	"PT": {Minimum: 1, Maximum: 0},
	"QA": {Minimum: 100, Maximum: 0},
	"RO": {Minimum: 1, Maximum: 5000000},
	"RW": {Minimum: 100, Maximum: 0},
	"SN": {Minimum: 1, Maximum: 50000000},
	"RS": {Minimum: 300000, Maximum: 0},
	"SG": {Minimum: 1, Maximum: 0},
	"SK": {Minimum: 1, Maximum: 0},
	"SI": {Minimum: 1, Maximum: 0},
	"ZA": {Minimum: 10000, Maximum: 500000000},
	"ES": {Minimum: 1, Maximum: 0},
	"LK": {Minimum: 100, Maximum: 0},
	"LC": {Minimum: 4, Maximum: 0},
	"SE": {Minimum: 1, Maximum: 1000000000},
	"CH": {Minimum: 1, Maximum: 0},
	"TW": {Minimum: 80000, Maximum: 0},
	"TZ": {Minimum: 3500, Maximum: 0},
	"TH": {Minimum: 60000, Maximum: 0},
	"TT": {Minimum: 10, Maximum: 0},
	"TN": {Minimum: 1, Maximum: 100000000},
	"TR": {Minimum: 500, Maximum: 0},
	"AE": {Minimum: 500, Maximum: 0},
	"GB": {Minimum: 1, Maximum: 0},
	"US": {Minimum: 1, Maximum: 0},
	"UZ": {Minimum: 34300000, Maximum: 0},
	"VN": {Minimum: 81125, Maximum: 0},
}

func (c Country) Limits() RecipientLimits {
	limits := countryRecipientLimits[c.Code]
	limits.Currency = c.Currency
	limits.CurrencyExponent = CurrencyExponent(c.Currency)
	return limits
}

func CurrencyExponent(currency string) int {
	// Global Payouts explicitly publishes 132300.00 MGA as 13230000 API units;
	// keep MGA at exponent 2 for this API.
	switch strings.ToLower(currency) {
	case "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf":
		return 0
	case "bhd", "jod", "kwd", "omr", "tnd":
		return 3
	default:
		return 2
	}
}

func (c Country) LimitError(minimum bool) error {
	limits := c.Limits()
	value, direction, action := limits.Maximum, "maximum", "Reduce"
	if minimum {
		value, direction, action = limits.Minimum, "minimum", "Increase"
	}
	if value == 0 {
		return nil
	}
	exponent := limits.CurrencyExponent
	divisor := int64(1)
	for range exponent {
		divisor *= 10
	}
	amount := fmt.Sprintf("%d", value/divisor)
	if exponent > 0 {
		amount += fmt.Sprintf(".%0*d", exponent, value%divisor)
	}
	return &RecipientLimitError{Message: fmt.Sprintf("Bank transfers to %s have a %s deposit of %s %s. %s your USD withdrawal; Stripe confirms the current exchange rate.", c.Name, direction, amount, strings.ToUpper(c.Currency), action)}
}

type RecipientLimitError struct{ Message string }

func (e *RecipientLimitError) Error() string { return e.Message }

func (c Country) ValidateRecipientAmount(amount Amount) error {
	if amount.Currency != c.Currency {
		return fmt.Errorf("unexpected recipient currency")
	}
	limits := c.Limits()
	if limits.Minimum > 0 && amount.Value < limits.Minimum {
		return c.LimitError(true)
	}
	if limits.Maximum > 0 && amount.Value > limits.Maximum {
		return c.LimitError(false)
	}
	return nil
}
