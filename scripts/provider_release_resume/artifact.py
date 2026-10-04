"""Download exact retained transport bytes before the existing bundle verifier."""
import hashlib
import json
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path

from .identity import MAX_ARCHIVE_BYTES


def extract_transport(archive, digest, output):
    with archive.open("rb") as stream:
        actual = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != digest:
        raise ValueError("Retained artifact transport checksum differs")
    with zipfile.ZipFile(archive) as zipped:
        files = zipped.infolist()
        if (len(files) != 1 or files[0].filename != "unsigned-provider.tar.gz"
                or files[0].is_dir() or stat.S_ISLNK(files[0].external_attr >> 16)
                or not 0 < files[0].file_size <= MAX_ARCHIVE_BYTES):
            raise ValueError("Unexpected unsigned artifact transport layout")
        output.mkdir(parents=True, exist_ok=False)
        with zipped.open(files[0]) as source, (output / files[0].filename).open("xb") as target:
            shutil.copyfileobj(source, target, 1 << 20)


def download(api, selection, output):
    with tempfile.TemporaryDirectory(prefix="retained-provider-") as temporary:
        archive = Path(temporary) / "artifact.zip"
        api.save("actions/artifacts/" + selection["unsigned_artifact_id"] + "/zip", archive)
        if archive.stat().st_size > MAX_ARCHIVE_BYTES:
            raise ValueError("Retained artifact transport exceeds size limit")
        extract_transport(archive, selection["unsigned_artifact_digest"], output)
    (output / "retained-build-provenance.json").write_text(json.dumps(selection, indent=2) + "\n")
