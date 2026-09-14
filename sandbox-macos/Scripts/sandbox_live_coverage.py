"""Explicit limits of the selected consumer campaign, not release approval."""

NOT_COVERED = (
    "second_account_authorization",
    "in_flight_transport_disconnect_recovery",
    "broker_crash_restart_and_host_reboot_reconciliation",
    "submitted_launchd_job_respawn_cleanup",
    "physical_host_inventory_and_storage_removal",
    "renewal_and_admission_drain",
    "paired_guest_ci_build_and_test_performance",
    "cold_boot_and_two_vm_cpu_contention",
    "production_deployment_notarization_and_persistent_keychain",
    "host_owner_privacy_and_per_vm_cryptoerase",
)


def not_covered(config):
    return list(NOT_COVERED) + ([] if config.get("workspace_exhaustion", False)
                              else ["workspace_exhaustion"])
