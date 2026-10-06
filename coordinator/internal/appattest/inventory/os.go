package inventory

import (
	"strconv"
	"strings"
)

func ReportedOSMajor(version string) int {
	version = strings.TrimPrefix(version, "Version ")
	first := strings.SplitN(version, ".", 2)[0]
	n, err := strconv.Atoi(first)
	if err != nil || n < 10 || n > 99 {
		return 0
	}
	return n
}
