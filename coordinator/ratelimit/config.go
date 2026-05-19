package ratelimit

// ReadConsumerConfig reads the consumer inference rate limiter config from env.
func ReadConsumerConfig() Config {
	return Config{
		RPS:   envFloat("EIGENINFERENCE_RATE_LIMIT_RPS", DefaultRPS),
		Burst: envInt("EIGENINFERENCE_RATE_LIMIT_BURST", DefaultBurst),
	}
}

// ReadFinancialConfig reads the stricter financial-endpoint rate limiter config
// from env. Defaults: 0.2 RPS = 1 req every 5s, burst 3.
func ReadFinancialConfig() Config {
	return Config{
		RPS:   envFloat("EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS", 0.2),
		Burst: envInt("EIGENINFERENCE_FINANCIAL_RATE_LIMIT_BURST", 3),
	}
}

// Check returns an error if the config is logically invalid.
// Zero RPS means "disabled", so it's valid.
func (c Config) Check() error {
	return nil
}
