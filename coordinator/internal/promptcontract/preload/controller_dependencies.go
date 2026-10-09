package preload

import "time"

func (c PreloadControllerConfig) newActiveSet() *PreloadActiveSet {
	if c.ActiveSets != nil {
		if selection := c.ActiveSets(); selection != nil {
			return selection
		}
	}
	return NewPreloadActiveSet()
}

func (c PreloadControllerConfig) policyClock() func() time.Duration {
	if c.PolicyNow != nil {
		return c.PolicyNow
	}
	origin := time.Now()
	return func() time.Duration { return time.Since(origin) }
}
