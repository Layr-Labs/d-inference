"""Accept only the existing, explicitly unavailable PostgreSQL maintenance test."""
from go_coverage import completed

SKIP = 'TestMaintenanceProcessDoesNotServeOrSeedAdmin'
REASON = '    maintenance_test.go:30: DATABASE_URL not set\n'


def validate_command(events, expected):
    result = completed(events, expected)
    package = 'github.com/eigeninference/d-inference/coordinator/cmd/coordinator'
    if set(expected) != {package} or SKIP not in expected[package]:
        raise ValueError('Closed coordinator command selection required')
    wanted = {name: ('skip' if name == SKIP else 'pass') for name in expected[package]}
    if result != {package: wanted}:
        raise ValueError('Command results differ from all passes plus the one explicit DB skip')
    reasons = [event.get('Output') for event in events
               if event.get('Package') == package and event.get('Test') == SKIP
               and event.get('Action') == 'output' and event.get('Output') == REASON]
    if reasons != [REASON]:
        raise ValueError('Exact source-bound DATABASE_URL skip reason required once')
    return result
