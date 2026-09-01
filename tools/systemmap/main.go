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
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/assemble"
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/render"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// Defaults for the coordinator map, shared with the test that checks source has
// not outgrown the overlay.
const (
	defaultModule  = "github.com/eigeninference/d-inference"
	defaultOverlay = "docs/reference/api-map/overlay.json"
	defaultOut     = "docs/reference/api-map"
)

func main() {
	var (
		root     = flag.String("root", "", "repository root (default: the git root of the working directory)")
		module   = flag.String("module", defaultModule, "Go module path of the analyzed repository")
		overlay  = flag.String("overlay", defaultOverlay, "curated overlay, relative to root")
		out      = flag.String("out", defaultOut, "output directory, relative to root")
		revision = flag.String("revision", "", "revision to stamp and link against (default: git HEAD)")
		check    = flag.Bool("check", false, "report drift without writing the map")
		quiet    = flag.Bool("quiet", false, "only print errors")
	)
	flag.Parse()

	if err := run(*root, *module, *overlay, *out, *revision, *check, *quiet); err != nil {
		fmt.Fprintln(os.Stderr, "systemmap:", err)
		os.Exit(1)
	}
}

func run(root, module, overlayPath, outDir, revision string, check, quiet bool) error {
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
	rep := report.New()
	svc, prog, err := extract.Go(root, cfg, rep)
	if err != nil {
		return err
	}
	graph := assemble.Build(svc, prog, cfg, rep, assemble.Options{Revision: revision, OverlayPath: overlayPath})

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
