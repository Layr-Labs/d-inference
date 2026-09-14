"""Read-only binding of an explicitly selected, existing local GUI host user.

This user is the trusted host operator, not the tenant identity. Membership in
admin is reported, not rejected. No account, credential or login setting changes.
"""

from dataclasses import asdict, dataclass
import grp
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import uuid
from xml.parsers.expat import ExpatError


RUNTIME_GROUP = "darkbloom_runtime"
ATTRIBUTES = ("RecordName", "UniqueID", "PrimaryGroupID", "GeneratedUID",
              "NFSHomeDirectory", "UserShell")


@dataclass(frozen=True)
class GUIHostUser:
    recordName: str
    uid: int
    primaryGID: int
    generatedUID: str
    homeDirectory: str

    def record(self):
        return asdict(self)


def configured_user(value):
    """Require a full identity assertion, so UID reuse cannot silently rebind it."""
    if not isinstance(value, dict) or set(value) != set(GUIHostUser.__dataclass_fields__):
        raise ValueError("hostUser must explicitly bind recordName, uid, primaryGID, generatedUID and homeDirectory")
    if not isinstance(value["recordName"], str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,63}", value["recordName"]):
        raise ValueError("hostUser.recordName must be an existing local login short name")
    if (type(value["uid"]) is not int or not 501 <= value["uid"] < 2**32 - 1 or value["uid"] == 2001
            or type(value["primaryGID"]) is not int or not 0 < value["primaryGID"] < 2**32 - 1):
        raise ValueError("hostUser must select a nonroot local login UID distinct from tenant UID 2001 and a nonzero primary GID")
    encoded = value["generatedUID"]
    try:
        identifier = uuid.UUID(encoded) if isinstance(encoded, str) else None
    except ValueError:
        identifier = None
    if identifier is None or identifier.int == 0 or str(identifier).upper() != encoded:
        raise ValueError("hostUser.generatedUID must be a canonical uppercase nonzero UUID")
    home = value["homeDirectory"]
    if (not isinstance(home, str) or not home.startswith("/") or str(Path(home)) != home
            or ".." in Path(home).parts or any(ord(c) < 32 or ord(c) == 127 for c in home)
            or home in ("/", "/var/empty", "/private/var/empty")):
        raise ValueError("hostUser.homeDirectory must be an explicit canonical login home")
    return GUIHostUser(**value)


def _read(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=10,
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"})
    except (OSError, subprocess.SubprocessError):
        raise ValueError("GUI host identity query unavailable") from None
    if result.returncode != 0 or result.stderr or len(result.stdout) > 65536:
        raise ValueError("GUI host identity query unavailable")
    return result.stdout


def _membership(user, group):
    data = _read(["/usr/bin/dsmemberutil", "checkmembership", "-U", user.recordName, "-G", group]).strip()
    if data == b"user is a member of the group":
        return True
    if data == b"user is not a member of the group":
        return False
    raise ValueError("GUI host membership response not recognized")


def validate_gui_user(value, *, require_runtime_membership=False):
    expected = configured_user(value)
    if sys.platform != "darwin":
        raise ValueError("GUI host identity validation requires macOS")
    try:
        user = pwd.getpwnam(expected.recordName)
        by_id = pwd.getpwuid(expected.uid)
        group = grp.getgrgid(expected.primaryGID)
    except (KeyError, OSError):
        raise ValueError("selected GUI host identity does not exist") from None
    identity = lambda record: (record.pw_name, record.pw_uid, record.pw_gid, record.pw_dir, record.pw_shell)
    if (identity(user) != identity(by_id) or user.pw_name != expected.recordName
            or user.pw_uid != expected.uid or user.pw_gid != expected.primaryGID
            or user.pw_dir != expected.homeDirectory or group.gr_gid != expected.primaryGID
            or not user.pw_shell.startswith("/")
            or Path(user.pw_shell).name in ("false", "nologin", "true")):
        raise ValueError("selected GUI host Unix identity or login home changed")
    try:
        record = plistlib.loads(_read(["/usr/bin/dscl", "-plist", "/Local/Default", "-read",
                                      "/Users/" + expected.recordName, *ATTRIBUTES]))
    except (ValueError, TypeError, OverflowError, ExpatError):
        raise ValueError("GUI host local record response not recognized") from None
    attributes = {"RecordName": expected.recordName, "UniqueID": str(expected.uid),
                  "PrimaryGroupID": str(expected.primaryGID), "GeneratedUID": expected.generatedUID,
                  "NFSHomeDirectory": expected.homeDirectory, "UserShell": user.pw_shell}
    if not isinstance(record, dict) or any(record.get("dsAttrTypeStandard:" + key) != [value]
                                           for key, value in attributes.items()):
        raise ValueError("selected GUI host local identity changed or is ambiguous")
    home = Path(expected.homeDirectory).lstat()
    if not stat.S_ISDIR(home.st_mode) or home.st_uid != expected.uid or home.st_mode & 0o022:
        raise ValueError("selected GUI host home must be a real owned directory without shared writes")
    # Membership is only a planning observation. A freshly launched agent must
    # actually open and hold the native runtime authority; a DS answer cannot
    # establish the kernel groups of an already-running GUI login session.
    try:
        runtime = grp.getgrnam(RUNTIME_GROUP)
    except KeyError:
        runtime = None
    if runtime is not None:
        try:
            runtime_by_id = grp.getgrgid(runtime.gr_gid)
        except (KeyError, OSError):
            raise ValueError("runtime group reverse lookup unavailable") from None
        if (runtime.gr_name != RUNTIME_GROUP or runtime_by_id.gr_name != RUNTIME_GROUP
                or runtime_by_id.gr_gid != runtime.gr_gid or runtime.gr_gid in (0, 80, expected.primaryGID)):
            raise ValueError("runtime group must have a separate unambiguous nonprivileged identity")
    runtime_member = runtime is not None and _membership(expected, RUNTIME_GROUP)
    if require_runtime_membership and not runtime_member:
        raise ValueError("selected GUI host user must belong to darkbloom_runtime")
    return expected, {"admin_member": _membership(expected, "admin"),
                      "runtime_group_member": runtime_member,
                      "runtime_gid": None if runtime is None else runtime.gr_gid}
