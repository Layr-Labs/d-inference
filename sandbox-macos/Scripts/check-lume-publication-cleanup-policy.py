#!/usr/bin/env python3

from __future__ import annotations

import argparse
import ast
import re
import sys
from collections.abc import Iterable
from pathlib import Path


FORBIDDEN_NAMESPACE_ATTRIBUTES = frozenset(
    {
        "removedirs",
        "rmdir",
        "rmtree",
        "unlink",
        "unlinkat",
    }
)
FORBIDDEN_DYNAMIC_SYMBOLS = FORBIDDEN_NAMESPACE_ATTRIBUTES | {"remove"}
ALLOWED_OS_GETATTR_NAMES = frozenset({"O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW"})
FORBIDDEN_PROCESS_MODULES = frozenset({"commands", "subprocess"})
SHELL_DELETION_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_])(?:/[A-Za-z0-9_./-]*/)?(?:rm|rmdir|unlink)"
    r"(?![A-Za-z0-9_-])"
)
ALLOWED_BUILD_ROOT_CLEANUP = 'rm -rf "$BUILD_ROOT" || finalization_failed=1'


def assigned_names(node: ast.AST) -> set[str]:
    if isinstance(node, ast.Name):
        return {node.id}
    if isinstance(node, (ast.Tuple, ast.List)):
        return {
            name
            for element in node.elts
            for name in assigned_names(element)
        }
    return set()


def assignment_pairs(tree: ast.AST) -> Iterable[tuple[set[str], ast.AST]]:
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            names = {
                name
                for target in node.targets
                for name in assigned_names(target)
            }
            yield names, node.value
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            yield assigned_names(node.target), node.value
        elif isinstance(node, ast.NamedExpr):
            yield assigned_names(node.target), node.value


def imported_aliases(tree: ast.AST, module: str) -> set[str]:
    aliases: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Import):
            continue
        for imported in node.names:
            if imported.name == module:
                aliases.add(imported.asname or module)
    return aliases


def propagated_aliases(tree: ast.AST, initial: set[str]) -> set[str]:
    aliases = set(initial)
    changed = True
    while changed:
        changed = False
        for targets, value in assignment_pairs(tree):
            if isinstance(value, ast.Name) and value.id in aliases:
                additions = targets - aliases
                aliases.update(additions)
                changed = changed or bool(additions)
    return aliases


def native_library_aliases(tree: ast.AST, ctypes_aliases: set[str]) -> set[str]:
    aliases: set[str] = set()
    for targets, value in assignment_pairs(tree):
        if not isinstance(value, ast.Call) or not isinstance(value.func, ast.Attribute):
            continue
        owner = value.func.value
        if (
            isinstance(owner, ast.Name)
            and owner.id in ctypes_aliases
            and value.func.attr in {"CDLL", "PyDLL"}
        ):
            aliases.update(targets)
    return propagated_aliases(tree, aliases)


def location(path: str, node: ast.AST) -> str:
    return f"{path}:{getattr(node, 'lineno', '?')}"


def python_policy_violations(source: str, path: str) -> list[str]:
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as error:
        return [f"{path}:{error.lineno or '?'}: invalid Python: {error.msg}"]

    violations: list[str] = []
    os_aliases = propagated_aliases(tree, imported_aliases(tree, "os"))
    ctypes_aliases = propagated_aliases(tree, imported_aliases(tree, "ctypes"))
    native_aliases = native_library_aliases(tree, ctypes_aliases)

    for node in ast.walk(tree):
        node_location = location(path, node)
        if isinstance(node, ast.Import):
            for imported in node.names:
                root_module = imported.name.split(".", 1)[0]
                if root_module in FORBIDDEN_PROCESS_MODULES:
                    violations.append(
                        f"{node_location}: process module import is forbidden: "
                        f"{imported.name}"
                    )
        elif isinstance(node, ast.ImportFrom):
            root_module = (node.module or "").split(".", 1)[0]
            if root_module in FORBIDDEN_PROCESS_MODULES:
                violations.append(
                    f"{node_location}: process module import is forbidden: "
                    f"{node.module}"
                )
            if node.module == "os":
                violations.append(
                    f"{node_location}: direct os imports bypass capability checks"
                )
        elif isinstance(node, ast.Attribute):
            owner = node.value
            owner_name = owner.id if isinstance(owner, ast.Name) else None
            if node.attr in FORBIDDEN_NAMESPACE_ATTRIBUTES:
                violations.append(
                    f"{node_location}: namespace deletion capability is forbidden: "
                    f"{node.attr}"
                )
            elif node.attr == "remove" and (
                owner_name in os_aliases or owner_name in native_aliases
            ):
                violations.append(
                    f"{node_location}: namespace deletion capability is forbidden: "
                    f"{node.attr}"
                )
            elif owner_name in os_aliases and (
                node.attr in {"popen", "system"}
                or node.attr.startswith("exec")
                or node.attr.startswith("spawn")
            ):
                violations.append(
                    f"{node_location}: process execution capability is forbidden: "
                    f"os.{node.attr}"
                )
            elif owner_name in native_aliases and node.attr == "system":
                violations.append(
                    f"{node_location}: native process execution is forbidden"
                )
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            if node.func.id in {"__import__", "compile", "eval", "exec"}:
                violations.append(
                    f"{node_location}: dynamic code execution is forbidden: "
                    f"{node.func.id}"
                )
            elif node.func.id == "getattr":
                allowed = (
                    len(node.args) >= 2
                    and isinstance(node.args[0], ast.Name)
                    and node.args[0].id in os_aliases
                    and isinstance(node.args[1], ast.Constant)
                    and node.args[1].value in ALLOWED_OS_GETATTR_NAMES
                )
                if not allowed:
                    violations.append(
                        f"{node_location}: dynamic attribute access is forbidden"
                    )
        elif (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and node.value in FORBIDDEN_DYNAMIC_SYMBOLS
        ):
            violations.append(
                f"{node_location}: dynamic deletion symbol is forbidden: "
                f"{node.value}"
            )

    return sorted(set(violations))


