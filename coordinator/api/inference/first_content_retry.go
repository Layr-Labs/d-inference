package inference

import (
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (d *dispatchState) requestForecast() *firstcontent.Forecast {
	if d.forecast == nil {
		d.forecast = firstcontent.NewForecast(contextCalibration, func(id string) {
			if d.excludeProviders == nil {
				d.excludeProviders = make(map[string]struct{})
			}
			d.excludeProviders[id] = struct{}{}
		})
	}
	return d.forecast
}

func (d *dispatchState) notePredictiveRefusal(provider *registry.Provider) {
	decision := d.requestForecast().Refused(provider)
	d.predictiveRefusals, d.freshFeasibleAfter = decision.Count, decision.FreshAfter
}
