package store

// PricingStore covers custom per-model price overrides (per account, and the
// "platform" account for global admin pricing). Prices are micro-USD per 1M
// tokens.
type PricingStore interface {
	// SetModelPrice sets a custom price override for a model on an account.
	// Input and output prices are in micro-USD per 1M tokens.
	SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error

	// GetModelPrice returns the custom price for a model on an account.
	// Returns (0, 0, false) if no custom price is set.
	GetModelPrice(accountID, model string) (inputPrice, outputPrice int64, ok bool)

	// ListModelPrices returns all custom price overrides for an account.
	ListModelPrices(accountID string) []ModelPrice

	// DeleteModelPrice removes a custom price override.
	DeleteModelPrice(accountID, model string) error
}

// ModelPrice represents a custom per-model price override for an account.
type ModelPrice struct {
	AccountID   string `json:"account_id"`
	Model       string `json:"model"`
	InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
	OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
}
