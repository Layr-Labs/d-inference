"""The redirect rule of the fixture download scripts.

A download follows a redirect only when the target has the origin (scheme, host
and port) of the URL that answered with it, and the target has no credentials.
A caller can allow one more redirect: from https://huggingface.co to an HTTPS
Hugging Face CDN host on port 443, that is `hf.co` or a name that ends in
`.hf.co`. The Hub answers a file stored with Xet or LFS with a 302 to such a
host (for example `us.aws.cdn.hf.co`, `cas-bridge.xethub.hf.co` or
`cdn-lfs-us-1.hf.co`). The pinned SHA-256 of each fixture still protects its
bytes. Every other redirect raises ValueError before its target is requested.
"""

import urllib.parse
import urllib.request

DEFAULT_PORTS = {"http": 80, "https": 443}
HUGGING_FACE_HUB_ORIGIN = ("https", "huggingface.co", 443)
HUGGING_FACE_CDN_DOMAIN = "hf.co"


def origin(url):
    parts = urllib.parse.urlsplit(url)
    return parts.scheme, parts.hostname, parts.port or DEFAULT_PORTS.get(parts.scheme)


def redirect_allowed(source, target, hugging_face_cdn=False):
    parts = urllib.parse.urlsplit(target)
    if parts.username is not None or parts.password is not None:
        return False
    if origin(target) == origin(source):
        return True
    if not hugging_face_cdn or origin(source) != HUGGING_FACE_HUB_ORIGIN:
        return False
    host = parts.hostname or ""
    # An exact name or a dot-separated suffix: hf.co.evil.example and evilhf.co do not match.
    return (origin(target) == ("https", host, 443)
            and (host == HUGGING_FACE_CDN_DOMAIN or host.endswith("." + HUGGING_FACE_CDN_DOMAIN)))


class OriginRedirect(urllib.request.HTTPRedirectHandler):
    """A urllib redirect handler that applies redirect_allowed to each hop."""

    def __init__(self, hugging_face_cdn=False):
        self.hugging_face_cdn = hugging_face_cdn

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not redirect_allowed(req.full_url, newurl, self.hugging_face_cdn):
            raise ValueError("fixture download redirected to another origin")
        return super().redirect_request(req, fp, code, msg, headers, newurl)
