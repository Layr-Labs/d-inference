package dispatch

// ExclusionSet is a request-local retry constraint. Selection consumes a detached
// list; failed preparation adds only the selected provider, never the whole fleet.
type ExclusionSet struct{ ids map[string]struct{} }

func NewExclusions(ids ...string) *ExclusionSet {
	s := &ExclusionSet{ids: make(map[string]struct{}, len(ids))}
	for _, id := range ids {
		s.Exclude(id)
	}
	return s
}

func (s *ExclusionSet) Exclude(id string) { s.ids[id] = struct{}{} }
func (s *ExclusionSet) IDs() []string {
	ids := make([]string, 0, len(s.ids))
	for id := range s.ids {
		ids = append(ids, id)
	}
	return ids
}
