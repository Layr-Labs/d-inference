"""Read SELECT evidence through the verified local Cloud SQL read-replica proxy."""
import os
import pathlib
import subprocess
import sys

password = subprocess.check_output([
    'gcloud', 'secrets', 'versions', 'access', 'latest',
    '--secret=darkbloom-inference-prod-coordinator-db-password',
    '--project=darkbloom-mainnet'], text=True).strip()
env = os.environ.copy()
env.update(PGHOST='127.0.0.1', PGPORT='15439', PGUSER='coordinator',
           PGDATABASE='eigeninference', PGPASSWORD=password, PGSSLMODE='disable',
           PGCONNECT_TIMEOUT='8', PGAPPNAME='codex-provider-quality-readonly',
           PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000 -c lock_timeout=1000')
cmd = ['psql', '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1']
guard = subprocess.check_output(cmd + ['-c', "SELECT pg_is_in_recovery() AND current_setting('transaction_read_only')::boolean"], env=env, text=True).strip()
if guard != 't':
    raise SystemExit('Refusing to query: connection is not a read-only physical replica')
sql = pathlib.Path(sys.argv[1]).read_text()
r = subprocess.run(cmd, input='BEGIN READ ONLY;\n' + sql + '\nROLLBACK;\n', env=env, text=True)
sys.exit(r.returncode)
