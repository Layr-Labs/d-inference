// provider-emails previews and synchronizes provider-owner audiences to Resend.
// Production campaigns are sent only from the Resend dashboard after review.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Getenv); err != nil {
		fmt.Fprintln(os.Stderr, "provider-emails:", err)
		os.Exit(1)
	}
}
