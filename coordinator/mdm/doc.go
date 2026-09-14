// Package mdm exchanges read-only device-verification commands with MicroMDM.
// The Client owns command correlation and waiters; providercontrol/verification
// and providercontrol/mdmscheduler decide whether returned evidence applies to
// the current provider and may change its trust state.
//
// The source follows the exchange:
//   - client.go constructs the transport, shared state and late-response hooks.
//   - devices.go looks up enrollment and the serial-to-UDID binding.
//   - command_policy.go limits outbound requests to SecurityInfo and
//     DeviceInformation; commands.go issues them and pushes raw commands.
//   - command_tracking.go correlates one-shot responses with issued UUIDs.
//   - security_info.go compares the reported posture; security_info_waiter.go
//     owns its exclusive waiter, bounded early replies and cancellation.
//   - device_attestation.go requests the nonce-bound certificate chain and
//     owns its exclusive waiter; verification of the chain belongs to callers.
//   - webhook.go preserves the solicited-command and exact-waiter checks before
//     delivery or late callbacks; plist.go decodes only the requested fields.
//
// Waiter callbacks and channel delivery remain outside the client locks. Startup
// installs late-response hooks before serving. Structured SecurityInfo requests
// rely on MicroMDM's push; raw DeviceInformation requests explicitly push after
// publishing the command. Config and Mac model lookup remain in config.go and
// mac_models.go.
package mdm
