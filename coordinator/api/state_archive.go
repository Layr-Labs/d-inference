package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/statearchive"
)

func (s *Server) newStateArchiveAPI() *statearchive.Controller {
	return statearchive.New(statearchive.Dependencies{
		AdminKey:    func() string { return s.adminKey },
		Logger:      func() *slog.Logger { return s.logger },
		BearerToken: extractBearerToken,
	})
}
