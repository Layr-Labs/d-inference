package ingress

// infiniteReader yields 'a' forever; with io.LimitReader it streams an
// over-cap body without allocating it, so the cap surfaces as a read error.
type infiniteReader struct{}

func (infiniteReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'a'
	}
	return len(p), nil
}
