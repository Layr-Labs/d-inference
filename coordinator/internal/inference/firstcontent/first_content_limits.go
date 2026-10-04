package firstcontent

import "time"

// preambleContentTimeout is the relative cap from the first boilerplate chunk
// to first content. The request-absolute clock always bounds this fallback.
const PreambleContentTimeout = 90 * time.Second

// maxHeldBoilerplate bounds buffered preamble per attempt. Excess boilerplate
// is dropped, never promoted to content or used to commit a provider.
const maxHeldBoilerplate = 8
