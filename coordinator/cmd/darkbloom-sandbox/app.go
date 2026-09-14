package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

type cli struct {
	client             *sandboxClient
	stdout, stderr     io.Writer
	pollInterval       time.Duration
	lastIdempotencyKey string
	transferID         string
}

type commandExit struct{ code int }

func (e commandExit) Error() string { return "sandbox command did not succeed" }

func runCLI(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	config, command, err := parseConfig(args, getenv, stderr)
	if errors.Is(err, flag.ErrHelp) {
		printUsage(stdout)
		return 0
	}
	if err == nil && command[0] == "help" {
		printUsage(stdout)
		return 0
	}
	app := &cli{client: newSandboxClient(config), stdout: stdout, stderr: stderr, pollInterval: time.Second}
	if err == nil {
		err = app.dispatch(ctx, command)
	}
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	var exit commandExit
	if errors.As(err, &exit) {
		return exit.code
	}
	if err != nil {
		if config.json {
			_ = json.NewEncoder(stdout).Encode(struct {
				Error          string `json:"error"`
				IdempotencyKey string `json:"idempotency_key,omitempty"`
				TransferID     string `json:"transfer_id,omitempty"`
			}{err.Error(), app.lastIdempotencyKey, app.transferID})
		} else {
			fmt.Fprintln(stderr, err)
			if app.lastIdempotencyKey != "" {
				fmt.Fprintf(stderr, "Retry the same request with --idempotency-key %s\n", app.lastIdempotencyKey)
			}
			if app.transferID != "" {
				fmt.Fprintf(stderr, "Resume or inspect upload transfer %s\n", app.transferID)
			}
		}
		return 1
	}
	return 0
}

func (a *cli) dispatch(ctx context.Context, args []string) error {
	switch args[0] {
	case "create":
		return a.create(ctx, args[1:])
	case "list":
		return a.list(ctx, args[1:])
	case "inspect":
		return a.inspect(ctx, args[1:])
	case "exec":
		return a.execute(ctx, args[1:])
	case "job":
		return a.job(ctx, args[1:])
	case "start", "stop", "delete", "renew":
		return a.lifecycle(ctx, args[0], args[1:])
	case "mkdir":
		return a.mkdir(ctx, args[1:])
	case "upload":
		return a.upload(ctx, args[1:])
	case "upload-status", "upload-abort":
		return a.transfer(ctx, args[0], args[1:])
	case "download":
		return a.download(ctx, args[1:])
	default:
		return fmt.Errorf("unknown command %q; use help", args[0])
	}
}

func (a *cli) flags(name string) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(a.stderr)
	return flags
}

func (a *cli) mutationKey() string {
	if a.lastIdempotencyKey == "" {
		a.lastIdempotencyKey = a.client.config.idempotencyKey
		if a.lastIdempotencyKey == "" {
			a.lastIdempotencyKey = uuid.NewString()
		}
	}
	return a.lastIdempotencyKey
}

func (a *cli) writeJSON(value any) error { return json.NewEncoder(a.stdout).Encode(value) }

func validID(value string) error {
	if !protocol.ValidSandboxUUID(value) {
		return errors.New("sandbox, command and transfer IDs must be UUIDs")
	}
	return nil
}

func pause(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
