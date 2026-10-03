package inference

import (
	"strings"
	"time"
)

func waitForCond(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

func containsTag(line, tag string) bool {
	i := strings.Index(line, "|#")
	if i < 0 {
		return false
	}
	for _, value := range strings.Split(line[i+2:], ",") {
		if value == tag {
			return true
		}
	}
	return false
}
