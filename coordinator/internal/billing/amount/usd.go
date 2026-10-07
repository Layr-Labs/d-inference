package amount

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
)

// USDPattern is the shared lexical bound for Checkout and payout USD amounts.
var USDPattern = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,2})?$`)

// PayoutUSDCents validates and converts a withdrawal amount without float rounding.
func PayoutUSDCents(amount string) (int64, error) {
	amount = strings.TrimSpace(amount)
	if !USDPattern.MatchString(amount) {
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
