SELECT hourly_covered_through::TIMESTAMPTZ AS hourly_covered_through
FROM read_json_auto('__ANALYTICS_ROOT__/state/processor-state.json')
