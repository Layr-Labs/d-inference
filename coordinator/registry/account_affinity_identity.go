package registry

type accountAffinityIdentityKind uint8

const (
	accountAffinityIdentitySerial accountAffinityIdentityKind = iota + 1
	accountAffinityIdentitySEKey
)

// Keep a reference to the immutable attested value instead of allocating a
// namespaced string for every provider in every request's snapshot. This
// comparable value is request-local; it adds no identity cache or lifecycle.
type accountAffinityIdentity struct {
	value string
	kind  accountAffinityIdentityKind
}

func (id accountAffinityIdentity) valid() bool {
	return id.value != "" && (id.kind == accountAffinityIdentitySerial || id.kind == accountAffinityIdentitySEKey)
}

func (id accountAffinityIdentity) prefix() string {
	switch id.kind {
	case accountAffinityIdentitySerial:
		return "serial:"
	case accountAffinityIdentitySEKey:
		return "sekey:"
	default:
		return ""
	}
}

// Preserve the lexical ordering of the old namespaced string for digest ties.
func (id accountAffinityIdentity) before(other accountAffinityIdentity) bool {
	if id.kind != other.kind {
		return id.prefix() < other.prefix()
	}
	return id.value < other.value
}

// stableAccountAffinityIdentityLocked identifies a verified physical machine,
// not its transient connection or the account owning several machines. The
// caller holds p.mu. Unlike fault tracking, an owner-account fallback would
// collapse a fleet of machines into one affinity destination, so it is absent.
func stableAccountAffinityIdentityLocked(p *Provider) accountAffinityIdentity {
	if p == nil || p.AttestationResult == nil || !p.AttestationResult.Valid {
		return accountAffinityIdentity{}
	}
	if serial := p.AttestationResult.SerialNumber; serial != "" {
		return accountAffinityIdentity{value: serial, kind: accountAffinityIdentitySerial}
	}
	if key := p.AttestationResult.PublicKey; key != "" {
		return accountAffinityIdentity{value: key, kind: accountAffinityIdentitySEKey}
	}
	return accountAffinityIdentity{}
}
