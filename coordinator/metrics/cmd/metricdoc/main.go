// Command metricdoc prints the declared metric catalog as a markdown table.
//
// It exists so the metric table in docs/reference/telemetry-inventory.md is
// generated from the declarations rather than maintained beside them: a metric
// whose tags change in code and not in the docs is how the inventory drifted
// from the coordinator in the first place.
//
//	cd coordinator && go run ./metrics/cmd/metricdoc
package main

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/metrics"
)

func main() {
	fmt.Print(metrics.Noop().DocumentTable())
}
