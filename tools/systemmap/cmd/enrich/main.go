// Command enrich writes the generated half of the system map's overlay: the
// prose that explains a route or a piece of state.
//
// It is the second half of a loop whose first half is `systemmap -check`. That
// gate reports every route with no description and every dependency node with no
// name or no documentation, and — with `-enrich-manifest` — writes exactly which
// entries are missing and which derived facts each must be written from. This
// program reads that manifest, asks a model for each entry, validates the answer
// against the facts, and writes `docs/reference/api-map/prose.json`. Running the
// gate again then passes.
//
// Why generate it at all: the curated overlay has two halves with very different
// risk. Clusters, namespaces, auth classes and declared tables decide what the map
// *draws*, and a wrong value there publishes a wrong architecture — those stay
// hand-written and hand-reviewed. Prose decides what the page *says* about
// something source already found, and its gate can only ever check that a sentence
// exists, never that it is still true. That is the half that rots. Generating it
// against a hash of the derived facts turns "somebody should reread these 101
// descriptions" into a check that fails on the one that changed.
//
// The output is a commit on the pull request's branch, so every generated sentence
// is read by the same human who reviews the code that caused it. Nothing here can
// add a node, an edge, a cluster or an auth class: a route with no cluster or no
// auth class still fails the gate and still waits for a person.
//
//	go run ./cmd/enrich -manifest tmp/plan.json          # write missing prose
//	go run ./cmd/enrich -manifest tmp/plan.json -dry-run # say what it would write
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/tools/systemmap/prose"
)

type manifest struct {
	Revision string          `json:"revision"`
	Requests []prose.Request `json:"requests"`
	Prune    []string        `json:"prune"`
	Fresh    int             `json:"fresh"`
}

type settings struct {
	root      string
	manifest  string
	prosePath string
	overlay   string
	model     string
	endpoint  string
	keyEnv    string
	maxTokens int
	workers   int
	limit     int
	attempts  int
	timeout   time.Duration
	dryRun    bool
	quiet     bool
}

func main() {
	var s settings
	flag.StringVar(&s.root, "root", "", "repository root (default: the git root of the working directory)")
	flag.StringVar(&s.manifest, "manifest", "tmp/systemmap-enrich.json", "manifest written by `systemmap -enrich-manifest`, relative to root")
	flag.StringVar(&s.prosePath, "prose", "docs/reference/api-map/prose.json", "generated prose file to write, relative to root")
	flag.StringVar(&s.overlay, "overlay", "docs/reference/api-map/overlay.json", "curated overlay, read for hand-written examples, relative to root")
	flag.StringVar(&s.model, "model", "claude-sonnet-5", "model to write with")
	flag.StringVar(&s.endpoint, "endpoint", "https://api.anthropic.com", "Messages API base URL")
	flag.StringVar(&s.keyEnv, "key-env", "ANTHROPIC_API_KEY", "environment variable holding the API key")
	flag.IntVar(&s.maxTokens, "max-tokens", 2048, "completion budget per entry")
	flag.IntVar(&s.workers, "workers", 4, "entries to write concurrently")
	flag.IntVar(&s.limit, "limit", 0, "stop after this many entries (0: no limit)")
	flag.IntVar(&s.attempts, "attempts", 3, "attempts per entry, including retries after a rejected answer")
	flag.DurationVar(&s.timeout, "timeout", 10*time.Minute, "budget for the whole run")
	flag.BoolVar(&s.dryRun, "dry-run", false, "report what would be written without calling the model")
	flag.BoolVar(&s.quiet, "quiet", false, "only print errors and the summary")
	flag.Parse()

	if err := run(s); err != nil {
		fmt.Fprintln(os.Stderr, "enrich:", err)
		os.Exit(1)
	}
}

