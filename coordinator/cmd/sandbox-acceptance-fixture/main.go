// sandbox-acceptance-fixture prepares isolated credentials and launches the
// real coordinator/consumer against an explicitly disposable loopback database.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"syscall"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		// Never include a DSN, credential or arbitrary driver error in output.
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("usage: sandbox-acceptance-fixture seed|run-coordinator|run-client|run-acceptance [options]")
	}
	flags := flag.NewFlagSet(arguments[0], flag.ContinueOnError)
	directory := flags.String("directory", "", "new private fixture directory (seed), or existing fixture (run)")
	databaseFile := flags.String("database-url-file", "", "private file containing the disposable loopback PostgreSQL URL")
	port := flags.Int("port", 18080, "explicit loopback coordinator port")
	baseImage := flags.String("base-image", "", "qualified base image ID provided by the test Mac operator")
	coordinator := flags.String("coordinator", "", "absolute path to the real cmd/coordinator binary on the test Mac")
	client := flags.String("client", "", "absolute path to the standalone consumer CLI on the test Mac")
	confirm := flags.Bool("confirm-disposable", false, "confirm the empty, dedicated acceptance database")
	start := flags.Bool("confirm-start", false, "explicitly launch the selected local component")
	harness := flags.String("harness", "", "absolute path to test-sandbox-live.py (acceptance mode)")
	python := flags.String("python", "/usr/bin/python3", "absolute Python executable (acceptance mode)")
	evidence := flags.String("output", "", "new absolute acceptance evidence directory")
	quota := flags.Bool("workspace-exhaustion", false, "include explicitly selected workspace exhaustion proof")
	if err := flags.Parse(arguments[1:]); err != nil {
		return errors.New("invalid fixture arguments")
	}
	if !filepath.IsAbs(*directory) {
		return errors.New("fixture directory must be absolute")
	}
	switch arguments[0] {
	case "seed":
		if !*confirm || flags.NArg() != 0 {
			return errors.New("seed requires --confirm-disposable and no extra arguments")
		}
		options := seedOptions{Directory: *directory, DatabaseFile: *databaseFile, Port: *port, BaseImage: *baseImage, Coordinator: *coordinator, Client: *client}
		if err := options.validate(); err != nil {
			return err
		}
		if err := os.Mkdir(options.Directory, 0700); err != nil {
			return errors.New("fixture directory must be new and privately writable")
		}
		if err := os.Mkdir(filepath.Join(options.Directory, "home"), 0700); err != nil {
			return errors.New("could not create private fixture home")
		}
		// This helper is a separate process. No inherited cloud/service/PG
		// settings or user .pgpass can affect its selected empty database.
		os.Clearenv()
		for key, value := range baseEnvironment(options.Directory) {
			_ = os.Setenv(key, value)
		}
		slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
		if err := seedPostgres(options); err != nil {
			return err
		}
		fmt.Println("Fixture seeded; private credentials and public acceptance configuration are in", options.Directory)
		return nil
	case "run-coordinator", "run-client", "run-acceptance":
		if !*start {
			return errors.New("launch requires --confirm-start; seeding never starts services")
		}
		plan, err := loadPlan(*directory)
		if err != nil {
			return err
		}
		var program string
		var args, environment []string
		if arguments[0] == "run-acceptance" {
			if flags.NArg() != 0 {
				return errors.New("acceptance launch does not accept extra arguments")
			}
			program, args, environment, err = acceptanceCommand(*directory, plan, *python, *harness, *evidence, *quota)
		} else {
			program, args, environment, err = launchCommand(*directory, plan, arguments[0], flags.Args())
		}
		if err != nil {
			return err
		}
		return syscall.Exec(program, append([]string{program}, args...), environment)
	default:
		return errors.New("unknown fixture mode")
	}
}
