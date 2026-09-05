//go:build race

package registry

// raceDetectorEnabled is true when the test binary was built with -race. The
// detector serializes goroutines heavily enough that throughput assertions
// (parallel speed-up guards) are meaningless under it.
const raceDetectorEnabled = true
