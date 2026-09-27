package registry

// Test-only adapters for the pointer-taking snapshot helpers: tests build
// routingSnapshot / pooledTokenBudget values (often inline, from helper
// calls) and these take their address so the assertions read as before.

func snapPtr(s routingSnapshot) *routingSnapshot { return &s }

func poolPtr(p pooledTokenBudget) *pooledTokenBudget { return &p }
