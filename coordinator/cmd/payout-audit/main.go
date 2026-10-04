// payout-audit reads bounded withdrawal history by default. Applying a historical
// refund requires an exact row, expected amount, and an operator-verified Stripe
// request ID. It never sends a payout, creates a recipient, or runs migrations.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	payoutaudit "github.com/eigeninference/d-inference/coordinator/internal/command/payoutaudit"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if err := payoutaudit.Run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
