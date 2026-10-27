"""Closed selection among three separately executed native fixtures."""
from binding_common import require
from window_result import validate_result as validate_window
from session_result import validate_result as validate_session
from transaction_result import validate_result as validate_target

REMOTE = '/Users/developer/DarkbloomDev/gemma-window-state-check-20260916'
BUNDLE = 'ad46a1f87e3448ff42fd40e5ffc36bc40a7e7b8a9a29caa646f380b7dbb3cdde'
SOURCE = 'cbe0586202236cbc225e4de06bbaad28139c20612b49142e6b3310c08f24a3e8'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'
JOBS = {
    'window': dict(product='WindowedRequestStateCheck', runArguments=['run-windowed-state-on-gpu'],
                   processAlarmSeconds=60, sha256='f9e691240f5a0422ceaf0acf5157479d72893fd4d2aa5dba8b9e8ce10b10de83'),
    'session': dict(product='TargetVerificationSessionCheck', runArguments=['run-tiny-session-on-gpu'],
                    processAlarmSeconds=60, sha256='3d2b4b16eb516a3c13bbdad1d5b8cf508f3e098890eecb1e0aa4c481afd72359'),
    'target': dict(product='TargetVerificationCheck', runArguments=['run-native-state-on-gpu'],
                   processAlarmSeconds=30, sha256='6deeb71002a59f912c6350e94510772cd0a40b09306d83022168a6ecaed405a2'),
}


def validate_result(raw, fixture):
    require(fixture in JOBS, 'Unknown native fixture')
    return {'window': validate_window, 'session': validate_session, 'target': validate_target}[fixture](raw)
