package protocol

// AppAttestAppleError is client-reported diagnostic data, never authorization
// evidence. Domain buckets are closed and descriptions/userInfo are absent.
type AppAttestAppleError struct {
	Domain           string `json:"domain"`
	Code             int64  `json:"code"`
	UnderlyingDomain string `json:"underlying_domain,omitempty"`
	UnderlyingCode   *int64 `json:"underlying_code,omitempty"`
}

func (e *AppAttestAppleError) Valid() bool {
	if e == nil {
		return true
	}
	validDomain := func(s string) bool {
		switch s {
		case "devicecheck", "osstatus", "url", "cocoa", "other":
			return true
		}
		return false
	}
	validCode := func(n int64) bool { return n >= -2147483648 && n <= 2147483647 }
	if !validDomain(e.Domain) || !validCode(e.Code) {
		return false
	}
	if e.UnderlyingDomain == "" && e.UnderlyingCode == nil {
		return true
	}
	return validDomain(e.UnderlyingDomain) && e.UnderlyingCode != nil && validCode(*e.UnderlyingCode)
}
