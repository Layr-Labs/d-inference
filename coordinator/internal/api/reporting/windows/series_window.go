package windows

import (
	"time"
)

type networkSeriesWindow struct {
	Label      string
	Duration   time.Duration
	BucketSize time.Duration
}

const MaxNetworkSeriesLookback = 30 * 24 * time.Hour

func ParseNetworkSeriesWindow(value string) (networkSeriesWindow, bool) {
	switch value {
	case "", "30m":
		return networkSeriesWindow{Label: "30m", Duration: 30 * time.Minute, BucketSize: time.Minute}, true
	case "24h", "1d":
		return networkSeriesWindow{Label: "24h", Duration: 24 * time.Hour, BucketSize: 30 * time.Minute}, true
	case "7d":
		return networkSeriesWindow{Label: "7d", Duration: 7 * 24 * time.Hour, BucketSize: 4 * time.Hour}, true
	case "30d":
		return networkSeriesWindow{Label: "30d", Duration: 30 * 24 * time.Hour, BucketSize: 12 * time.Hour}, true
	default:
		return networkSeriesWindow{}, false
	}
}
