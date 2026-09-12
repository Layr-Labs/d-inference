// Command systemmap generates the Darkbloom system map from source.
//
// Everything structural is derived by type-checking each mapped service: its
// route table, middleware chains, authorization gates, the state each endpoint's
// reachable code touches, and whether that access reads or writes. The curated
// overlay supplies only what source cannot state — node names, the clusters they
// live in, namespaces, auth class names, callers and prose — and the generator
// fails when the two drift apart.
//
// The coordinator is the first extracted service. The IR is service-agnostic, so
// the provider and the consoles arrive as additional extractors and additional
// clusters, not as a schema change.
//
// The artifact is not committed. It is generated — by CI for every pull request
// and for the published page, or locally when someone wants to read it — so the
// map cannot be stale by construction and a source change costs no diff.
//
// systemmap is its own Go module, so it is invoked through its directory:
//
//	make -C tools/systemmap            # generate into docs/reference/api-map (ignored)
//	make -C tools/systemmap check      # fail if source has outgrown the overlay
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/assemble"
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/prose"
	"github.com/eigeninference/d-inference/tools/systemmap/render"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// Defaults for the coordinator map, shared with the test that checks source has
// not outgrown the overlay.
const (
	defaultModule  = "github.com/eigeninference/d-inference"
	defaultOverlay = "docs/reference/api-map/overlay.json"
	defaultProse   = "docs/reference/api-map/prose.json"
	defaultOut     = "docs/reference/api-map"
)

// options are the generator's inputs. They are a struct rather than a parameter
// list because the enrichment paths added two more, and a run() with nine
// positional arguments is a call nobody can read.
type options struct {
	Root     string
	Module   string
	Overlay  string
	Prose    string
	Out      string
	Revision string
	Manifest string
	Check    bool
	Quiet    bool
}

func main() {
	var opt options
	flag.StringVar(&opt.Root, "root", "", "repository root (default: the git root of the working directory)")
	flag.StringVar(&opt.Module, "module", defaultModule, "Go module path of the analyzed repository")
	flag.StringVar(&opt.Overlay, "overlay", defaultOverlay, "curated overlay, relative to root")
	flag.StringVar(&opt.Prose, "prose", defaultProse, "generated prose, relative to root")
	flag.StringVar(&opt.Out, "out", defaultOut, "output directory, relative to root")
	flag.StringVar(&opt.Revision, "revision", "", "revision to stamp and link against (default: git HEAD)")
	flag.StringVar(&opt.Manifest, "enrich-manifest", "", "write the prose CI must generate as JSON to this path, relative to root")
	flag.BoolVar(&opt.Check, "check", false, "report drift without writing the map")
	flag.BoolVar(&opt.Quiet, "quiet", false, "only print errors")
	flag.Parse()

	if err := run(opt); err != nil {
		fmt.Fprintln(os.Stderr, "systemmap:", err)
		os.Exit(1)
	}
}

