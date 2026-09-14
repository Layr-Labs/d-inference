"""Generate an explicit GUI-session qualification plan; never activate it."""

from pathlib import Path
import plistlib
import shlex
import uuid

from sandbox_release_support import HOST_ID, new_directory, write_json


UNVERIFIED = ["installed identity enforcement in the actual agent", "actual agent GUI/audit context",
              "actual agent runtime authority access", "guest readiness and isolation",
              "provisioned key persistence", "logout cleanup and login recovery",
              "coordinator admission and reconnect", "notarization"]


def installed_job_path(configuration):
    host_id = str(uuid.UUID(configuration["hostID"]))
    return Path("/Library/Application Support/Darkbloom/host-plans") / host_id / (HOST_ID + ".plist")


def installed_identity_path(configuration):
    return installed_job_path(configuration).with_name("host-user.json")


def identity_document(configuration, user):
    return {"schema_version": 1, "host_id": str(uuid.UUID(configuration["hostID"])), "host_user": user.record()}


def launch_agent(arguments):
    # A root-owned definition is explicitly loaded into ONE chosen GUI domain.
    # No global /Library/LaunchAgents auto-loading, credential switching, shell,
    # altered HOME, or fabricated security-session environment is involved.
    return {"Label": HOST_ID, "ProgramArguments": arguments,
            "LimitLoadToSessionType": "Aqua", "RunAtLoad": True,
            "KeepAlive": False, "ProcessType": "Interactive", "Umask": 63,
            "EnvironmentVariables": {"LUME_TELEMETRY_ENABLED": "false", "LUME_LOG_LEVEL": "error"}}


