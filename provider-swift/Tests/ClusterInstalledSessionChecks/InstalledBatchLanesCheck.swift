import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterBootstrap
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote
@testable import InstalledContract

extension InstalledSessionCheck {
    /// The actual child boundary that previously dropped the operator's lane
    /// count while provider admission still used it. No inherited environment
    /// is passed to this process, and no native worker or model is started.
    static func installedBatchLanePropagation(_ f: InstalledFixture) throws {
        let probe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("InstalledOwnerEnvironmentProbe")
        let ownerFixture = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-owner"),
            probe: f.probe, owner: probe, worker: f.worker)
        let prepared = try ownerFixture.prepare()
        let key = DistributedInstalledPlan.batchLanesSwitch
        let fixed = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        func observed(_ configuration: ClusterLocalOwnerConfiguration) throws -> [String: String] {
            let launch = try configuration.launch()
            let child = Process(), output = Pipe()
            child.executableURL = launch.executable; child.arguments = launch.arguments
            child.environment = launch.environment; child.standardOutput = output
            try child.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            try require(child.terminationStatus == 0, "owner environment probe failed")
            var environment = try JSONDecoder().decode([String: String].self, from: bytes)
            // Foundation initializes this derived user/encoding value inside
            // the child even when exec receives only the fixed dictionary.
            environment.removeValue(forKey: "__CF_USER_TEXT_ENCODING")
            try require(environment == launch.environment, "child environment differs from the fixed launch")
            return environment
        }
        try require(try observed(.init(installedDarkbloom: probe)) == fixed,
            "nil lanes changed the fixed local owner environment")
        for invalid in [Int.min, -1, 0, 9, Int.max] {
            try rejected { _ = try ClusterLocalOwnerConfiguration(installedDarkbloom: probe, batchLanes: invalid) }
        }
        for lanes in [1, 2, 4, 8] {
            let caller = [key: String(lanes), "DYLD_INSERT_LIBRARIES": "must-not-forward", "UNRELATED": "must-not-forward"]
            let plan = prepared.plan
            let config = try plan.localOwnerConfiguration(ownerEnvironment: caller)
            let child = try observed(config)
            var expected = fixed; expected[key] = String(lanes)
            try require(child == expected, "local owner failed exact typed lane forwarding or inherited unrelated values")
            try require(plan.batchLanes(caller) == lanes && plan.batchLanes(child) == lanes,
                "provider admission and owner lease disagree")
            let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
            try require(Int(native[key] ?? "1") == lanes, "owner lease and native worker disagree")
            try require(plan.lanesRetireAlone(caller) == plan.lanesRetireAlone(child),
                "provider and owner cancellation policy disagree")
        }
        func malformedOverrideKeepsOneLane(_ plan: DistributedInstalledPlan, matrix: URL) throws {
            for invalid in ["0", "9", "unbounded", "999999999999999999999999"] {
                let caller = [key: invalid]
                let child = try observed(plan.localOwnerConfiguration(ownerEnvironment: caller))
                let native = plan.nativeEnvironment(matrix: matrix, ownerEnvironment: child)
                try require(child[key] == "1" && plan.batchLanes(caller) == 1 && plan.batchLanes(child) == 1
                    && Int(native[key] ?? "1") == 1, "malformed override restored a wider child default")
                try require(!plan.lanesRetireAlone(caller) && !plan.lanesRetireAlone(child),
                    "malformed override enabled lane retirement")
            }
        }
        try malformedOverrideKeepsOneLane(prepared.plan, matrix: prepared.matrixURL)
        for lanes in [2, 4, 8] {
            let saved = try InstalledFixture.make(root: f.root.appendingPathComponent("planned-lanes-\(lanes)"),
                probe: f.probe, owner: probe, worker: f.worker, batchLanes: lanes)
            let prepared = try saved.prepare(), plan = prepared.plan
            let child = try observed(plan.localOwnerConfiguration(ownerEnvironment: [:]))
            let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
            try require(plan.batchLanes([:]) == lanes && child[key] == String(lanes)
                && plan.batchLanes(child) == lanes && Int(native[key] ?? "1") == lanes,
                "Planned width was lost between provider, actual sanitized child, owner and native worker")
            try require(plan.lanesRetireAlone([:]) && plan.lanesRetireAlone(child), "Planned width lost cancellation isolation")
            try require(plan.batchLanes([key: "1"]) == 1, "Explicit diagnostic single lane was ignored")
            try malformedOverrideKeepsOneLane(plan, matrix: prepared.matrixURL)
        }
        // Exact Qwen27 TP propagates the saved/explicit width through a real
        // sanitized owner child. Its native budget is independently quoted.
        for lanes in [1, 2, 4, 8] {
            let fixture = try InstalledFixture.make(root: f.root.appendingPathComponent("qwen27-tp-lanes-\(lanes)"),
                probe: f.probe, owner: probe, worker: f.worker,
                generationMode: ClusterGenerationMode.tensorParallel.rawValue, advertisedModes: [.pipeline, .tensorParallel],
                registered: ("registered_qwen38_27b", "registered_qwen38_27b_greedy_generation_v1", "fixture/qwen27"),
                batchLanes: lanes == 1 ? nil : lanes)
            let prepared = try fixture.prepare(), plan = prepared.plan
            let child = try observed(plan.localOwnerConfiguration(ownerEnvironment: [:]))
            let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
            try require(plan.batchLanes([:]) == lanes && child[key] == String(lanes) && Int(native[key] ?? "1") == lanes,
                "Qwen27 TP planned width was lost across the actual owner child")
            try require(plan.lanesRetireAlone([:]) == (lanes > 1) && plan.lanesRetireAlone(child) == (lanes > 1),
                "Qwen27 TP cancellation isolation differs from its native width")
            let profile = try DistributedResidentExecutionProfile(capability: plan.capability, generationMode: .tensorParallel,
                requestTimeout: .seconds(10))
            try require(profile.supportsLogprobs, "Qwen27 TP width lost actual native raw-logprob capture")
            // Both local service roles use this exact launcher. Only the typed
            // local binary setting survives both child environment boundaries.
            let sync = DistributedInstalledPlan.fastSynchronizationSwitch
            let baseline = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
            try require(child[sync] == nil && baseline[sync] == nil, "Absent sync choice changed the worker default")
            for choice in ["0", "1", "", "true", "false", "2", "-1", "00", "01", " 0", "0\n", "$(false)"] {
                let caller = [sync: choice, "DYLD_INSERT_LIBRARIES": "must-not-forward",
                    "MLX_METAL_FUSED_FENCE_UPDATE": "1", "UNRELATED": "must-not-forward"]
                let expected = ["0", "1"].contains(choice) ? choice : nil
                let observedChild = try observed(plan.localOwnerConfiguration(ownerEnvironment: caller))
                var expectedChild = child
                if let expected { expectedChild[sync] = expected }
                try require(observedChild == expectedChild, "Sync choice widened or escaped the fixed owner environment")
                var expectedNative = baseline
                if let expected { expectedNative[sync] = expected }
                let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: observedChild)
                try require(native == expectedNative, "Sync choice changed unrelated native guards or did not reach the worker")
                // Exercise the final native launch constructor, not just its environment helper.
                let binding = try plan.binding(epoch: UUID(), lease: UUID(), incarnation: UUID())
                let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000_000
                let starts = try DistributedInstalledNativeStart.starts(plan: plan, epoch: binding.identity.membershipEpoch)
                let attachment = try ClusterOwnerBootstrapAttachment(profile: .nativeKeyPreludeMesh2, deadline: deadline,
                    nativeStart: starts[plan.configuration.localRank])
                defer { attachment.cancel() }
                let trust = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch: binding.identity.membershipEpoch)[plan.configuration.localRank]
                let launch = try DistributedInstalledOwner.nativeLaunch(prepared: prepared, binding: binding, deadline: deadline,
                    startupDeadline: nil, attachment: attachment, dataPlaneTrust: trust, prefixSSDKey: nil,
                    ownerEnvironment: observedChild)
                try require(launch.environment == expectedNative, "Final native launch dropped the typed sync choice")
            }
            try malformedOverrideKeepsOneLane(plan, matrix: prepared.matrixURL)
        }
        for model in ["registered_qwen35_9b", "registered_qwen35_35b_a3b", "unknown"] {
            try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .qwen35Dense, mode: .tensorParallel,
                hasPrivateImages: false, runtimeModelID: model) == nil, "Other model inherited Qwen27 TP lanes")
        }
        try rejected {
            _ = try InstalledFixture.make(root: f.root.appendingPathComponent("qwen9-unpriced-tp-width"),
                probe: f.probe, owner: probe, worker: f.worker, generationMode: ClusterGenerationMode.tensorParallel.rawValue,
                advertisedModes: [.pipeline, .tensorParallel], batchLanes: 2)
        }
        // A default greater than one exposes the nil/absent mismatch which
        // the current Qwen singleton default would otherwise hide.
        let glm = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-glm-default"),
            probe: f.probe, owner: probe, worker: f.worker,
            generationMode: ClusterGenerationMode.tensorParallel.rawValue,
            advertisedModes: [.pipeline, .tensorParallel],
            registered: (ClusterGLMImageCandidate.runtimeModelID, ClusterGLMImageCandidate.textProfileID, "fixture/glm-text"),
            adapter: .glm5NextLayerStage)
        let glmPrepared = try glm.prepare()
        try require(glmPrepared.plan.batchLanes([:]) == 8, "GLM tensor-parallel default changed")
        try require(try observed(glmPrepared.plan.localOwnerConfiguration(ownerEnvironment: [:]))[key] == "8",
            "GLM default did not reach its owner")
        try malformedOverrideKeepsOneLane(glmPrepared.plan, matrix: glmPrepared.matrixURL)
        let gpt = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-gptoss"),
            probe: f.probe, owner: probe, worker: f.worker,
            registered: ("registered_gpt_oss_20b", "registered_gpt_oss_20b_greedy_generation_v1", "fixture/gptoss"),
            adapter: .gptossLayerStage)
        let gptPrepared = try gpt.prepare()
        try require(gptPrepared.plan.batchLanes([:]) == 1, "GPT-OSS default enabled unqualified concurrency")
        for lanes in [1, 2, 4, 8] {
            let caller = [key: String(lanes)]
            let child = try observed(gptPrepared.plan.localOwnerConfiguration(ownerEnvironment: caller))
            let native = gptPrepared.plan.nativeEnvironment(matrix: gptPrepared.matrixURL, ownerEnvironment: child)
            try require(gptPrepared.plan.batchLanes(caller) == lanes && gptPrepared.plan.batchLanes(child) == lanes
                && Int(native[key] ?? "1") == lanes, "GPT-OSS provider/actual child/native lane widths differ")
            try require(gptPrepared.plan.lanesRetireAlone(caller) == (lanes > 1), "GPT-OSS cancel isolation width differs")
            try require(native[DistributedInstalledPlan.kvBackendSwitch] != "contiguous", "GPT-OSS pages were disabled by batching")
        }
        try malformedOverrideKeepsOneLane(gptPrepared.plan, matrix: gptPrepared.matrixURL)
        let gemma = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-gemma-paged"),
            probe: f.probe, owner: probe, worker: f.worker,
            registered: ("registered_gemma4_26b_qat_4bit", "registered_gemma4_26b_qat_4bit_greedy_generation_v1", "fixture/gemma"),
            adapter: .gemma4LayerStage)
        let gemmaPrepared = try gemma.prepare()
        for lanes in [1, 2, 4, 8] {
            let child = try observed(gemmaPrepared.plan.localOwnerConfiguration(ownerEnvironment: [key: String(lanes)]))
            let native = gemmaPrepared.plan.nativeEnvironment(matrix: gemmaPrepared.matrixURL, ownerEnvironment: child)
            try require(Int(native[key] ?? "1") == lanes, "Gemma native lane width differs from its actual owner")
            try require(native[DistributedInstalledPlan.kvBackendSwitch] == nil, "Gemma batching changed the paged default")
        }
        let sync = DistributedInstalledPlan.fastSynchronizationSwitch
        for choice in ["0", "1"] {
            let caller = [sync: choice]
            let owner = try observed(gemmaPrepared.plan.localOwnerConfiguration(ownerEnvironment: caller))
            let native = gemmaPrepared.plan.nativeEnvironment(matrix: gemmaPrepared.matrixURL, ownerEnvironment: caller)
            try require(owner[sync] == nil && native[sync] == nil, "Pipeline gained a TP synchronization override")
        }
        let diagnostic = gemmaPrepared.plan.nativeEnvironment(matrix: gemmaPrepared.matrixURL,
            ownerEnvironment: [key: "8", DistributedInstalledPlan.kvBackendSwitch: "contiguous"])
        try require(diagnostic[DistributedInstalledPlan.kvBackendSwitch] == "contiguous", "Explicit local KV diagnostic was lost")
        for mode in ClusterGenerationMode.allCases where mode != .pipeline {
            try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .gptossLayerStage, mode: mode,
                hasPrivateImages: false) == nil, "GPT-OSS batch mode widened")
            try require(!DistributedInstalledPlan.lanesRetireAlone(adapter: .gptossLayerStage, mode: mode,
                hasPrivateImages: false, lanes: 8), "GPT-OSS cancellation policy widened")
        }
        try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .gptossLayerStage, mode: .pipeline,
            hasPrivateImages: true) == nil, "GPT-OSS images gained lanes")
        // Actual unsupported-mode plans preserve nil despite the override.
        for mode in [ClusterGenerationMode.pipelineCompactDecode, .phaseSplit, .pipelineMTP] {
            let fixture = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-" + mode.rawValue),
                probe: f.probe, owner: probe, worker: f.worker, generationMode: mode.rawValue,
                advertisedModes: [.pipeline, mode])
            let plan = try fixture.prepare().plan
            try require(plan.batchLanes([key: "8"]) == nil, "unsupported mode accepted lanes")
            try require(try observed(plan.localOwnerConfiguration(ownerEnvironment: [key: "8"])) == fixed,
                "unsupported mode forwarded lanes")
        }
        try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .qwen35Dense, mode: .pipeline,
            hasPrivateImages: true) == nil, "pipeline images gained batch lanes")
        try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .mimoV26ImageCandidate, mode: .pipeline,
            hasPrivateImages: true) == nil, "MiMo image adapter gained batch lanes")
        // Lightning uses the same real owner launcher and per-request memory
        // gates as Qwen; only explicit plain-pipeline widths are added here.
        for mode in [ClusterGenerationMode.pipeline, .pipelineMTP, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP] {
            let lightning = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-lightning-" + mode.rawValue),
                probe: f.probe, owner: probe, worker: f.worker, generationMode: mode.rawValue,
                advertisedModes: ClusterGenerationMode.allCases.filter { [.pipeline, .pipelineMTP, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP].contains($0) },
                registered: ("registered_nemotron35_lightning", "registered_nemotron35_lightning_greedy_generation_v1", "fixture/nemotron-lightning"),
                adapter: .nemotronH)
            let prepared = try lightning.prepare(), plan = prepared.plan
            try require(plan.batchLanes([:]) == (mode == .pipeline ? 1 : nil), "Lightning default or mode gate changed")
            for lanes in [1, 2, 4, 8] {
                let caller = [key: String(lanes)]
                let child = try observed(plan.localOwnerConfiguration(ownerEnvironment: caller))
                let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
                if mode == .pipeline {
                    try require(child[key] == String(lanes) && plan.batchLanes(caller) == lanes
                        && plan.batchLanes(child) == lanes && Int(native[key] ?? "1") == lanes,
                        "Lightning provider/owner/native lane widths disagree")
                    try require(plan.lanesRetireAlone(child) == (lanes > 1), "Lightning cancellation width differs")
                } else {
                    try require(plan.batchLanes(caller) == nil && child == fixed && native[key] == nil,
                        "Lightning speculative/compact/phase mode gained lanes")
                }
            }
            if mode == .pipeline { try malformedOverrideKeepsOneLane(plan, matrix: prepared.matrixURL) }
        }
        // MiMo uses the same real owner launcher and per-request memory
        // gates as Qwen; only explicit plain-pipeline widths are added here.
        for mode in [ClusterGenerationMode.pipeline, .pipelineMTP, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP] {
            let mimo = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-mimo-" + mode.rawValue),
                probe: f.probe, owner: probe, worker: f.worker, generationMode: mode.rawValue,
                advertisedModes: ClusterGenerationMode.allCases.filter { [.pipeline, .pipelineMTP, .pipelineCompactDecode, .phaseSplit, .phaseSplitMTP].contains($0) },
                registered: ("registered_mimo_v26_flash_mopd", "registered_mimo_v26_flash_mopd_greedy_generation_v1", "fixture/mimo"),
                adapter: .mimoV26LayerStage)
            let prepared = try mimo.prepare(), plan = prepared.plan
            try require(plan.batchLanes([:]) == (mode == .pipeline ? 1 : nil), "MiMo default or mode gate changed")
            for lanes in [1, 2, 4, 8] {
                let caller = [key: String(lanes)]
                let child = try observed(plan.localOwnerConfiguration(ownerEnvironment: caller))
                let native = plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: child)
                if mode == .pipeline {
                    try require(child[key] == String(lanes) && plan.batchLanes(caller) == lanes
                        && plan.batchLanes(child) == lanes && Int(native[key] ?? "1") == lanes,
                        "MiMo provider/owner/native lane widths disagree")
                    try require(plan.lanesRetireAlone(child) == (lanes > 1), "MiMo cancellation width differs")
                } else {
                    try require(plan.batchLanes(caller) == nil && child == fixed && native[key] == nil,
                        "MiMo speculative/compact/phase mode gained lanes")
                }
            }
            if mode == .pipeline { try malformedOverrideKeepsOneLane(plan, matrix: prepared.matrixURL) }
        }
        try require(DistributedInstalledPlan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel,
            hasPrivateImages: false) == 8, "GLM tensor-parallel default changed")

        // The coordinator-member installation also carries the locally resolved
        // scalar; both rank constructors use the same actual owner launcher.
        let paired = try InstalledFixture.make(root: f.root.appendingPathComponent("lane-member"),
            probe: f.probe, owner: f.owner, worker: f.worker, pairing: true)
        let plan = try paired.prepare().plan
        let attachment = try require(plan.configuration.nativeMember, "member fixture has no approval")
        for rank in [0, 1] {
            let installation = try NativePairMemberInstallation(expectedCoordinatorPolicy: attachment.policyBytes,
                rank: rank, clusterID: plan.configuration.clusterID, identity: plan.identity(epoch: UUID()),
                profile: plan.capability.profile, installedOwner: probe,
                ownerSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: probe)),
                nativeExecutable: f.probe, metallib: URL(fileURLWithPath: attachment.metallibPath),
                resourceLibrary: URL(fileURLWithPath: attachment.resourceLibraryPath), chip: "Apple M4",
                leaseDirectory: paired.paths.deviceDirectory, batchLanes: plan.batchLanes([key: "2"]))
            try require(try observed(installation.localOwner)[key] == "2", "member rank lost its local lane count")
        }
        print("Installed batch lanes: actual child propagation, admission/lease/native parity, bounds, gates and both member ranks passed")
    }
}
