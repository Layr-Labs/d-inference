package store

// One counter row per UTC hour, model and consumer keeps reads compact and
// applies old/new outcome deltas under a single row lock. Projection writers
// order batches by this key to avoid cross-model lock inversions.
const modelDemandHourlyDDL = `CREATE TABLE IF NOT EXISTS model_demand_hourly (
 hour TIMESTAMPTZ NOT NULL,
 model TEXT NOT NULL,
 consumer_hash TEXT NOT NULL,
 requests BIGINT NOT NULL,
 completed BIGINT NOT NULL,
 capacity_rejected BIGINT NOT NULL,
 latency_rejected BIGINT NOT NULL,
 timed_out BIGINT NOT NULL,
 failed BIGINT NOT NULL,
 cancelled BIGINT NOT NULL,
 unknown BIGINT NOT NULL,
 excluded BIGINT NOT NULL,
 http_429 BIGINT NOT NULL,
 PRIMARY KEY(hour,model,consumer_hash)
)`

const modelDemandRollupFunctionDDL = `CREATE OR REPLACE FUNCTION update_model_demand_hourly() RETURNS trigger AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.outcome=NEW.outcome AND (OLD.http_status=429)=(NEW.http_status=429) THEN RETURN NEW; END IF;
 INSERT INTO model_demand_hourly (hour,model,consumer_hash,requests,completed,capacity_rejected,latency_rejected,timed_out,failed,cancelled,unknown,excluded,http_429)
 VALUES (date_trunc('hour',NEW.received_at,'UTC'),NEW.model,NEW.consumer_hash,
 1-CASE WHEN TG_OP='UPDATE' THEN 1 ELSE 0 END,
 (NEW.outcome='completed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='completed')::integer ELSE 0 END,
 (NEW.outcome='capacity_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='capacity_rejected')::integer ELSE 0 END,
 (NEW.outcome='latency_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='latency_rejected')::integer ELSE 0 END,
 (NEW.outcome='timed_out')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='timed_out')::integer ELSE 0 END,
 (NEW.outcome='failed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='failed')::integer ELSE 0 END,
 (NEW.outcome='cancelled')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='cancelled')::integer ELSE 0 END,
 (NEW.outcome='unknown')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='unknown')::integer ELSE 0 END,
 (NEW.outcome='excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='excluded')::integer ELSE 0 END,
 (NEW.http_status=429 AND NEW.outcome<>'excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.http_status=429 AND OLD.outcome<>'excluded')::integer ELSE 0 END)
 ON CONFLICT (hour,model,consumer_hash) DO UPDATE SET
 requests=model_demand_hourly.requests+EXCLUDED.requests,
 completed=model_demand_hourly.completed+EXCLUDED.completed,
 capacity_rejected=model_demand_hourly.capacity_rejected+EXCLUDED.capacity_rejected,
 latency_rejected=model_demand_hourly.latency_rejected+EXCLUDED.latency_rejected,
 timed_out=model_demand_hourly.timed_out+EXCLUDED.timed_out,
 failed=model_demand_hourly.failed+EXCLUDED.failed,
 cancelled=model_demand_hourly.cancelled+EXCLUDED.cancelled,
 unknown=model_demand_hourly.unknown+EXCLUDED.unknown,
 excluded=model_demand_hourly.excluded+EXCLUDED.excluded,
 http_429=model_demand_hourly.http_429+EXCLUDED.http_429;
 RETURN NEW;
END;
$$ LANGUAGE plpgsql`

const modelDemandRollupTriggerDDL = `CREATE OR REPLACE TRIGGER model_demand_rollup
 AFTER INSERT OR UPDATE ON model_demand_requests FOR EACH ROW EXECUTE FUNCTION update_model_demand_hourly()`
