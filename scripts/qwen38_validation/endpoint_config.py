"""Human-configured loopback transport for synthetic qualification harnesses.

No deployment address or credential is embedded. Setting these variables does
not authorize testing: obtain permission and reserve the inference lane first.
"""
import ipaddress
import os
from pathlib import Path
import stat
import urllib.parse
import urllib.request

BASE_VARIABLE = "QWEN38_VALIDATION_BASE_URL"
KEY_VARIABLE = "QWEN38_VALIDATION_API_KEY_FILE"

def base_url(environ=None):
    env = os.environ if environ is None else environ
    raw = env.get(BASE_VARIABLE, "")
    try:
        parsed = urllib.parse.urlsplit(raw)
        address = ipaddress.ip_address(parsed.hostname or "")
        port = parsed.port
    except ValueError as error:
        raise ValueError("Configure an explicit loopback IP origin and port") from None
    if (parsed.scheme != "http" or not address.is_loopback or port is None
            or not 1 <= port <= 65535 or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment or parsed.username is not None
            or parsed.password is not None):
        raise ValueError("Validation requires an explicit HTTP loopback origin without userinfo, path, query or fragment")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))

def connection_target():
    parsed = urllib.parse.urlsplit(base_url())
    return parsed.hostname, parsed.port

def headers():
    result = {"Content-Type": "application/json"}
    path = os.environ.get(KEY_VARIABLE)
    if path is None:
        return result
    location = Path(path)
    if not location.is_absolute():
        raise ValueError("The approved credential-file path must be absolute")
    descriptor = os.open(location, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("The approved credential file must be owned, regular and mode0600")
        token = stream.read(4097).strip()
    if not token or len(token) > 4096 or not all(33 <= ord(char) <= 126 for char in token):
        raise ValueError("Invalid bearer credential format")
    result["Authorization"] = "Bearer " + token
    return result

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def open_request(request, timeout=300):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    return opener.open(request, timeout=timeout)

def raw_http_headers(endpoint, content_length, *, close=False):
    if endpoint not in ("/v1/chat/completions", "/v1/responses"):
        raise ValueError("Unexpected qualification route")
    authority = urllib.parse.urlsplit(base_url()).netloc
    fields = {"Host": authority, **headers(), "Content-Length": str(content_length)}
    if close:
        fields["Connection"] = "close"
    return (f"POST {endpoint} HTTP/1.1\r\n" +
            "".join(f"{name}: {value}\r\n" for name, value in fields.items()) + "\r\n").encode()
