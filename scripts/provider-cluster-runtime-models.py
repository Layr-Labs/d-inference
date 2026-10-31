#!/usr/bin/env python3
"""Fetch the metadata of every model a release's cluster runtime facts describe.

The input is the build's own model list (`darkbloom cluster runtime-facts
--list-release-models`) and the release's environment. The catalog and model
CDN read are the environment's own, the ones its app reads
(provider-swift/identity/provider-identity.json: `coordinatorHTTPURL`,
`modelCDNURL`). For each listed artifact, every entry of the public catalog
(`GET /v1/models/catalog`) with that aggregate gives candidates: the two
encodings of the entry's manifest the provider reads, in the order it asks for
them (ClusterModelProvisioningStore.catalogAnswer:
`<modelCDNURL>/<r2_prefix>/manifest.json`, then
`<coordinator>/v1/models/catalog/manifest/<model ID>`), each with the entry's
config.json from the CDN. A manifest is kept when it names the entry and the
listed aggregate and lists config.json; config.json is kept when its size and
SHA-256 are the manifest's. Each kept manifest is one candidate folder; the
build's own worker chooses among them. Weights are never read.

A listed artifact the catalog does not have is left out and named (standard
output and `--skipped`). Every other failure (an unreadable catalog, an entry
with no usable manifest) fails the command, which then writes nothing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
IDENTITY_FILE = ROOT / 'provider-swift/identity/provider-identity.json'
ENVIRONMENTS = ('dev', 'staging', 'prod')
# ClusterCatalogArtifact.maximumManifestBytes; ClusterConfigurationFiles.maximumModelConfigurationBytes.
MAXIMUM_MANIFEST_BYTES = 1 << 20
MAXIMUM_CONFIGURATION_BYTES = 32 << 20
MAXIMUM_CATALOG_BYTES = 8 << 20
ATTEMPTS = 3
# The CDN refuses Python's default agent.
USER_AGENT = 'darkbloom-release-cluster-runtime/1'
DIGEST = re.compile(r'[0-9a-f]{64}')


class FetchError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise FetchError(f'refusing a redirect from {req.full_url}')


def registry(environment, identity_file=IDENTITY_FILE):
    """(coordinator URL, CDN URL) the app of `environment` reads."""
    if environment not in ENVIRONMENTS:
        raise ValueError(f'Unknown environment: {environment}')
    entry = json.loads(Path(identity_file).read_text())['environments'][environment]
    return entry['coordinatorHTTPURL'].rstrip('/'), entry['modelCDNURL'].rstrip('/')


def get(url, maximum):
    """The body of a 200 response of at most `maximum` bytes; transient failures are retried."""
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    for attempt in range(1, ATTEMPTS + 1):
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
                data = response.read(maximum + 1)
            if len(data) > maximum:
                raise FetchError(f'{url}: more than {maximum} bytes')
            return data
        except urllib.error.HTTPError as error:
            error.close()
            if error.code < 500 or attempt == ATTEMPTS:
                raise FetchError(f'{url}: HTTP {error.code}') from error
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            if attempt == ATTEMPTS:
                raise FetchError(f'{url}: {error}') from error
        time.sleep(2 * attempt)
    raise AssertionError('unreachable')


def r2_path(path):
    # ModelDownloader.escapeR2Path: each segment percent-encoded as a URL path.
    return '/'.join(urllib.parse.quote(segment, safe="!$&'()*+,;=:@") for segment in path.split('/'))


def model_id_path(model_id):
    # ModelCatalogClient.escapeModelIDForPath: one segment, so "/" is encoded.
    return urllib.parse.quote(model_id, safe="!$&'()*+,;=:@")


def catalog(coordinator, fetch=get):
    try:
        models = json.loads(fetch(coordinator + '/v1/models/catalog', MAXIMUM_CATALOG_BYTES))['models']
    except (ValueError, KeyError, TypeError) as error:
        raise FetchError(f'{coordinator}: unreadable model catalog') from error
    if not isinstance(models, list):
        raise FetchError(f'{coordinator}: unreadable model catalog')
    return [entry for entry in models if isinstance(entry, dict)]


def configuration_entry(data, entry, artifact):
    """The manifest's config.json entry, when the manifest names this catalog entry and artifact."""
    try:
        manifest = json.loads(data)
    except ValueError as error:
        raise ValueError('not JSON') from error
    if not isinstance(manifest, dict) or manifest.get('model_id') != entry['id'] \
            or manifest.get('aggregate_sha256') != artifact:
        raise ValueError('names another model or aggregate')
    files = [item for item in manifest.get('files') or [] if isinstance(item, dict) and item.get('path') == 'config.json']
    if len(files) != 1 or type(files[0].get('size_bytes')) is not int \
            or not DIGEST.fullmatch(str(files[0].get('sha256'))):
        raise ValueError('lists no single config.json with its size and SHA-256')
    return files[0]


