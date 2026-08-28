SELECT *
FROM read_json(
  '__ANALYTICS_ROOT__/events/ready/**/*.jsonl',
  columns = {
    schema_version: 'INTEGER', event_id: 'VARCHAR', event_at: 'TIMESTAMPTZ',
    event_name: 'VARCHAR', process_epoch: 'VARCHAR', job_id: 'VARCHAR',
    trace_id: 'VARCHAR', serving_mode: 'VARCHAR', model: 'VARCHAR', outcome: 'VARCHAR',
    error_class: 'VARCHAR', streaming: 'BOOLEAN', prompt_tokens: 'BIGINT',
    completion_tokens: 'BIGINT', cached_prompt_tokens: 'BIGINT', queue_ms: 'DOUBLE',
    ttft_ms: 'DOUBLE', total_ms: 'DOUBLE', decode_tps: 'DOUBLE',
    earned_micro_usd: 'BIGINT', kv_backend: 'VARCHAR', mtp_active: 'BOOLEAN'
  },
  format = 'newline_delimited'
)
WHERE event_name IN (
  'inference.completed', 'inference.failed', 'inference.cancelled', 'inference.rejected'
)
