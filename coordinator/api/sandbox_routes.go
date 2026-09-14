package api

func (s *Server) registerSandboxRoutes() {
	// Sandbox hosts use their own credentials and protocol. Keep this connection
	// alive while admission drains so durable cancellation and deletion finish.
	s.mux.HandleFunc("GET /ws/sandbox-host", s.handleSandboxHostWS)

	s.mux.HandleFunc("POST /v1/sandboxes",
		s.drainGate(s.requireSandboxAdmission(s.rateLimitFinancial(s.handleCreateSandbox))))
	s.mux.HandleFunc("GET /v1/sandboxes", s.requireSandboxAuth(s.handleListSandboxes))
	s.mux.HandleFunc("GET /v1/sandboxes/{sandboxID}", s.requireSandboxAuth(s.handleGetSandbox))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/commands",
		s.drainGate(s.requireSandboxAdmission(s.rateLimitConsumer(s.handleSandboxCommand))))
	s.mux.HandleFunc("GET /v1/sandboxes/{sandboxID}/commands", s.requireSandboxAuth(s.handleListSandboxCommands))
	s.mux.HandleFunc("GET /v1/sandboxes/{sandboxID}/commands/{commandID}", s.requireSandboxAuth(s.handleGetSandboxCommand))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/commands/{commandID}/cancel",
		s.requireSandboxAuth(s.rateLimitConsumer(s.handleCancelSandboxCommand)))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/renew",
		s.drainGate(s.requireSandboxAdmission(s.handleRenewSandbox)))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/start",
		s.drainGate(s.requireSandboxAdmission(s.rateLimitFinancial(s.handleStartSandbox))))

	// Cleanup stays available during admission and coordinator drains. These
	// handlers record durable intent before dispatch, and HTTP shutdown waits
	// for their handlers independently of the inference inflight counter.
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/stop", s.requireSandboxAuth(s.handleStopSandbox))
	s.mux.HandleFunc("DELETE /v1/sandboxes/{sandboxID}", s.requireSandboxAuth(s.handleDeleteSandbox))
	s.mux.HandleFunc("GET /v1/sandbox-operations/{operationID}", s.requireSandboxAuth(s.handleGetSandboxOperation))
	s.registerSandboxFileRoutes()
}

func (s *Server) registerSandboxFileRoutes() {
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/files/uploads", s.drainGate(s.requireSandboxAdmission(s.rateLimitConsumer(s.handleSandboxUploadBegin))))
	s.mux.HandleFunc("PUT /v1/sandboxes/{sandboxID}/files/uploads/{transferID}/chunks", s.drainGate(s.requireSandboxAdmission(s.rateLimitConsumer(s.handleSandboxUploadChunk))))
	s.mux.HandleFunc("GET /v1/sandboxes/{sandboxID}/files/uploads/{transferID}", s.requireSandboxAuth(s.handleSandboxUploadStatus))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/files/uploads/{transferID}/commit", s.drainGate(s.requireSandboxAdmission(s.rateLimitConsumer(s.handleSandboxUploadCommit))))
	s.mux.HandleFunc("DELETE /v1/sandboxes/{sandboxID}/files/uploads/{transferID}", s.requireSandboxAuth(s.handleSandboxUploadAbort))
	s.mux.HandleFunc("POST /v1/sandboxes/{sandboxID}/files/directories", s.drainGate(s.requireSandboxAdmission(s.rateLimitConsumer(s.handleSandboxFileMkdir))))
	s.mux.HandleFunc("GET /v1/sandboxes/{sandboxID}/files", s.requireSandboxAuth(s.handleSandboxFileDownload))
}
