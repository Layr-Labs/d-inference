package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"strings"

	"github.com/google/uuid"
)

type clientConfig struct {
	baseURL        string
	apiKey         string
	json           bool
	idempotencyKey string
}

func parseConfig(args []string, getenv func(string) string, output io.Writer) (clientConfig, []string, error) {
	config := clientConfig{baseURL: getenv("DARKBLOOM_API_URL"), apiKey: getenv("DARKBLOOM_API_KEY")}
	if config.baseURL == "" {
		config.baseURL = "https://api.darkbloom.dev"
	}
	flags := flag.NewFlagSet("darkbloom-sandbox", flag.ContinueOnError)
	flags.SetOutput(output)
	flags.StringVar(&config.baseURL, "api-url", config.baseURL, "coordinator URL (or DARKBLOOM_API_URL)")
	// Help must not print an unvalidated environment URL containing userinfo.
	flags.Lookup("api-url").DefValue = "https://api.darkbloom.dev"
	flags.BoolVar(&config.json, "json", false, "write one JSON result to stdout")
	flags.StringVar(&config.idempotencyKey, "idempotency-key", "", "UUID to reuse an earlier lifecycle or exec request")
	allowLocal := flags.Bool("allow-insecure-localhost", false, "allow HTTP only for a local test coordinator")
	if err := flags.Parse(args); err != nil {
		return config, nil, err
	}
	remaining := flags.Args()
	if len(remaining) == 0 || remaining[0] == "help" {
		return config, []string{"help"}, nil
	}
	for _, argument := range remaining[1:] {
		if argument == "--" {
			break
		}
		if argument == "--help" || argument == "-h" {
			return config, []string{"help"}, nil
		}
	}
	base, err := url.Parse(config.baseURL)
	if err != nil || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" || (base.Path != "" && base.Path != "/") {
		return config, nil, errors.New("API URL must be an HTTPS coordinator origin without credentials, path, query or fragment")
	}
	if base.Scheme != "https" {
		ip := net.ParseIP(base.Hostname())
		local := strings.EqualFold(base.Hostname(), "localhost") || ip != nil && ip.IsLoopback()
		if base.Scheme != "http" || !*allowLocal || !local {
			return config, nil, errors.New("HTTPS is required; local test HTTP requires --allow-insecure-localhost")
		}
	}
	if config.apiKey == "" || strings.ContainsAny(config.apiKey, " \t\r\n") {
		return config, nil, errors.New("set DARKBLOOM_API_KEY to an account API key")
	}
	if config.idempotencyKey != "" {
		if len(config.idempotencyKey) != 36 {
			return config, nil, errors.New("idempotency key must be a UUID")
		}
		if _, err := uuid.Parse(config.idempotencyKey); err != nil {
			return config, nil, errors.New("idempotency key must be a UUID")
		}
	}
	config.baseURL = strings.TrimSuffix(config.baseURL, "/")
	return config, remaining, nil
}

func printUsage(out io.Writer) {
	fmt.Fprintln(out, `Usage: darkbloom-sandbox [global flags] <command> [command flags] [arguments]

Global flags: --api-url URL --json --idempotency-key UUID --allow-insecure-localhost
Credentials: DARKBLOOM_API_KEY; optional DARKBLOOM_API_URL

  create --image IMAGE [--cpu 4 --memory-gib 8 --workspace-gib 25 --wait=true]
  list [--limit 100]
  inspect SANDBOX_ID
  exec [--cwd /workspace --timeout 900 --env NAME=VALUE --wait=true] SANDBOX_ID -- /absolute/executable [args]
  job status|logs|cancel SANDBOX_ID COMMAND_ID
  job list SANDBOX_ID
  mkdir SANDBOX_ID RELATIVE_DIRECTORY
  upload [--transfer-id UUID] SANDBOX_ID LOCAL_FILE RELATIVE_FILE
  upload-status|upload-abort SANDBOX_ID TRANSFER_ID
  download SANDBOX_ID RELATIVE_FILE LOCAL_FILE
  start|stop|delete|renew [--wait=true] SANDBOX_ID

Use the same idempotency key after a lifecycle or exec transport failure.
Resume uploads using the printed transfer ID. Downloads never overwrite a local file.`)
}