def generate_gui_plan(configuration, arguments, user, observations, manifest, package, install_root, output):
    target = new_directory(output)
    filename = HOST_ID + ".plist"
    (target / filename).write_bytes(plistlib.dumps(launch_agent(arguments)))
    job = installed_job_path(configuration)
    write_json(target / "host-user.json", identity_document(configuration, user))
    (target / "host-user.json").chmod(0o444)
    domain = f"gui/{user.uid}"
    # Reviewable qualification commands, not an executable activation script.
    # Only a later explicitly authorized operator may run them after the gates.
    commands = {"bootstrap": ["/bin/launchctl", "bootstrap", domain, str(job)],
                "bootout": ["/bin/launchctl", "bootout", domain + "/" + HOST_ID]}
    write_json(target / "plan.json", {
        "schema_version": 2, "deployment": "selected_gui_user", "installed": False,
        "host_user": user.record(), "identity_observations": observations,
        "install_root": str(install_root), "installed_job_path": str(job),
        "host_identity_file": str(installed_identity_path(configuration)),
        "launchd_domain": domain, "program_arguments": arguments,
        "qualification_commands": commands, "production_ready": False,
        "automatic_login_startup": False, "activation_script_generated": False,
        "not_verified": UNVERIFIED,
    })
    quote = lambda value: shlex.quote(str(value))
    text = f"""# GUI-user host qualification plan

This plan selects the existing local user `{user.recordName}`, UID {user.uid},
primary GID {user.primaryGID}, GeneratedUID `{user.generatedUID}`, home
{quote(user.homeDirectory)}. Its signed package is version {manifest['version']}.
The user is the trusted host operator and can inspect host-side VM plaintext.
An explicitly selected administrator is permitted. A separate nonadmin GUI login
account reduces exposure to unrelated host files; account creation, credentials,
keychains, automatic login and group changes are never performed by this tool.
Tenant commands still execute only inside the VM as numeric UID/GID 2001.

The prior hidden nonlogin LaunchDaemon deployment is unsupported: matching BSD
credentials do not establish a Virtualization-compatible graphical session.
This plan is for qualification, not production activation. No activation script
is generated. It does not establish recurring login startup, runtime identity
enforcement in the installed agent, actual GUI/audit context, guest readiness, or logout cleanup.

1. Review this selected user on the target Mac. Generation and installed
   validation compare its exact local DirectoryService identity with Unix
   lookup, including GeneratedUID, so a reused UID is insufficient. The plan
   queries no password/authentication attributes and preserves existing groups.
   Reported admin membership is {str(observations['admin_member']).lower()}.
   Do not convert an inference host or stop another workload implicitly.
2. Install the exact signed package from {quote(package)} into the fresh root
   {quote(install_root)} with `/usr/bin/ditto --rsrc --extattr`. Preserve signature
   xattrs and every file digest. Code must be root:wheel: public directories
   0755, data 0644, executables 0755, without symlinks, hard links or ACLs.
   Keep the pinned Lume subtree at its signed immutable 0555/0444 modes.
   Never re-sign guest artifacts or add this plan to the signed release tree.
3. Provision private state for this selected UID: storage
   {quote(configuration['storageDirectory'])} and capacity
   {quote(configuration['capacityDirectory'])} at 0700; the token
   {quote(configuration['tokenFile'])} at 0600 in a private 0700 parent.
   Use encrypted APFS for all three. Ancestors must be trusted root/selected-user
   directories without shared writes or extended ACLs. Other GUI users must not
   have access. Never place token contents in arguments, environment or plans.
4. Preserve the machine-wide runtime authority at
   `/Library/Application Support/Darkbloom/runtime/ownership.lock`: root-owned
   single-link empty inode, mode 0660, group `darkbloom_runtime`, parent 0750 in
   that group. Provision only when absent; never truncate or replace it. Add
   only intended host runtime users through a separately authorized operation.
   DirectoryService membership does not prove that an existing GUI session has
   new kernel groups. The actual LaunchAgent must acquire native EX successfully.
   Provider inference holds SH through engine cleanup; broker and VM hold EX
   through VM cleanup. Existing uncoordinated providers require an explicit
   upgrade/restart before qualification.
5. Place the generated {filename} at {quote(job)} as root:wheel 0644 under
   root-owned 0755 parents, without ACLs or writable ancestors. Install its
   generated host-user.json sibling as root:wheel 0444, preserving the exact
   JSON. The process requires this host-ID/user binding before machine EX;
   every serve mode enforces it. No runtime flag relaxes this ownership rule.
   This path is
   deliberately outside global `/Library/LaunchAgents`: the definition must not
   autoload into every logged-in user's session. Run this tool with the same
   configuration, `--gui-user-plan --verify-installed`, before an operator starts
   the qualification job. Installed validation remains `production_ready=false`.
6. The selected user must already have a real Aqua login session. A later
   authorized qualification action may load this exact definition with:

```sh
{shlex.join(commands['bootstrap'])}
```

   The definition contains no UserName/GroupName, sudo, shell, setsid or HOME
   override. It inherits the selected GUI session's natural audit/security
   context. The actual process inspector must pass; an SSH process, root
   `launchctl asuser`, or an unrelated console login is not equivalent proof.
   Keep coordinator admission disabled and the capacity store draining.
7. The one-shot job uses KeepAlive=false so an unqualified failure cannot cause
   an automatic restart loop. No relogin startup is installed. Logout ends
   availability; login alone does not restore it. Before any availability claim,
   prove actual logout/agent-death cleanup, inherited VM authority retention,
   reconciliation and fresh-login recovery. Preserve capacity on unknown cleanup.
   The operator unload command for this exact domain is:

```sh
{shlex.join(commands['bootout'])}
```

   Independently prove VM owner termination, lifecycle cleanup and no remaining
   image/authority holders. A successful launchctl exit alone is insufficient.
   This plan never changes host mode to sandbox_dedicated or stops inference.

Selected-context VZ boot/stop is independent of guest-control readiness. Required
remaining checks are recorded in plan.json; no template or capacity is published.
"""
    (target / "INSTALLATION_PLAN.md").write_text(text)
    return {"plan": str(target / "INSTALLATION_PLAN.md"), "installed": False,
            "deployment": "selected_gui_user", "production_ready": False}
