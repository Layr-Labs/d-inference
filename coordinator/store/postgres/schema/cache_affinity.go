package schema

const LegacyCacheAffinityGuardFunction = `CREATE OR REPLACE FUNCTION clear_legacy_cache_affinity_key()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
	NEW.cache_affinity_key := '';
	RETURN NEW;
END $$`

const LegacyCacheAffinityGuardTrigger = `DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_legacy_cache_affinity_key'
		  AND NOT tg.tgisinternal
		  AND target.relname = 'inference_routes'
		  AND ns.nspname = current_schema()
	) THEN
		CREATE TRIGGER clear_legacy_cache_affinity_key
		BEFORE INSERT OR UPDATE OF cache_affinity_key ON inference_routes
		FOR EACH ROW EXECUTE FUNCTION clear_legacy_cache_affinity_key();
	END IF;
END $$`

const LegacyCacheAffinityScrubMigration = `DO $$ BEGIN
	IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'scrub_inference_route_cache_affinity_v1') THEN
		IF EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = 'inference_routes'
			  AND column_name = 'cache_affinity_key'
		) THEN
			UPDATE inference_routes SET cache_affinity_key = '' WHERE cache_affinity_key <> '';
		END IF;
		INSERT INTO schema_migrations (id) VALUES ('scrub_inference_route_cache_affinity_v1');
	END IF;
END $$`
