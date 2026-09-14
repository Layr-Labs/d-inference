// darkbloom-sandbox is the standalone consumer client. It does not load the
// inference provider or any MLX dependencies.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	os.Exit(runCLI(ctx, os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}