def candidates(listed, coordinator, cdn, fetch=get):
    """({artifact: [(manifest bytes, config bytes)]}, listed models the catalog lacks, failures)."""
    entries = catalog(coordinator, fetch)
    found, skipped, failures = {}, [], []
    for model in listed:
        artifact, kept, notes = model['artifact_sha256'], [], []
        matching = [entry for entry in entries if entry.get('aggregate_sha256') == artifact
                    and isinstance(entry.get('id'), str) and isinstance(entry.get('r2_prefix'), str)]
        if not matching:
            skipped.append(model)
            continue
        for entry in matching:
            base = cdn + '/' + r2_path(entry['r2_prefix'])
            configuration, entry_kept = None, 0
            for url in (base + '/manifest.json',
                        coordinator + '/v1/models/catalog/manifest/' + model_id_path(entry['id'])):
                try:
                    data = fetch(url, MAXIMUM_MANIFEST_BYTES)
                    item = configuration_entry(data, entry, artifact)
                    if any(data == manifest for manifest, _ in kept):
                        entry_kept += 1
                        continue
                    if configuration is None:
                        configuration = fetch(base + '/config.json', MAXIMUM_CONFIGURATION_BYTES)
                    if len(configuration) != item['size_bytes'] \
                            or hashlib.sha256(configuration).hexdigest() != item['sha256']:
                        raise ValueError("config.json differs from the manifest's size or SHA-256")
                    kept.append((data, configuration))
                    entry_kept += 1
                except (FetchError, ValueError) as error:
                    notes.append(f'{url}: {error}')
            if not entry_kept:
                failures.append(f"{entry['id']} ({model['runtime_model_id']}, {artifact}): " + '; '.join(notes))
        found[artifact] = kept
    return found, skipped, failures


def write(found, output):
    output.mkdir(parents=True, exist_ok=False)
    index = 0
    for artifact in sorted(found):
        for manifest, configuration in found[artifact]:
            folder = output / f'{index:03d}'
            folder.mkdir()
            (folder / 'manifest.json').write_bytes(manifest)
            (folder / 'config.json').write_bytes(configuration)
            index += 1


def read_list(path):
    listed = json.loads(Path(path).read_text())
    if not isinstance(listed, list) or not listed or not all(
            isinstance(item, dict) and set(item) == {'runtime_model_id', 'artifact_sha256'}
            and isinstance(item['runtime_model_id'], str) and DIGEST.fullmatch(str(item['artifact_sha256']))
            for item in listed):
        raise ValueError('The release model list must be a non-empty list of runtime_model_id and artifact_sha256')
    return listed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    parser.add_argument('--environment', choices=ENVIRONMENTS, required=True,
                        help="The release's environment: its catalog and model CDN are read")
    parser.add_argument('--models', type=Path, required=True,
                        help='Output of darkbloom cluster runtime-facts --list-release-models')
    parser.add_argument('--output', type=Path, required=True, help='New folder for the candidate folders')
    parser.add_argument('--skipped', type=Path, required=True,
                        help='New file: one Markdown line per listed model the catalog does not have')
    arguments = parser.parse_args(argv)
    coordinator, cdn = registry(arguments.environment)
    found, skipped, failures = candidates(read_list(arguments.models), coordinator, cdn)
    if failures:
        for failure in failures:
            print(f'::error::No usable catalog metadata for a qualified cluster model: {failure}', file=sys.stderr)
        return 1
    lines = [f"- Not in the {arguments.environment} catalog, left out: {model['runtime_model_id']} "
             f"(artifact {model['artifact_sha256']})" for model in skipped]
    for line in lines:
        print(line)
    write(found, arguments.output)
    with open(arguments.skipped, 'x', encoding='utf-8') as file:
        file.write(''.join(line + '\n' for line in lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())
