// systemmap is a repo-level documentation tool, deliberately kept in its own
// module so its analysis dependencies never reach the coordinator service.
module github.com/eigeninference/d-inference/tools/systemmap

go 1.25.0

require golang.org/x/tools v0.44.0

require (
	golang.org/x/mod v0.35.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
)
