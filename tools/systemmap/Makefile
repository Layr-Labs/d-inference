# systemmap is its own Go module, so that go/packages and go/types never become
# dependencies of the coordinator service. These targets hide the extra `cd`:
#
#   make -C tools/systemmap          generate docs/reference/api-map (git-ignored)
#   make -C tools/systemmap check    fail if source has outgrown the overlay
#   make -C tools/systemmap test     unit tests for the extractor
#
# The generated map is not committed: CI builds it for every pull request and
# publishes it to Pages from master, so it cannot go stale and a coordinator
# change costs no diff. `check` is the gate that still matters — it renders the
# whole map and fails when source contains something the curated overlay does
# not explain.
.PHONY: all check test

all:
	go run . $(ARGS)

check:
	go run . -check

test:
	go test ./...
