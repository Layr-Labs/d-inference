import Foundation
import MLX
import Testing

@testable import ProviderCore

@Suite("GLM-5.3-Flash wired-limit advice")
struct GLM5NextWiredLimitTests {
    private static let command = "sudo sysctl -w iogpu.wired_limit_mb=245760 "
        + "vm.global_user_wire_limit=261134011596 vm.user_wire_limit=261134011596"
    /// macOS defaults on a 256 GiB Mac: Metal's working set and 88% wire limits.
    private static let defaults = GLM5NextWiredLimit.Limits(
        gpuWiredLimitMB: 0, globalUserWireLimitBytes: 241_892_558_110,
        userWireLimitBytes: 241_892_558_110, metalWorkingSetBytes: 239_143_780_352)
    private static let production = GLM5NextWiredLimit.Limits(
        gpuWiredLimitMB: 245_760, globalUserWireLimitBytes: 261_134_011_596,
        userWireLimitBytes: 261_134_011_596, metalWorkingSetBytes: 239_143_780_352)
    private static let metalOutOfMemory = MLXError.caught(
        "[METAL] Command buffer execution failed: Insufficient Memory "
            + "(00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory).")

    private var recommendation: GLM5NextWiredLimit.Recommendation {
        GLM5NextWiredLimit.recommendation(chipFamily: .m5, memoryGiB: 256)!
    }

    @Test("256 GB M5 values derive from physical memory and match the production hosts")
    func productionValues() {
        #expect(recommendation.gpuWiredLimitMB == 245_760)
        #expect(recommendation.userWireLimitBytes == 261_134_011_596)
        #expect(recommendation.sysctlCommand == Self.command)
        #expect(recommendation.plannedGPUBytes / 1_000_000_000 == 247)
    }

    @Test("other chips and memory sizes get no recommendation")
    func unvalidatedHosts() {
        #expect(GLM5NextWiredLimit.recommendation(chipFamily: .m3, memoryGiB: 256) == nil)
        #expect(GLM5NextWiredLimit.recommendation(chipFamily: .m5, memoryGiB: 512) == nil)
        #expect(GLM5NextWiredLimit.recommendation(chipFamily: .m5, memoryGiB: 128) == nil)
    }

    @Test("the macOS default limit is below the recommendation; the production values meet it")
    func threshold() {
        #expect(!recommendation.isMet(by: Self.defaults))
        #expect(recommendation.isMet(by: Self.production))

        var gpuOnly = Self.defaults
        gpuOnly.gpuWiredLimitMB = 245_760
        #expect(!recommendation.isMet(by: gpuOnly))

        var lowGPU = Self.production
        lowGPU.gpuWiredLimitMB = 230_000
        #expect(!recommendation.isMet(by: lowGPU))

        // A default limit counts as Metal's working set, whatever macOS sets it to.
        var largeDefault = Self.production
        largeDefault.gpuWiredLimitMB = 0
        largeDefault.metalWorkingSetBytes = 245_760 << 20
        #expect(recommendation.isMet(by: largeDefault))

        let unreadable = GLM5NextWiredLimit.Limits(
            gpuWiredLimitMB: nil, globalUserWireLimitBytes: nil, userWireLimitBytes: nil,
            metalWorkingSetBytes: 0)
        #expect(!recommendation.isMet(by: unreadable))
    }

