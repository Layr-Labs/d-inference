import SwiftUI

struct MyMacLatestReportSection: View {
    let mac: MyMac

    var body: some View {
        MyMacDetailSection("Latest report") {
            MyMacFactRow("Last reported", value: date(mac.lastSeen))
            if let heartbeat = mac.live?.lastHeartbeat {
                MyMacFactRow("Last heartbeat", value: date(heartbeat))
            }
            MyMacFactRow("Last verified", value: date(mac.challenge.lastVerifiedAt))
            MyMacFactRow("Provider version", value: versionValue)
        }
    }

    private var versionValue: String {
        let installed = mac.version.installed ?? MyMacsPresentation.notReported
        switch mac.version.disposition {
        case .current:
            return "\(installed) · Current"
        case .updateAvailable:
            return "\(installed) · Update available"
        case .belowMinimum:
            return "\(installed) · Below required version"
        case .unknown:
            return mac.version.installed == nil ? installed : "\(installed) · Update status unavailable"
        }
    }

    private func date(_ value: Date?) -> String {
        value?.formatted(date: .abbreviated, time: .shortened)
            ?? MyMacsPresentation.notReported
    }
}

struct MyMacHardwareSection: View {
    let mac: MyMac

    var body: some View {
        MyMacDetailSection("Hardware", detail: "Reported by this provider") {
            if mac.hardware == nil {
                Text("Hardware information has not been reported.")
                    .font(.body).foregroundStyle(.secondary)
            } else {
                MyMacFactRow("Unified memory", value: memory)
                MyMacFactRow("CPU cores", value: integer(mac.hardware?.cpuCoreCount))
                MyMacFactRow("GPU cores", value: integer(mac.hardware?.gpuCoreCount))
                DisclosureGroup("More hardware details") {
                    VStack(alignment: .leading, spacing: 12) {
                        MyMacFactRow("Memory available for inference", value: availableMemory)
                        MyMacFactRow("Performance cores", value: integer(mac.hardware?.performanceCoreCount))
                        MyMacFactRow("Efficiency cores", value: integer(mac.hardware?.efficiencyCoreCount))
                        MyMacFactRow("Memory bandwidth", value: memoryBandwidth)
                    }
                    .padding(.top, 10)
                }
                .font(.body)
            }
        }
    }

    private var memory: String {
        mac.hardware?.memoryGB.map { "\($0) GB" } ?? MyMacsPresentation.notReported
    }

    private var availableMemory: String {
        mac.hardware?.memoryAvailableGB.map {
            $0.formatted(.number.precision(.fractionLength(0 ... 1))) + " GB"
        } ?? MyMacsPresentation.notReported
    }

    private var memoryBandwidth: String {
        mac.hardware?.memoryBandwidthGBs.map {
            $0.formatted(.number.precision(.fractionLength(0 ... 1))) + " GB/s"
        } ?? MyMacsPresentation.notReported
    }

    private func integer(_ value: Int?) -> String {
        value?.formatted() ?? MyMacsPresentation.notReported
    }
}

struct MyMacModelsSection: View {
    let mac: MyMac

    var body: some View {
        MyMacDetailSection("Reported models", detail: "Advertised by this provider") {
            modelCatalog

            Divider()
                .padding(.vertical, 2)

            Text("Capacity report")
                .font(.body.weight(.semibold))
            capacity
        }
    }

    @ViewBuilder
    private var modelCatalog: some View {
        if let models = mac.models {
            if models.isEmpty {
                Text("No models reported")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(models) { model in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "shippingbox")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                    .font(.body.weight(.medium))
                                    .monospaced()
                                    .textSelection(.enabled)
                                Text(modelDetail(model))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            Text(MyMacsPresentation.notReported)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var capacity: some View {
        switch mac.live?.capacity ?? .unavailable {
        case let .backendSlots(capacity):
            VStack(alignment: .leading, spacing: 8) {
                Text("Backend slots are the current capacity report.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if capacity.slots.isEmpty {
                    Text("No backend slots reported")
                        .font(.body)
                } else {
                    ForEach(capacity.slots) { slot in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.modelID)
                                    .font(.body.weight(.medium))
                                    .monospaced()
                                    .textSelection(.enabled)
                                Text(slotDetail(slot))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(slotState(slot.state))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(slotTint(slot.state))
                        }
                    }
                }
            }

        case let .legacy(capacity):
            VStack(alignment: .leading, spacing: 6) {
                Text("Legacy provider report")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(legacyModels(capacity), id: \.self) { model in
                    Text(model)
                        .font(.body)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }

        case .unavailable:
            Text(MyMacsPresentation.notReported)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func modelDetail(_ model: MyMacModelSnapshot) -> String {
        let parts: [String?] = [
            model.quantization,
            model.sizeBytes.map(Self.byteCount),
            model.isVision == true ? "Vision" : nil,
        ]
        let reported = parts.compactMap { $0 }
        return reported.isEmpty ? MyMacsPresentation.notReported : reported.joined(separator: " · ")
    }

    private func slotDetail(_ slot: MyMacBackendSlotSnapshot) -> String {
        let parts: [String?] = [
            slot.runningRequestCount.map { "\($0) running" },
            slot.waitingRequestCount.map { "\($0) waiting" },
            slot.observedDecodeTPS.map {
                $0.formatted(.number.precision(.fractionLength(0 ... 1))) + " tok/s reported"
            },
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func slotState(_ state: MyMacBackendSlotState) -> String {
        switch state {
        case .running: "Running"
        case .idle: "Loaded · idle"
        case .idleShutdown: "Not resident"
        case .crashed: "Crashed"
        case .reloading: "Reloading"
        case let .unknown(value): "Reported: \(value)"
        }
    }

    private func slotTint(_ state: MyMacBackendSlotState) -> Color {
        switch state {
        case .running: DarkbloomTheme.accent
        case .idle: ProductPalette.positive
        case .reloading: ProductPalette.warning
        case .crashed: ProductPalette.critical
        case .idleShutdown, .unknown: .secondary
        }
    }

    private func legacyModels(_ capacity: MyMacLegacyCapacitySnapshot) -> [String] {
        var values: [String] = []
        if let current = capacity.currentModelID {
            values.append(current)
        }
        for model in capacity.warmModelIDs where !values.contains(model) {
            values.append(model)
        }
        return values.isEmpty ? [MyMacsPresentation.notReported] : values
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
