package challenge

func VersionMetricTag(version string) string {
	if version == "" {
		return "version:unknown"
	}
	return "version:" + version
}