def shell_policy_violations(
    source: str,
    path: str,
    allowed_deletion_lines: frozenset[str] = frozenset(),
) -> list[str]:
    violations: list[str] = []
    observed_allowed = {line: 0 for line in allowed_deletion_lines}
    for line_number, line in enumerate(source.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped in observed_allowed:
            observed_allowed[stripped] += 1
            continue
        if SHELL_DELETION_PATTERN.search(stripped):
            violations.append(
                f"{path}:{line_number}: shell deletion capability is forbidden"
            )

    for allowed_line, count in observed_allowed.items():
        if count != 1:
            violations.append(
                f"{path}: expected one identity-independent build cleanup line, "
                f"found {count}: {allowed_line}"
            )
    return violations


def assert_policy_result(
    name: str,
    violations: list[str],
    *,
    should_pass: bool,
) -> None:
    if should_pass and violations:
        raise AssertionError(f"{name} unexpectedly failed: {violations}")
    if not should_pass and not violations:
        raise AssertionError(f"{name} unexpectedly passed")


def run_self_test() -> None:
    python_cases = {
        "benign-collection-remove": ("items = []\nitems.remove('value')\n", True),
        "direct-unlink": ("import os\nos.unlink('/tmp/staging')\n", False),
        "imported-alias": (
            "from os import unlink as delete_path\ndelete_path('/tmp/staging')\n",
            False,
        ),
        "assigned-alias": (
            "import os\ndelete_path = os.remove\ndelete_path('/tmp/staging')\n",
            False,
        ),
        "module-alias": (
            "import os\nfilesystem = os\nfilesystem.remove('/tmp/staging')\n",
            False,
        ),
        "dynamic-getattr": (
            "import os\ngetattr(os, 'rmdir')('/tmp/staging')\n",
            False,
        ),
        "pathlib-unlink": (
            "from pathlib import Path\nPath('/tmp/staging').unlink()\n",
            False,
        ),
        "native-remove": (
            "import ctypes\nlibc = ctypes.CDLL(None)\nlibc.remove(b'/tmp/staging')\n",
            False,
        ),
        "subprocess-rm": (
            "import subprocess\nsubprocess.run(['/bin/rm', '-rf', '/tmp/staging'])\n",
            False,
        ),
    }
    for name, (source, should_pass) in python_cases.items():
        assert_policy_result(
            name,
            python_policy_violations(source, name),
            should_pass=should_pass,
        )

    allowed = frozenset({ALLOWED_BUILD_ROOT_CLEANUP})
    allowed_source = f"{ALLOWED_BUILD_ROOT_CLEANUP}\n"
    shell_cases = {
        "build-root-cleanup": (
            allowed_source,
            allowed,
            True,
        ),
        "staging-rm": (
            allowed_source + 'rm -rf "$STAGING_DIR"\n',
            allowed,
            False,
        ),
        "staging-rmdir": (
            allowed_source + '/bin/rmdir "$STAGING_DIR"\n',
            allowed,
            False,
        ),
        "aliased-shell-delete": (
            allowed_source + 'DELETE=/bin/rm\n"$DELETE" -rf "$STAGING_DIR"\n',
            allowed,
            False,
        ),
    }
    for name, (source, allowed_lines, should_pass) in shell_cases.items():
        assert_policy_result(
            name,
            shell_policy_violations(source, name, allowed_lines),
            should_pass=should_pass,
        )

    print(
        "lume_publication_cleanup_policy_self_test="
        f"exact:{len(python_cases) + len(shell_cases)}"
    )


def read_text(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Enforce quarantine-only Lume staging cleanup"
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--python-helper")
    parser.add_argument("--build-script")
    parser.add_argument("--quarantine-script")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.self_test:
        run_self_test()

    target_arguments = (
        arguments.python_helper,
        arguments.build_script,
        arguments.quarantine_script,
    )
    if not any(target_arguments):
        if arguments.self_test:
            return 0
        raise SystemExit("publication policy targets are required")
    if not all(target_arguments):
        raise SystemExit("all publication policy targets are required")

    violations = python_policy_violations(
        read_text(arguments.python_helper),
        arguments.python_helper,
    )
    violations.extend(
        shell_policy_violations(
            read_text(arguments.build_script),
            arguments.build_script,
            frozenset({ALLOWED_BUILD_ROOT_CLEANUP}),
        )
    )
    violations.extend(
        shell_policy_violations(
            read_text(arguments.quarantine_script),
            arguments.quarantine_script,
        )
    )
    if violations:
        raise SystemExit(
            "automatic staging deletion is forbidden; quarantine instead:\n"
            + "\n".join(f"- {violation}" for violation in sorted(violations))
        )
    print("lume_publication_cleanup_policy=quarantine-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
