"""Read-only validation of the installed trusted, nonadmin broker account.

This validates account policy, not confinement of the service to its own files.
macOS ambient group memberships remain possible and are not altered here.
"""

from dataclasses import dataclass
import grp
import os
import plistlib
import pwd
import re
import subprocess
import sys
from xml.parsers.expat import ExpatError


BROKER_NAME = "_darkbloom_sandbox"
RUNTIME_GROUP_NAME = "darkbloom_runtime"
ATTRIBUTES = ["RecordName", "UniqueID", "PrimaryGroupID", "UserShell",
              "NFSHomeDirectory", "AuthenticationAuthority", "IsHidden"]
DISABLED_AUTHORITY = re.compile(r";DisabledUser;(?:;ShadowHash;HASHLIST:<[A-Z0-9,_-]+>)?")


@dataclass(frozen=True)
class SandboxBrokerAccount:
    uid: int
    gid: int


def _read_command(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=10,
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"})
    except (OSError, subprocess.SubprocessError):
        raise ValueError("broker account verification unavailable: system query failed") from None
    if result.returncode != 0 or result.stderr or len(result.stdout) > 65536:
        raise ValueError("broker account verification unavailable: system query failed")
    return result.stdout


def _attribute(record, name):
    namespace = "dsAttrTypeNative:" if name == "IsHidden" else "dsAttrTypeStandard:"
    value = record.get(namespace + name)
    if not isinstance(value, list) or not value or any(not isinstance(item, str) for item in value):
        raise ValueError("broker account verification unavailable: required account attribute missing or invalid")
    return value


def _member(group):
    data = _read_command(["/usr/bin/dsmemberutil", "checkmembership", "-U", BROKER_NAME, "-G", group])
    if data.strip() == b"user is a member of the group":
        return True
    if data.strip() == b"user is not a member of the group":
        return False
    raise ValueError("broker account verification unavailable: membership response not recognized")


def validate_broker_account():
    """Require the documented dedicated-account shape and return only safe IDs."""
    if sys.platform != "darwin" or os.geteuid() != 0:
        raise ValueError("--verify-installed requires root to read protected broker authentication policy")
    try:
        user = pwd.getpwnam(BROKER_NAME)
        private_group = grp.getgrnam(BROKER_NAME)
        runtime_group = grp.getgrnam(RUNTIME_GROUP_NAME)
        user_by_id = pwd.getpwuid(user.pw_uid)
        group_by_id = grp.getgrgid(private_group.gr_gid)
        runtime_by_id = grp.getgrgid(runtime_group.gr_gid)
    except (KeyError, OSError):
        raise ValueError("broker account verification unavailable: required service identity missing") from None
    if (user.pw_name != BROKER_NAME or user_by_id.pw_name != BROKER_NAME
            or private_group.gr_name != BROKER_NAME or group_by_id.gr_name != BROKER_NAME
            or runtime_group.gr_name != RUNTIME_GROUP_NAME or runtime_by_id.gr_name != RUNTIME_GROUP_NAME
            or user.pw_uid <= 0 or private_group.gr_gid <= 0 or runtime_group.gr_gid <= 0
            or private_group.gr_gid in (0, 80) or runtime_group.gr_gid in (0, 80)
            or user.pw_gid != private_group.gr_gid or runtime_group.gr_gid == private_group.gr_gid):
        raise ValueError("broker must use its dedicated non-root user and private primary group")
    data = _read_command(["/usr/bin/dscl", "-plist", "/Local/Default", "-read",
                          "/Users/" + BROKER_NAME] + ATTRIBUTES)
    try:
        record = plistlib.loads(data)
    except (ValueError, TypeError, OverflowError, ExpatError):
        raise ValueError("broker account verification unavailable: account response not recognized") from None
    if not isinstance(record, dict):
        raise ValueError("broker account verification unavailable: account response not recognized")
    expected = {"RecordName": [BROKER_NAME], "UniqueID": [str(user.pw_uid)],
                "PrimaryGroupID": [str(private_group.gr_gid)], "UserShell": ["/usr/bin/false"],
                "IsHidden": ["1"]}
    if any(_attribute(record, key) != value for key, value in expected.items()):
        raise ValueError("broker must be a hidden nonlogin account matching its Unix identity")
    home = _attribute(record, "NFSHomeDirectory")
    if (home not in [["/var/empty"], ["/private/var/empty"]]
            or user.pw_dir not in ("/var/empty", "/private/var/empty")
            or user.pw_shell != "/usr/bin/false"):
        raise ValueError("broker must use /var/empty and /usr/bin/false")
    authorities = _attribute(record, "AuthenticationAuthority")
    # Support the fresh role-account marker and fully disabled ShadowHash
    # wrappers. Mixed active authorities and unknown encodings fail closed.
    if any(DISABLED_AUTHORITY.fullmatch(authority) is None for authority in authorities):
        raise ValueError("broker authentication must be disabled using a supported DisabledUser authority")
    if _member("admin") or _member("wheel"):
        raise ValueError("broker must not be a member of admin or wheel")
    if not _member(RUNTIME_GROUP_NAME):
        raise ValueError("broker must be a member of darkbloom_runtime")
    return SandboxBrokerAccount(uid=user.pw_uid, gid=private_group.gr_gid)