func run(s settings) error {
	if s.root == "" {
		found, err := gitRoot()
		if err != nil {
			return err
		}
		s.root = found
	}
	root, err := filepath.Abs(s.root)
	if err != nil {
		return err
	}
	s.root = root

	plan, err := loadManifest(filepath.Join(root, s.manifest))
	if err != nil {
		return err
	}
	file, err := prose.Load(filepath.Join(root, s.prosePath))
	if err != nil {
		return err
	}

	// Pruning needs no model, so it happens whatever else does: an entry for a
	// route that no longer exists is removed even on a run that writes nothing.
	pruned := 0
	for _, key := range plan.Prune {
		if _, ok := file.Entries[key]; ok {
			delete(file.Entries, key)
			pruned++
		}
	}

	requests := plan.Requests
	if s.limit > 0 && len(requests) > s.limit {
		requests = requests[:s.limit]
	}
	if s.dryRun {
		for _, req := range requests {
			fmt.Printf("would write %s:%s (hash %s)\n", req.Kind, req.Key, req.Hash)
		}
		fmt.Printf("enrich: %d to write, %d to prune, %d current\n", len(requests), pruned, plan.Fresh)
		return nil
	}
	if len(requests) == 0 {
		if pruned > 0 {
			if err := file.Save(filepath.Join(root, s.prosePath)); err != nil {
				return err
			}
		}
		if !s.quiet {
			fmt.Printf("enrich: nothing to write, %d pruned, %d current\n", pruned, plan.Fresh)
		}
		return nil
	}

	key := os.Getenv(s.keyEnv)
	if key == "" {
		return fmt.Errorf("%s is not set, and %d entries need writing; on a pull request from a fork "+
			"the secret is unavailable by design — publish the manifest as an artifact and let a "+
			"maintainer run `make -C tools/systemmap enrich`", s.keyEnv, len(requests))
	}

	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	pctx, err := loadContext(root, s.overlay)
	if err != nil {
		return err
	}
	cl := &client{
		http:     &http.Client{Timeout: 3 * time.Minute},
		endpoint: s.endpoint,
		key:      key,
		model:    s.model,
		maxTok:   s.maxTokens,
	}
	written, failures := writeAll(ctx, cl, s, requests, pctx)

	for key, entry := range written {
		file.Entries[key] = entry
	}
	if err := file.Save(filepath.Join(root, s.prosePath)); err != nil {
		return err
	}
	if !s.quiet {
		fmt.Printf("enrich: wrote %d, pruned %d, %d already current → %s\n", len(written), pruned, plan.Fresh, s.prosePath)
	}
	if len(failures) > 0 {
		// Partial output is kept: the entries that succeeded are correct and cost
		// money, and the gate will simply ask again for the rest.
		sort.Strings(failures)
		return fmt.Errorf("%d of %d entries could not be written:\n  %s", len(failures), len(requests), strings.Join(failures, "\n  "))
	}
	return nil
}

// writeAll fills every request, concurrently but with a deterministic result: the
// entries are keyed, not ordered, and the file is saved with sorted keys, so two
// runs over the same manifest produce the same diff shape.
func writeAll(ctx context.Context, cl *client, s settings, requests []prose.Request, pctx contextSource) (map[string]prose.Entry, []string) {
	var (
		guard    idGuard
		mu       sync.Mutex
		written  = map[string]prose.Entry{}
		failures []string
		wg       sync.WaitGroup
	)
	work := make(chan prose.Request)
	workers := s.workers
	if workers < 1 {
		workers = 1
	}
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for req := range work {
				entry, err := writeOne(ctx, cl, s, req, pctx, guard)
				mu.Lock()
				if err != nil {
					failures = append(failures, fmt.Sprintf("%s:%s — %v", req.Kind, req.Key, err))
				} else {
					written[req.Kind+":"+req.Key] = entry
					if !s.quiet {
						fmt.Printf("enrich: %s:%s\n", req.Kind, req.Key)
					}
				}
				mu.Unlock()
			}
		}()
	}
	for _, req := range requests {
		select {
		case work <- req:
		case <-ctx.Done():
		}
	}
	close(work)
	wg.Wait()
	return written, failures
}

// writeOne asks for one entry and holds the answer to the rules. A rejected
// answer is returned to the model as another turn naming the rule it broke, which
// is what makes the validator productive rather than merely fatal: the common
// failures (a fenced reply, a missing doc field, a table nobody reads) are all
// things a model fixes when told.
func writeOne(ctx context.Context, cl *client, s settings, req prose.Request, pctx contextSource, guard idGuard) (prose.Entry, error) {
	turns := buildTurns(req, pctx)
	attempts := s.attempts
	if attempts < 1 {
		attempts = 1
	}
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if err := ctx.Err(); err != nil {
			if lastErr != nil {
				return prose.Entry{}, fmt.Errorf("%v (last error: %v)", err, lastErr)
			}
			return prose.Entry{}, err
		}
		text, err := cl.complete(ctx, systemPrompt, turns)
		if err != nil {
			lastErr = err
			if !retryable(err) {
				return prose.Entry{}, err
			}
			sleep(ctx, backoff(attempt))
			continue
		}
		fields, err := parseCompletion(text)
		if err == nil {
			var entry prose.Entry
			entry, err = validate(req, fields, guard, s.model)
			if err == nil {
				return entry, nil
			}
		}
		lastErr = err
		turns = append(turns,
			message{Role: "assistant", Content: text},
			message{Role: "user", Content: fmt.Sprintf(
				"That answer was rejected: %v\n\nWrite the JSON object again, corrected. Reply with the object and nothing else.", err)})
	}
	return prose.Entry{}, fmt.Errorf("%d attempts: %v", attempts, lastErr)
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

func loadManifest(path string) (manifest, error) {
	var m manifest
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return m, fmt.Errorf("no manifest at %s; run `systemmap -enrich-manifest` first", path)
		}
		return m, err
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, fmt.Errorf("manifest %s: %w", path, err)
	}
	return m, nil
}

func gitRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not in a git repository; pass -root")
	}
	return strings.TrimSpace(string(out)), nil
}