    @Test("the LaunchDaemon is the production plist and installs from one pasted block")
    func launchDaemon() throws {
        let production = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>com.layrlabs.glm53-wired-limits</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \t\t<string>/usr/sbin/sysctl</string>
            \t\t<string>-w</string>
            \t\t<string>iogpu.wired_limit_mb=245760</string>
            \t\t<string>vm.global_user_wire_limit=261134011596</string>
            \t\t<string>vm.user_wire_limit=261134011596</string>
            \t</array>
            \t<key>RunAtLoad</key>
            \t<true/>
            \t<key>StandardOutPath</key>
            \t<string>/var/log/com.layrlabs.glm53-wired-limits.log</string>
            \t<key>StandardErrorPath</key>
            \t<string>/var/log/com.layrlabs.glm53-wired-limits.log</string>
            </dict>
            </plist>
            """
        #expect(recommendation.launchDaemonPlist == production)
        let parsed = try #require(PropertyListSerialization.propertyList(
            from: Data(recommendation.launchDaemonPlist.utf8), format: nil) as? [String: Any])
        #expect(parsed["Label"] as? String == "com.layrlabs.glm53-wired-limits")
        #expect(parsed["RunAtLoad"] as? Bool == true)
        #expect(parsed["ProgramArguments"] as? [String]
            == ["/usr/sbin/sysctl", "-w"] + recommendation.sysctlAssignments)

        #expect(recommendation.launchDaemonInstallCommands == [
            "sudo tee /Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist >/dev/null <<'EOF'",
            production,
            "EOF",
            "sudo launchctl bootstrap system /Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist",
        ])
    }

    @Test("Metal out-of-memory text is recognized through provider wrappers")
    func outOfMemoryClassification() {
        #expect(GLM5NextWiredLimit.isMetalOutOfMemory(Self.metalOutOfMemory))
        #expect(GLM5NextWiredLimit.isMetalOutOfMemory(InferenceError.modelLoadFailed(
            "Model 'glm-5.3-flash' loaded but its v2 engine construction failed: "
                + "\(Self.metalOutOfMemory) — unloaded")))
        #expect(GLM5NextWiredLimit.isMetalOutOfMemory(
            MultiModelBatchSchedulerEngineError.generationFailed(String(describing: Self.metalOutOfMemory))))
        #expect(GLM5NextWiredLimit.isMetalOutOfMemory("Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"))
    }

    @Test("the provider's own memory refusals are not Metal out-of-memory errors")
    func admissionRefusalsDoNotMatch() {
        for message in [
            "Insufficient memory for 'glm-5.3-flash' at final load admission",
            "Insufficient memory (12.0 GB free, need 30.0 GB) to load without evicting resident models",
            "Model 'glm-5.3-flash' loaded but has insufficient KV headroom under the memory cap",
            "token_budget_exhausted: KV capacity exhausted after requeues",
        ] {
            #expect(!GLM5NextWiredLimit.isMetalOutOfMemory(message))
            #expect(!GLM5NextWiredLimit.isMetalOutOfMemory(InferenceError.modelLoadFailed(message)))
        }
    }

    @Test("a GLM Metal out-of-memory failure below the recommendation maps to the fix notice")
    func failureNotice() {
        func notice(
            _ modelID: String, outOfMemory: Bool = true,
            recommendation: GLM5NextWiredLimit.Recommendation? = nil,
            limits: GLM5NextWiredLimit.Limits = Self.defaults
        ) -> String? {
            GLM5NextWiredLimitNotice.notice(
                modelID: modelID, isMetalOutOfMemory: outOfMemory,
                recommendation: recommendation ?? self.recommendation, limits: limits,
                cliName: "darkbloom")
        }
        let expected = "GLM-5.3-Flash at full KV needs more GPU memory than this Mac's macOS "
            + "wired-memory limits allow (Metal \"Insufficient Memory\"). Fix: \(Self.command), "
            + "then `darkbloom restart`; `darkbloom doctor` shows how to keep it after reboot."
        #expect(notice("glm-5.3-flash") == expected)
        #expect(notice(GLM5NextLocalQualification.modelID) == expected)

        #expect(notice("qwen3.5-35b-a3b") == nil)
        #expect(notice("glm-5.3-flash", outOfMemory: false) == nil)
        #expect(notice("glm-5.3-flash", limits: Self.production) == nil)
        #expect(GLM5NextWiredLimitNotice.notice(
            modelID: "glm-5.3-flash", isMetalOutOfMemory: true, recommendation: nil,
            limits: Self.defaults) == nil)
    }
}
