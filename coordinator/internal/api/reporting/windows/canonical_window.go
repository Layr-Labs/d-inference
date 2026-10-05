package windows

func NetworkTotalsWindow(param string) string {
	switch param {
	case "1d":
		return "24h"
	case "", "lifetime":
		return "all"
	}
	return param
}
