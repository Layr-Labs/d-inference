// Command promptsidecarloadproof verifies the release prompt sidecar against
// immutable production prompt artifacts without contacting or mutating a live
// coordinator. Its stdout is a single machine-readable proof summary.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type arguments struct {
	BinaryPath      string
	ArtifactRoot    string
	VectorsPath     string
	Duration        time.Duration
	QPS             int
	MaxRSSMiB       int
	MaxRSSGrowthMiB int
}

func main() {
	os.Exit(execute())
}

func execute() int {
	args := parseArguments()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	summary, err := runProof(ctx, args)
	if err != nil {
		summary.Passed = false
		summary.Error = err.Error()
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if encodeErr := encoder.Encode(summary); encodeErr != nil {
		_, _ = fmt.Fprintf(os.Stderr, "encode load-proof summary: %v\n", encodeErr)
		return 1
	}
	if err != nil {
		return 1
	}
	return 0
}

func parseArguments() arguments {
	var args arguments
	flag.StringVar(&args.BinaryPath, "binary", "", "absolute release promptsidecar binary path")
	flag.StringVar(&args.ArtifactRoot, "artifact-root", "", "absolute provisioned prompt-artifact root")
	flag.StringVar(&args.VectorsPath, "vectors", "", "production_vectors.json path")
	flag.DurationVar(&args.Duration, "duration", 15*time.Second, "sustained load duration")
	flag.IntVar(&args.QPS, "qps", 25, "plan requests per second")
	flag.IntVar(&args.MaxRSSMiB, "max-rss-mib", 1024, "hard observed RSS ceiling")
	flag.IntVar(&args.MaxRSSGrowthMiB, "max-rss-growth-mib", 128, "allowed RSS growth after preload")
	flag.Parse()
	return args
}