func run(opt options) error {
	root, module, overlayPath, outDir := opt.Root, opt.Module, opt.Overlay, opt.Out
	revision, check, quiet := opt.Revision, opt.Check, opt.Quiet
	if root == "" {
		found, err := gitRoot()
		if err != nil {
			return err
		}
		root = found
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	if revision == "" {
		revision = gitRevision(root)
	}

	cfg, err := config.Load(filepath.Join(root, overlayPath), module)
	if err != nil {
		return err
	}

	// Generated prose is merged into the overlay's gaps before anything is
	// assembled, so the rest of the pipeline cannot tell the two apart — a
	// sentence is a sentence. What is captured first is who wrote what, because
	// that is exactly what the merge destroys and what enrichment must respect.
	generated, err := prose.Load(filepath.Join(root, opt.Prose))
	if err != nil {
		return err
	}
	human := cfg.HumanProse()
	cfg.MergeProse(generated)

	rep := report.New()
	svc, prog, err := extract.Go(root, cfg, rep)
	if err != nil {
		return err
	}
	graph := assemble.Build(svc, prog, cfg, rep, assemble.Options{Revision: revision, OverlayPath: overlayPath})

	// The plan is worked out from the assembled graph, so it sees the same facts
	// the page shows. Prose whose facts have moved is drift: unlike a missing
	// sentence, nothing else in the report would mention it, and a description of
	// a route that has since changed auth class is worse than no description.
	plan := prose.Build(graph, human, cfg.SymbolsByNode(), generated)
	for _, req := range plan.Requests {
		if req.Prior == nil {
			continue // missing prose; the sections above already report it
		}
		rep.AddOutdatedProse(fmt.Sprintf("`%s` — generated prose describes facts that have changed (hash %s); run `make -C tools/systemmap enrich`",
			req.Key, req.Hash))
	}
	graph.Generator.OverlayComplete = rep.Clean()
	if opt.Manifest != "" {
		if err := writeManifest(filepath.Join(root, opt.Manifest), revision, plan); err != nil {
			return err
		}
		if !quiet {
			fmt.Printf("systemmap: %d prose entries to write, %d current, %d to prune → %s\n",
				len(plan.Requests), plan.Fresh, len(plan.Prune), opt.Manifest)
		}
	}

	inventory, err := graph.Marshal()
	if err != nil {
		return err
	}
	page, err := render.HTML(graph, inventory)
	if err != nil {
		return err
	}
	drift := []byte(rep.Markdown())

	// -check still renders everything: the page and the inventory are where a
	// marshalling or template failure surfaces, and a gate that only ran the
	// extractor would pass on a map that cannot be published.
	files := map[string][]byte{
		"inventory.json":  inventory,
		"system-map.html": page,
		"report.md":       drift,
	}

	if !check {
		for name, content := range files {
			path := filepath.Join(root, outDir, name)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(path, content, 0o644); err != nil {
				return err
			}
		}
	}
	if !quiet {
		fmt.Printf("systemmap: %d routes, %d nodes, %d associations at %s\n",
			len(graph.Routes), len(graph.Nodes), len(graph.StateAccess), shortRev(revision))
		if !check {
			fmt.Printf("systemmap: wrote %s\n", outDir)
		}
		if rep.Clean() {
			fmt.Println("systemmap: overlay complete, no drift")
		} else if check {
			fmt.Printf("systemmap: DRIFT — %s\n\n%s", rep.Counts(), drift)
		} else {
			fmt.Printf("systemmap: DRIFT — %s (see %s/report.md)\n", rep.Counts(), outDir)
		}
	}
	if !rep.Clean() {
		return fmt.Errorf("drift detected: %s", rep.Counts())
	}
	return nil
}

// writeManifest records what enrichment has to do. It is written even when the
// run fails on drift, because drift is the normal state of a pull request that
// added a route: the gate says "this needs prose", the manifest says which prose
// and from which facts, and the enrichment job turns the second into the first
// being satisfied.
func writeManifest(path, revision string, plan prose.Plan) error {
	payload := struct {
		Revision string          `json:"revision"`
		Requests []prose.Request `json:"requests"`
		Prune    []string        `json:"prune"`
		Fresh    int             `json:"fresh"`
		// The map's vocabulary of state, so the enricher's validator knows what a node
		// id looks like here without having to guess it from a token's shape.
		Categories []string `json:"categories"`
		Tables     []string `json:"tables"`
	}{revision, plan.Requests, plan.Prune, plan.Fresh, plan.Categories, plan.Tables}
	if payload.Requests == nil {
		payload.Requests = []prose.Request{}
	}
	if payload.Prune == nil {
		payload.Prune = []string{}
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, append(raw, '\n'), 0o644)
}

func gitRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("not in a git repository; pass -root")
	}
	return strings.TrimSpace(string(out)), nil
}

func gitRevision(root string) string {
	cmd := exec.Command("git", "rev-parse", "HEAD")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return "main"
	}
	return strings.TrimSpace(string(out))
}

func shortRev(rev string) string {
	if len(rev) > 12 {
		return rev[:12]
	}
	return rev
}
