# systemmap is its own Go module, so that go/packages and go/types never become
# dependencies of the coordinator service. These targets hide the extra `cd`:
#
#   make -C tools/systemmap          generate docs/reference/api-map (git-ignored)
#   make -C tools/systemmap check    fail if source has outgrown the overlay
#   make -C tools/systemmap test     unit tests for the extractor, plus the DOM suite
#   make -C tools/systemmap webtest  drive the generated page in a DOM (needs node)
#   make -C tools/systemmap history  the same map with its history slider (minutes)
#   make -C tools/systemmap timeline just the timeline, without re-rendering the map
#   make -C tools/systemmap enrich   write the prose the gate is missing (needs a key)
#
# The default target and `history` produce two different artifacts, and which one you
# get is decided by the command rather than by what is lying around in the output
# directory. The default is the map of this commit: seconds, and what `check` and CI
# publish. `history` is the same map with a slider over the coordinator's whole
# history, which costs one full type-check per commit — minutes — so nobody pays for
# it who did not ask.
#
# The generated map is not committed: CI builds it for every pull request and
# publishes it to Pages from master, so it cannot go stale and a coordinator
# change costs no diff. `check` is the gate that still matters — it renders the
# whole map and fails when source contains something the curated overlay does
# not explain.
.PHONY: all check test enrich plan webdeps webtest history timeline

MANIFEST ?= tmp/systemmap-enrich.json
# Where `webtest` builds the map it drives. Git-ignored, like the map itself: this
# is a throwaway copy that exists for the length of one test run.
WEBTEST_OUT ?= tmp/systemmap-webtest

# Paths the generator is given — the manifest, the overlay, the output — are
# resolved against the repository root and not the working directory, so a rule
# that wants to look at one has to say where it landed.
ROOT := $(shell git rev-parse --show-toplevel)
MANIFEST_PATH := $(ROOT)/$(MANIFEST)

all:
	go run . $(ARGS)

check:
	go run . -check

test:
	go test ./...

# The explorer is the deliverable a reader actually uses, so it is executed rather
# than pattern-matched: render/webtest loads a generated page into a DOM, drives its
# controls, and checks the geometry the layout computes. `webdeps` installs jsdom;
# `go test` picks the suite up on its own once it is there (TestPageExecutes), so
# `make test` covers the page too and `make webtest` is the way to run it alone —
# over the real coordinator map, whose 108 routes, 20 groups and 990 wires
# crowd the label pass on their own, rather than over the five-route fixture, which
# only reaches that claim through a deliberately small viewport.
webdeps: render/webtest/node_modules/jsdom

# The install is the target, so a second `make webtest` does not re-run npm. Deleting
# node_modules, or a change to the lockfile, brings it back.
render/webtest/node_modules/jsdom: render/webtest/package-lock.json
	cd render/webtest && npm ci
	touch $@

# No -history here, and that is the point of the flag: the baseline page is the same
# page on every machine, rather than one that grew a slider because whoever ran the
# suite happened to have built a timeline last week. The timeline's own tests build
# their fixture in the DOM.
webtest: webdeps
	go run . -out $(WEBTEST_OUT)
	cd render/webtest && SYSTEMMAP_PAGE=$(ROOT)/$(WEBTEST_OUT)/system-map.html npm test

# history is the walkable map: the timeline, then the map that embeds it. Both halves,
# because "I asked for history and got a map without a slider" is the failure this
# target exists to make impossible — and the render is seconds on top of a walk that
# costs one full type-check per commit.
#
# HISTORY_ARGS is where sampling goes. `-every 25` is the quick look; a walk worth
# reading keeps every commit, because watching the shape move is the point. Nothing
# publishes it yet — the Pages job builds the plain map, since the walk costs minutes —
# so today this target is a human asking for the slider on their own machine.
history: timeline
	go run . -history $(ARGS)

# timeline writes the artifact and stops, for re-rendering later (`make ARGS=-history`)
# or for a walk whose sampling you want to check before spending a render on it.
timeline:
	go run ./cmd/history $(HISTORY_ARGS)

# plan writes the manifest — which prose is missing and which derived facts each
# entry must be written from — without needing a key or a network. It fails on
# drift like `check` does, and writes the manifest anyway, because a pull request
# that added a route is *expected* to fail here.
#
# So a non-zero exit is tolerated, but not on its own: the manifest is written
# before the gate's verdict and after everything that can fail, so its presence is
# what separates "drift, as expected" from a crash. Ignoring the status alone let a
# generator that never ran hand `enrich` a manifest from some earlier commit — which
# is why the stale one is deleted first.
plan:
	@rm -f $(MANIFEST_PATH)
	@go run . -check -enrich-manifest $(MANIFEST) || true
	@test -f $(MANIFEST_PATH) || { \
		echo "systemmap: no manifest written — the generator failed before it could plan; run 'make -C tools/systemmap check' to see why" >&2; \
		exit 1; \
	}

# enrich fills the missing prose and prunes what the map no longer has, then
# re-runs the gate so the target only succeeds if the result is actually complete.
# Needs ANTHROPIC_API_KEY. Prose only: nothing it writes can add a node, an edge,
# a cluster or an auth class, so a new route with no cluster still fails for a
# person to fix.
enrich: plan
	go run ./cmd/enrich -manifest $(MANIFEST) $(ENRICH_ARGS)
	go run . -check
