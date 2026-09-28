"""Read immutable Git objects as data; never check out or execute PR source."""
import base64
import difflib
import re
from .client import ReviewUnavailable


class Sources:
    def __init__(self, github):
        self.github = github
        self.trees, self.roots, self.blobs = {}, {}, {}

    def tree(self, sha):
        if sha not in self.trees:
            result = self.github.call(f"/git/trees/{sha}")
            if result.get("truncated") or not isinstance(result.get("tree"), list):
                raise ReviewUnavailable("Incomplete source tree")
            self.trees[sha] = {entry["path"]: entry for entry in result["tree"]}
        return self.trees[sha]

    def read(self, revision, path):
        if revision not in self.roots:
            commit = self.github.call(f"/git/commits/{revision}")
            self.roots[revision] = commit["tree"]["sha"]
        parts = path.split("/")
        if any(part in ("", ".", "..") for part in parts):
            raise ReviewUnavailable("Invalid source path")
        sha = self.roots[revision]
        for index, part in enumerate(parts):
            if not re.fullmatch(r"[0-9a-f]{40}", sha):
                raise ReviewUnavailable("Invalid source object")
            entry = self.tree(sha).get(part)
            if not entry:
                raise ReviewUnavailable("Missing source object")
            sha = entry["sha"]
            if index < len(parts) - 1 and entry["type"] != "tree":
                raise ReviewUnavailable("Source path traverses a non-directory")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ReviewUnavailable("Invalid source blob")
        if entry["type"] != "blob":
            raise ReviewUnavailable("Submodule source requires a separate review")
        if sha not in self.blobs:
            blob = self.github.call(f"/git/blobs/{sha}")
            if blob.get("encoding") != "base64":
                raise ReviewUnavailable("Unsupported source encoding")
            raw = base64.b64decode(blob["content"], validate=False)
            if len(raw) != blob["size"] or b"\0" in raw:
                raise ReviewUnavailable("Binary or incomplete source")
            try:
                self.blobs[sha] = raw.decode("utf-8")
            except UnicodeDecodeError:
                raise ReviewUnavailable("Non-text source requires a separate review") from None
        return self.blobs[sha], entry["mode"]


def complete_files(github, files, base, head):
    """Replace possibly truncated API patches with diffs of complete Git blobs."""
    sources, complete = Sources(github), []
    for original in files:
        file = dict(original)
        try:
            old_path = file.get("previous_filename", file["filename"])
            before, old_mode = ("", None) if file["status"] == "added" else sources.read(base, old_path)
            after, new_mode = ("", None) if file["status"] == "removed" else sources.read(head, file["filename"])
            file["base_text"], file["head_text"] = before, after
            file["base_mode"], file["head_mode"] = old_mode, new_mode
            # splitlines handles a missing final newline without joining diff lines.
            lines = list(difflib.unified_diff(before.splitlines(), after.splitlines(),
                                            fromfile=old_path, tofile=file["filename"], lineterm=""))
            file["patch"] = "\n".join(lines[2:])
            file["additions"] = sum(line.startswith("+") for line in lines[2:])
            file["deletions"] = sum(line.startswith("-") for line in lines[2:])
            file["source_complete"] = True
        except (ReviewUnavailable, KeyError, ValueError, TypeError):
            # Do not expose API response/exception text. Preserve any API patch,
            # but never classify this file as completely reviewed.
            file["source_complete"] = False
        complete.append(file)
    return complete
