// devnet-seed fills an empty DevNet coordinator database with synthetic data.
// See internal/command/devnetseed.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/eigeninference/d-inference/coordinator/internal/command/devnetseed"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := devnetseed.Run(ctx, os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "devnet-seed:", err)
		os.Exit(1)
	}
}
