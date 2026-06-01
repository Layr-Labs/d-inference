package payments

import (
	"fmt"
	"math"
)

// microUSDScale is the number of micro-USD per USD. All balances and prices in
// the system are stored as integer micro-USD; these helpers are the single
// canonical place to convert to/from USD floats.
const microUSDScale = 1_000_000

// USDToMicro converts a USD dollar amount to micro-USD, rounded to the nearest
// micro-USD. Rounding (not truncation) is the canonical behavior so the same
// dollar input always maps to the same integer regardless of call site.
func USDToMicro(usd float64) int64 { return int64(math.Round(usd * microUSDScale)) }

// MicroToUSD converts micro-USD to a USD float.
func MicroToUSD(micro int64) float64 { return float64(micro) / microUSDScale }

// FormatUSD formats a micro-USD amount as a fixed-decimal USD string with no
// currency symbol, e.g. FormatUSD(1_500_000, 2) == "1.50". It reproduces the
// fmt.Sprintf("%.<decimals>f", micro/1e6) pattern used across the handlers.
func FormatUSD(micro int64, decimals int) string {
	return fmt.Sprintf("%.*f", decimals, MicroToUSD(micro))
}
