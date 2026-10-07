package config

import "fmt"

// CheckDeploymentEnvironment treats the zero value as production, never development.
func (c AppConfig) CheckDeploymentEnvironment() error {
	switch c.DeploymentEnvironment {
	case "", "production", "development":
		return nil
	default:
		return fmt.Errorf("%s_DEPLOYMENT_ENVIRONMENT must be production or development", EnvPrefix)
	}
}

// RequiresProductionAppAttest excludes only explicit development and the actual
// opt-in memory backend. A database URL wins over AllowMemoryStore at startup.
func (c AppConfig) RequiresProductionAppAttest() bool {
	return c.DeploymentEnvironment != "development" &&
		!(c.StoreConfig.AllowMemoryStore && c.StoreConfig.DatabaseURL == "")
}
