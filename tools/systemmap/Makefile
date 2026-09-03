# systemmap is its own Go module, so that go/packages and go/types never become
# dependencies of the coordinator service. These targets hide the extra `cd`:
#
#   make -C tools/systemmap          generate docs/reference/api-map (git-ignored)
#   make -C tools/systemmap check    fail if source has outgrown the overlay
#   make -C tools/systemmap test     unit tests for the extractor
#   make -C tools/systemmap enrich   write the prose the gate is missing (needs a key)
#
# The generated map is not committed: CI builds it for every pull request and
# publishes it to Pages from master, so it cannot go stale and a coordinator
# change costs no diff. `check` is the gate that still matters — it renders the
# whole map and fails when source contains something the curated overlay does
# not explain.
.PHONY: all check test enrich plan

MANIFEST ?= tmp/systemmap-enrich.json

all:
	go run . $(ARGS)

check:
	go run . -check

test:
	go test ./...

# plan writes the manifest — which prose is missing and which derived facts each
# entry must be written from — without needing a key or a network. It fails on
# drift like `check` does, and writes the manifest anyway, because a pull request
# that added a route is *expected* to fail here.
plan:
	-go run . -check -enrich-manifest $(MANIFEST)

# enrich fills the missing prose and prunes what the map no longer has, then
# re-runs the gate so the target only succeeds if the result is actually complete.
# Needs ANTHROPIC_API_KEY. Prose only: nothing it writes can add a node, an edge,
# a cluster or an auth class, so a new route with no cluster still fails for a
# person to fix.
enrich: plan
	go run ./cmd/enrich -manifest $(MANIFEST) $(ENRICH_ARGS)
	go run . -check
