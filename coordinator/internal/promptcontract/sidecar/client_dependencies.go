package sidecar

import "net/http"

// Pool names one of the client's independent HTTP connection pools.
type Pool string

const (
	PoolPlan    Pool = "plan"
	PoolHealth  Pool = "health"
	PoolControl Pool = "control"
)

func (c ClientConfig) newPlanAdmission(workers int) *PlanAdmission {
	if c.PlanAdmissions != nil {
		if admission := c.PlanAdmissions(workers); admission != nil {
			return admission
		}
	}
	return NewPlanAdmission(workers)
}

func (c ClientConfig) newPool(pool Pool, transport *http.Transport) *http.Client {
	if c.Transports != nil {
		if roundTripper := c.Transports(pool, transport); roundTripper != nil {
			return &http.Client{Transport: roundTripper}
		}
	}
	return &http.Client{Transport: transport}
}
