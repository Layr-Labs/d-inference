package api

import (
	"github.com/eigeninference/d-inference/coordinator/api/releases"
)

func (s *Server) SetKnownBinaryHashes(hashes []string)           { s.releases.SetKnownBinaryHashes(hashes) }
func (s *Server) AddKnownBinaryHashes(hashes []string)           { s.releases.AddKnownBinaryHashes(hashes) }
func (s *Server) SyncBinaryHashes() error                        { return s.releases.SyncBinaryHashes() }
func (s *Server) SyncRuntimeManifest() error                     { return s.releases.SyncRuntimeManifest() }
func (s *Server) SetRuntimeManifest(m *releases.RuntimeManifest) { s.releases.SetRuntimeManifest(m) }
