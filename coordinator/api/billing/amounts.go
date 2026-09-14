package billing

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
)

// microUSDToCents truncates to integer cents (1¢ = 10,000 micro-USD).
func microUSDToCents(microUSD int64) int64 { return microUSD / 10_000 }

func formatUSD(microUSD int64) string {
	return fmt.Sprintf("%.2f", float64(microUSD)/1_000_000)
}

var payoutUSDPattern = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,2})?$`)

func payoutUSDCents(amount string) (int64, error) {
	amount = strings.TrimSpace(amount)
	if !payoutUSDPattern.MatchString(amount) {
		return 0, errors.New("use a USD amount with at most two decimal places")
	}
	parts := strings.SplitN(amount, ".", 2)
	dollars, _ := strconv.ParseInt(parts[0], 10, 64)
	cents := int64(0)
	if len(parts) == 2 {
		cents, _ = strconv.ParseInt((parts[1] + "0")[:2], 10, 64)
	}
	total := dollars*100 + cents
	if total < 100 || total > 100_000_000 {
		return 0, errors.New("withdrawal must be between $1 and $1,000,000")
	}
	return total, nil
}

func payoutCurrencyExponent(currency string) int { return globalpayouts.CurrencyExponent(currency) }
