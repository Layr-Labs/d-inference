package registry

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"
)

func decodeCacheMasterKey(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("key is empty")
	}
	decoders := []func(string) ([]byte, error){
		base64.RawURLEncoding.DecodeString,
		base64.URLEncoding.DecodeString,
		base64.RawStdEncoding.DecodeString,
		base64.StdEncoding.DecodeString,
		hex.DecodeString,
	}
	for _, decode := range decoders {
		if key, err := decode(raw); err == nil && len(key) == 32 {
			return key, nil
		}
	}
	return nil, errors.New("key must encode exactly 32 bytes as base64url, base64, or hex")
}

func deriveCacheKeys(master []byte) cacheRouteKeys {
	return cacheRouteKeys{
		route: hmacBytes(master, []byte("darkbloom/cache-routing/route/v2")),
		scope: hmacBytes(master, []byte("darkbloom/cache-routing/scope/v2")),
	}
}

func hmacBytes(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	var n [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(n[:], uint32(len(part)))
		_, _ = m.Write(n[:])
		_, _ = m.Write(part)
	}
	return m.Sum(nil)
}

func opaqueHMAC(key []byte, parts ...string) string {
	b := make([][]byte, 0, len(parts))
	for _, part := range parts {
		b = append(b, []byte(part))
	}
	return base64.RawURLEncoding.EncodeToString(hmacBytes(key, b...))
}

// DeriveCacheRoute derives coordinator-only route keys from the final body that
// will be sealed to a provider. The optional OpenRouter affinity header is
// intentionally unsupported: no authenticated provenance seam exists today.
func (r *Registry) DeriveCacheRoute(account, model, endpoint string, finalBody []byte, sessionHeader string, hasMedia bool) CacheRoute {
	if r == nil || account == "" || model == "" || len(finalBody) == 0 {
		return CacheRoute{}
	}
	r.mu.RLock()
	mode, keys := r.cacheRoutingMode, r.cacheRouteKeys
	r.mu.RUnlock()
	if mode == CacheRoutingOff || len(keys.route) == 0 {
		return CacheRoute{}
	}
	var body map[string]any
	if json.Unmarshal(finalBody, &body) != nil {
		return CacheRoute{}
	}
	canonical := cloneCacheBody(body)
	canonical["model"] = model
	canonicalBytes, err := json.Marshal(canonical)
	if err != nil {
		return CacheRoute{}
	}
	exactDigest := sha256.Sum256(canonicalBytes)
	explicit, hasExplicit := explicitCacheNamespace(body, sessionHeader)
	// The header is not part of the sealed JSON body, so bind the effective
	// explicit namespace (including its source prefix) into exact identity.
	// Body session_id and prompt_cache_key retain their existing precedence.
	exactNamespace := ""
	if hasExplicit {
		exactNamespace = explicit
	}
	exactKey := opaqueHMAC(keys.route, "exact-v2", account, endpoint, model, string(exactDigest[:]), exactNamespace)
	route := CacheRoute{ExactKey: exactKey, ScopeNamespace: base64.RawURLEncoding.EncodeToString(exactDigest[:])}

	if hasExplicit {
		route.ConversationKey = opaqueHMAC(keys.route, "conversation-explicit-v2", account, endpoint, model, explicit)
		route.ConversationKind = "explicit"
		route.ScopeNamespace = explicit
		return route
	}
	if hasMedia || endpoint == "/v1/completions" {
		return route
	}
	if anchor := derivedConversationAnchor(endpoint, model, body); anchor != "" {
		route.ConversationKey = opaqueHMAC(keys.route, "conversation-derived-v2", account, anchor)
		route.ConversationKind = "derived"
		route.ScopeNamespace = opaqueHMAC(keys.route, "namespace-anchor-v2", account, anchor)
	}
	return route
}

func cloneCacheBody(body map[string]any) map[string]any {
	out := make(map[string]any, len(body))
	for key, value := range body {
		out[key] = value
	}
	for _, key := range []string{
		"provider_serial", "provider_serials",
		"self_route", "prefer_self_route", "routing", "route", "cache_receipt_nonce", "cache_scope",
	} {
		delete(out, key)
	}
	return out
}

func explicitCacheNamespace(body map[string]any, sessionHeader string) (string, bool) {
	if value, ok := body["session_id"].(string); ok {
		value = strings.TrimSpace(value)
		if value != "" && len(value) <= 256 {
			return "session_id:" + value, true
		}
	}
	sessionHeader = strings.TrimSpace(sessionHeader)
	if sessionHeader != "" && len(sessionHeader) <= 256 {
		return "x-session-id:" + sessionHeader, true
	}
	if value, ok := body["prompt_cache_key"].(string); ok {
		value = strings.TrimSpace(value)
		if value != "" && len(value) <= 512 {
			return "prompt_cache_key:" + value, true
		}
	}
	return "", false
}

func derivedConversationAnchor(endpoint, model string, body map[string]any) string {
	messages, ok := body["messages"].([]any)
	if !ok {
		return ""
	}
	var leading, first string
	if endpoint == "/v1/messages" {
		leading = cacheMessageText(body["system"])
	}
	for _, raw := range messages {
		message, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		role, _ := message["role"].(string)
		text := cacheMessageText(message["content"])
		if text == "" {
			continue
		}
		if role == "system" || role == "developer" {
			if first == "" {
				leading += role + "\x00" + text + "\x00"
			}
			continue
		}
		if first == "" {
			first = text
		}
	}
	if leading == "" && first == "" {
		return ""
	}
	leading = firstUTF8Bytes(leading, 1024)
	template := make(map[string]any)
	for _, key := range []string{"tools", "tool_choice", "response_format", "reasoning_effort", "verbosity", "parallel_tool_calls"} {
		if value, ok := body[key]; ok {
			template[key] = value
		}
	}
	templateJSON, _ := json.Marshal(template)
	user, _ := body["user"].(string)
	return endpoint + "\x00" + model + "\x00" + string(templateJSON) + "\x00" + leading + "\x00" + first + "\x00" + user
}

func cacheMessageText(content any) string {
	if text, ok := content.(string); ok {
		return text
	}
	parts, ok := content.([]any)
	if !ok {
		return ""
	}
	var b strings.Builder
	for _, raw := range parts {
		part, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := part["type"].(string)
		if typ != "text" && typ != "input_text" {
			continue
		}
		if text, ok := part["text"].(string); ok {
			b.WriteString(text)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func firstUTF8Bytes(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	for len(s) > 0 && !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

func (r *Registry) ProviderCacheScope(account, model, expectedWeightHash, namespace string) string {
	if r == nil || account == "" || model == "" || expectedWeightHash == "" || namespace == "" {
		return ""
	}
	r.mu.RLock()
	mode, key := r.cacheRoutingMode, append([]byte(nil), r.cacheRouteKeys.scope...)
	r.mu.RUnlock()
	if mode == CacheRoutingOff || len(key) == 0 {
		return ""
	}
	return opaqueHMAC(key, "scope-v2", account, model, strings.ToLower(expectedWeightHash), namespace)
}
