"""Read a pinned native catalog and associate a freshly replayed packet."""

from runtime.stage_checks.common import digest, parse
from ..candidates import associate
from ..costs import require, sha
from .inputs import read_regular
from .packet import extract


def associate_packet(packet_path, catalog_path, expected_sha256):
    sha(expected_sha256, 'raw native catalog')
    raw, identity = read_regular(catalog_path, 32 * 1024**2)
    require(digest(raw) == expected_sha256, 'Pinned native catalog bytes differ')
    catalog = parse(raw)
    services = extract(packet_path)
    result = associate(catalog, services)
    require(read_regular(catalog_path, 32 * 1024**2) == (raw, identity),
            'Native catalog changed during extraction')
    return dict(result, catalog_raw_sha256=expected_sha256, packet_sha256=services['packet_sha256'])
