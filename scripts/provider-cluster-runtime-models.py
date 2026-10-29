#!/usr/bin/env python3
"""Fetch the metadata of every model a dev release's cluster runtime facts describe.

The input is the build's own model list (`darkbloom cluster runtime-facts
--list-release-models`). For each listed artifact this reads the public model
catalogs of the dev and prod coordinators named in
provider-swift/identity/provider-identity.json. For every catalog entry with that
aggregate it fetches the two encodings of the entry's manifest that the provider
reads (ModelDownloader: `<modelCDNURL>/<r2_prefix>/manifest.json`;
ModelCatalogClient: `<coordinator>/v1/models/catalog/manifest/<model ID>`) and
the entry's config.json from the CDN. A manifest is kept when it names the entry
and the listed aggregate and lists config.json; config.json is kept when its size
and SHA-256 are the manifest's. Each kept manifest is one candidate folder; the
build's own worker chooses among them. Weights are never read. The command fails
when a listed artifact has no candidate.
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
# The environments whose catalogs are read, in this order.
CATALOG_ENVIRONMENTS = ('dev', 'prod')
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


def registries(identity_file=IDENTITY_FILE):
    """(coordinator URL, CDN URL) of each catalog environment, without repeats."""
    environments = json.loads(Path(identity_file).read_text())['environments']
    seen = []
    for name in CATALOG_ENVIRONMENTS:
        pair = (environments[name]['coordinatorHTTPURL'].rstrip('/'), environments[name]['modelCDNURL'].rstrip('/'))
        if pair not in seen:
            seen.append(pair)
    return seen


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


def catalog(coordinator):
    try:
        models = json.loads(get(coordinator + '/v1/models/catalog', MAXIMUM_CATALOG_BYTES))['models']
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
    if len(files) != 1 or not isinstance(files[0].get('size_bytes'), int) \
            or not DIGEST.fullmatch(str(files[0].get('sha256'))):
        raise ValueError('lists no single config.json with its size and SHA-256')
    return files[0]


def candidates(listed, registry_list, fetch=get):
    """[(manifest bytes, config bytes)] per listed artifact, and why each listed artifact has none."""
    entries = []
    for coordinator, cdn in registry_list:
        entries += [(coordinator, cdn, entry) for entry in catalog(coordinator)]
    found, failures = {}, []
    for model in listed:
        artifact, kept, notes = model['artifact_sha256'], [], []
        for coordinator, cdn, entry in entries:
            if entry.get('aggregate_sha256') != artifact or not isinstance(entry.get('id'), str) \
                    or not isinstance(entry.get('r2_prefix'), str):
                continue
            base = cdn + '/' + r2_path(entry['r2_prefix'])
            configuration = None
            for url in (base + '/manifest.json',
                        coordinator + '/v1/models/catalog/manifest/' + model_id_path(entry['id'])):
                try:
                    data = fetch(url, MAXIMUM_MANIFEST_BYTES)
                    item = configuration_entry(data, entry, artifact)
                    if any(data == manifest for manifest, _ in kept):
                        continue
                    if configuration is None:
                        configuration = fetch(base + '/config.json', MAXIMUM_CONFIGURATION_BYTES)
                    if len(configuration) != item['size_bytes'] \
                            or hashlib.sha256(configuration).hexdigest() != item['sha256']:
                        raise ValueError("config.json differs from the manifest's size or SHA-256")
                    kept.append((data, configuration))
                except (FetchError, ValueError) as error:
                    notes.append(f'{url}: {error}')
        found[artifact] = kept
        if not kept:
            failures.append(f"{model['runtime_model_id']} ({artifact}): "
                            + ('; '.join(notes) if notes else 'no catalog entry has this aggregate'))
    return found, failures


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
    parser.add_argument('--models', type=Path, required=True,
                        help='Output of darkbloom cluster runtime-facts --list-release-models')
    parser.add_argument('--output', type=Path, required=True, help='New folder for the candidate folders')
    arguments = parser.parse_args(argv)
    found, failures = candidates(read_list(arguments.models), registries())
    if failures:
        for failure in failures:
            print(f'::error::No registry metadata for a qualified cluster model: {failure}', file=sys.stderr)
        return 1
    write(found, arguments.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
