"""Extract signed bundles without losing non-Mach-O signing attributes."""
import os
from pathlib import Path
import posixpath
import sys
import tarfile


def _reject_unsafe_member(member):
    name = member.name
    if os.path.isabs(name) or any(part == '..' for part in Path(name).parts):
        raise ValueError(f'unsafe path in bundle archive: {name}')
    if member.issym() or member.islnk():
        target = member.linkname or ''
        if os.path.isabs(target) or any(part == '..' for part in Path(target).parts):
            raise ValueError(f'unsafe link in bundle archive: {name} -> {target}')


def _darwin_setxattr(path, name, value):
    """CPython's os.setxattr is Linux-only (no macOS implementation), so the
    stdlib has no portable call for this. libc's setxattr(2) exists on every
    Darwin, so bind it directly via ctypes rather than shelling out."""
    import ctypes
    import ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.setxattr.restype = ctypes.c_int
    if libc.setxattr(path.encode('utf-8'), name.encode('utf-8'), value, len(value), 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def _set_xattr(path, name, value):
    if hasattr(os, 'setxattr'):
        os.setxattr(path, name, value)
    elif sys.platform == 'darwin':
        _darwin_setxattr(path, name, value)
    else:
        raise OSError('extended attributes are not supported on this platform')


def _restore_signing_xattrs(dest, members):
    """release-swift.yml extracts the retained bundle with native /usr/bin/tar
    ("Native tar restores the non-Mach-O signing extended attributes"):
    codesign stores the ad-hoc signature of non-Mach-O bundle members (e.g.
    mlx.metallib) in com.apple.cs.* extended attributes, which Python's
    tarfile.extractall never writes back to disk even though it parses them
    into each member's PAX headers (SCHILY.xattr.<name>, surrogateescape-
    decoded). Without this, `codesign --verify --deep --strict` falsely
    reports those members "not signed at all" after a tarfile-based extract."""
    prefix = 'SCHILY.xattr.'
    for member in members:
        headers = getattr(member, 'pax_headers', None) or {}
        xattrs = {k[len(prefix):]: v for k, v in headers.items() if k.startswith(prefix)}
        if not xattrs:
            continue
        target = dest / member.name
        if not target.is_file():
            continue
        for name, value in xattrs.items():
            try:
                _set_xattr(str(target), name, value.encode('utf-8', 'surrogateescape'))
            except OSError:
                pass


def _normalize_member_name(name):
    return name[2:] if name.startswith('./') else name


def _drop_apple_double_sidecars(members):
    """The release build's archive carries some non-Mach-O signatures twice:
    once as PAX SCHILY.xattr.* headers on the real entry (restored above),
    and once more as a legacy AppleDouble sidecar entry (`._name`, empty PAX
    headers) next to it, for tools that don't understand PAX xattrs. Native
    tar consumes/discards that sidecar on extraction rather than writing it
    out as a visible file; tarfile.extractall does not, and the stray file
    then makes the app bundle's sealed-resource manifest (_CodeSignature/
    CodeResources) invalid. Drop only sidecars that have a real counterpart
    entry, exactly matching what native tar leaves on disk."""
    names = {_normalize_member_name(m.name) for m in members}
    kept = []
    for member in members:
        norm = _normalize_member_name(member.name)
        dirpart, base = posixpath.split(norm)
        if base.startswith('._') and len(base) > 2:
            real = posixpath.join(dirpart, base[2:]) if dirpart else base[2:]
            if real in names:
                continue
        kept.append(member)
    return kept


def safe_extract(bundle_path, dest):
    with tarfile.open(bundle_path, 'r:gz') as tar:
        all_members = tar.getmembers()
        for member in all_members:
            _reject_unsafe_member(member)
        members = _drop_apple_double_sidecars(all_members)
        try:
            tar.extractall(dest, members=members, filter='data')
        except TypeError:
            # Python < 3.12 without PEP 706 filter support: members were
            # already vetted above.
            tar.extractall(dest, members=members)
        _restore_signing_xattrs(dest, members)


