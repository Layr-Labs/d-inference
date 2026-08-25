package store

const providerLogReportSerialGuardFunction = `CREATE OR REPLACE FUNCTION clear_provider_log_report_serial()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
	NEW.serial_number := '';
	RETURN NEW;
END $$`

const providerLogReportSerialGuardTrigger = `DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_provider_log_report_serial'
		  AND NOT tg.tgisinternal
		  AND target.relname = 'provider_log_reports'
		  AND ns.nspname = current_schema()
	) THEN
		CREATE TRIGGER clear_provider_log_report_serial
		BEFORE INSERT OR UPDATE OF serial_number ON provider_log_reports
		FOR EACH ROW EXECUTE FUNCTION clear_provider_log_report_serial();
	END IF;
END $$`

const providerLogReportSerialScrubMigration = `DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM schema_migrations
		WHERE id = 'scrub_provider_log_report_serials_v1'
	) THEN
		UPDATE provider_log_reports SET serial_number = '' WHERE serial_number <> '';
		INSERT INTO schema_migrations (id)
		VALUES ('scrub_provider_log_report_serials_v1')
		ON CONFLICT (id) DO NOTHING;
	END IF;
END $$`
