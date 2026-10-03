package amount

import "regexp"

// USDPattern is the shared lexical bound for Checkout and payout USD amounts.
var USDPattern = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,2})?$`)
