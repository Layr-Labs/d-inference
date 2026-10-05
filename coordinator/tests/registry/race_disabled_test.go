//go:build !race

package registry_test

// raceDetectorEnabled is false when the test binary was built without -race.
const raceDetectorEnabled = false
