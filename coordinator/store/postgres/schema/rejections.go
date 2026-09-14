package schema

func rejections() []string {
	return []string{

		// Rejected inbound inference requests (4xx/5xx) at any pipeline stage,
		// with the request shape and a counterfactual servability snapshot
		// ("could the fleet have served it?"). Contains no prompt or response
		// content.
		`CREATE TABLE IF NOT EXISTS request_rejections (
			id BIGSERIAL PRIMARY KEY,
			request_id TEXT,
			endpoint TEXT,
			stage TEXT,
			reason_code TEXT,
			http_status INT,
			consumer_key_hash TEXT,
			key_id TEXT,
			client_class TEXT,
			requested_model TEXT,
			resolved_model TEXT,
			stream BOOL,
			n INT,
			estimated_prompt_tokens INT,
			requested_max_tokens INT,
			requires_vision BOOL,
			has_image BOOL,
			has_audio BOOL,
			has_tools BOOL,
			tool_count INT,
			response_format TEXT,
			self_route_only BOOL,
			prefer_owner BOOL,
			params JSONB,
			request_body_bytes INT,
			retry_after_ms INT,
			could_have_served BOOL,
			candidate_count INT,
			capacity_rejections INT,
			model_too_large_rejections INT,
			vision_rejections INT,
			warm_provider_existed BOOL,
			best_ttft_ms DOUBLE PRECISION,
			shortfall_micro_usd BIGINT,
			limit_kind TEXT,
			over_by BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_request_rejections_created ON request_rejections(created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_request_rejections_reason ON request_rejections(reason_code, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_request_rejections_model ON request_rejections(resolved_model, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_request_rejections_status ON request_rejections(http_status, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_request_rejections_servable ON request_rejections(could_have_served, created_at DESC) WHERE could_have_served = true`,
	}
}
