package logformat

func Status(sev string) string {
	switch sev {
	case "debug":
		return "debug"
	case "info":
		return "info"
	case "warn":
		return "warning"
	case "error":
		return "error"
	case "fatal":
		return "critical"
	default:
		return "info"
	}
}

func Truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
