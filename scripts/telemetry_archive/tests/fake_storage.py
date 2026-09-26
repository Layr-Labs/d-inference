"""A strict create-only object store; deliberately has no delete/overwrite API."""

from types import SimpleNamespace

from google.api_core.exceptions import PreconditionFailed


class Blob:
    def __init__(self, bucket, name):
        self.bucket = bucket
        self.name = name
        self.metadata = None

    def upload_from_filename(self, filename, **kwargs):
        assert kwargs["if_generation_match"] == 0
        assert kwargs["checksum"] is None
        if self.bucket.fail_prefix and self.name.startswith(self.bucket.fail_prefix):
            raise RuntimeError("simulated upload failure")
        if self.name in self.bucket.objects:
            raise PreconditionFailed("exists")
        with open(filename, "rb") as stream:
            data = stream.read()
        self.bucket.sequence += 1
        self.bucket.objects[self.name] = (data, dict(self.metadata), self.bucket.sequence)

    def upload_from_string(self, data, **kwargs):
        assert kwargs["if_generation_match"] == 0
        assert kwargs["checksum"] is None
        if self.name in self.bucket.objects:
            raise PreconditionFailed("exists")
        self.bucket.sequence += 1
        self.bucket.objects[self.name] = (data, dict(self.metadata), self.bucket.sequence)

    def reload(self, **kwargs):
        data, self.metadata, self.generation = self.bucket.objects[self.name]
        self.size = len(data)

    def download_as_bytes(self, **kwargs):
        data, _, generation = self.bucket.objects[self.name]
        if kwargs["if_generation_match"] != generation:
            raise PreconditionFailed("generation changed")
        return data

    def download_to_filename(self, filename, **kwargs):
        with open(filename, "wb") as stream:
            stream.write(self.download_as_bytes(**kwargs))


class Bucket:
    def __init__(self):
        self.storage_class = "STANDARD"
        self.location = "US-EAST4"
        self.iam_configuration = SimpleNamespace(
            uniform_bucket_level_access_enabled=True,
            public_access_prevention="enforced",
        )
        self.lifecycle_rules = []
        self.objects = {}
        self.sequence = 0
        self.fail_prefix = None

    def blob(self, name):
        return Blob(self, name)

    def get_blob(self, name, **kwargs):
        if name not in self.objects:
            return None
        blob = self.blob(name)
        blob.reload()
        return blob


class Client:
    def __init__(self):
        self.bucket = Bucket()

    def get_bucket(self, name):
        assert name == "archive-test"
        return self.bucket
