"""Bind the unchanged retry helpers; never prepare or copy a candidate tree."""
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
PACKAGE = Path(__file__).resolve().parent
UPSTREAM = PACKAGE.parent / 'cluster-member-actor-await-retry-20260916'
UPSTREAM_SHA = 'd7ff7fdfd9fc89778d5ea6aaf75a6565f885adf814ca98991a292f736ed44e80'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_manifest(root, expected=None):
    if expected is not None and digest(root / 'manifest.json') != expected:
        raise ValueError('Manifest changed: ' + str(root))
    for row in json.loads((root / 'manifest.json').read_text())['files']:
        path = root / row['path']
        if (not path.is_file() or path.is_symlink() or path.stat().st_size != row['sizeBytes']
                or digest(path) != row['sha256']):
            raise ValueError('Frozen member changed: ' + str(path))


verify_manifest(UPSTREAM, UPSTREAM_SHA)
sys.path.insert(0, str(UPSTREAM))
from inputs import BASE, SOURCE, RETRY, FAILED, OVERLAY_SHA, B_OVERLAY_SHA, NATIVE_PAIR_METHODS, SWIFT_FILTER
from guards import sha, save, verify_overlay, verify_failed_evidence, isolated_environment
import source_inventory as inventory
from check_process import run_owned


def verify_preparation():
    verify_manifest(PACKAGE)
    preparation = json.loads((RETRY / 'preparation.json').read_text())
    workspace = FAILED / 'workspace'
    if (preparation['overlayManifestSHA256'] != OVERLAY_SHA or preparation['nativeBManifestSHA256'] != B_OVERLAY_SHA
            or preparation['wrapperManifestSHA256'] != UPSTREAM_SHA
            or preparation['swiftIntegrationSHA256'] != sha(BASE / 'swift-integration.json')
            or preparation['actorAwaitIntegrationSHA256'] != sha(BASE / 'integration.json')
            or preparation['workspace'] != str(workspace) or preparation['source'] != str(SOURCE)
            or preparation['phase'] != 'swift'):
        raise ValueError('Prepared source identity differs')
    before = json.loads((RETRY / 'source-before.json').read_text())
    candidate = json.loads((RETRY / 'candidate-before.json').read_text())
    integration = verify_overlay()
    verify_failed_evidence()
    expected = dict(before)
    for row in integration['files']:
        expected[row['path']] = {'sha256': row['proposedSHA256']}
    if expected != candidate:
        raise ValueError('Retained candidate map differs from exact member/B/await composition')
    return workspace, before, candidate


def recheck_current_sources():
    workspace, before, candidate = verify_preparation()
    if inventory.inventory(workspace) != candidate or inventory.inventory(SOURCE) != before:
        raise ValueError('MAIN or private Swift source/dependencies changed')
    return workspace
