//go:build !race

package registry

// raceDetectorEnabled is false when the test binary was built without -race.
const raceDetectorEnabled = false
