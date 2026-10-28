import DarkbloomClusterProtocol
import Foundation

/// How many NextN proposals each GLM tensor-parallel decode round verifies,
/// and whether a target window may have one row.
///
/// A round of `w` proposals verifies a `[1, w + 1]` window. Every target row's
/// bits must not depend on that width, or a request's tokens would depend on
/// the rounds other requests make. Measured on the pair (real model, c48):
/// windows of two and three rows (depths 1 and 2) give every row the same
/// bits, at any column; one row (MLX's one-row `qmv` and the one-token dense
/// and KDA kernels) and four rows (depth 3) do not. So the policies here
/// choose between depths 1 and 2 only, and never verify a window of one row:
/// a round of no proposal (its request's last token, at its output limit)
/// verifies its token beside a padding row (the NextN layer's step-0
/// proposal, which that round computes anyway), keeps only its token and
/// drops the padding row's cache rows, as a rejected proposal's. A window
/// that straddles the dense-to-sparse DSA switch (2,048 tokens of history)
/// projects both parts' attention rows in one product, so a part of one row
/// does not take the one-row product either.
///
/// - `fixed` (the default): every round verifies up to `depth` proposals, as
///   before; with `widthInvariant` off this is the product's decode
///   bit for bit.
/// - `load`: up to `depth` proposals while fewer than `loadLanes` lanes decode
///   in a step, one from then on; implies `widthInvariant`. A request
///   then gets the same tokens and logits at any concurrency, while a busy
///   pair verifies fewer rows per accepted token.
///
/// Windows follow agreed state only (the lanes in the agreed plan, a
/// request's agreed tokens), so both ranks verify the same rows. Both ranks
/// bind the policy into their load agreement (`loadAgreementFields`; none for
/// the default, so a default load's agreement is unchanged).
struct GLM5NextTensorParallelDecodePolicy: Equatable, Sendable {
    enum Depth: String, Sendable { case fixed, load }

    var depth = Depth.fixed
    /// `load`: lanes decoding in one step from which each round verifies one proposal.
    var loadLanes = 3
    /// One arithmetic for every target row (`ClusterGLMTensorParallel.widthInvariantSwitch`,
    /// implied by `load`): no window of one row (`GLM5NextTensorParallelSpeculation
    /// .padsSingleRowWindows`), and a window straddling the dense-to-sparse
    /// DSA switch projects its attention rows in one product
    /// (`GLM5NextTextStage.widthInvariantWindows`).
    var widthInvariant = false

    static let fixed = Self()

    /// The lane count matters to `load` only; other policies keep the default.
    init(depth: Depth = .fixed, loadLanes: Int = 3, widthInvariant: Bool = false) {
        self.depth = depth; self.loadLanes = depth == .load ? loadLanes : 3
        self.widthInvariant = widthInvariant || depth == .load
    }

    /// From the worker's environment (`ClusterGLMTensorParallel.decodeSwitches`);
    /// a value outside a switch's set is refused.
    init(environment: [String: String]) throws {
        typealias Switches = ClusterGLMTensorParallel
        for (name, values) in Switches.decodeSwitches {
            if let value = environment[name], !values.contains(value) {
                throw ProbeError("\(name) takes " + values.sorted().joined(separator: ", "))
            }
        }
        self.init(depth: environment[Switches.depthPolicySwitch].flatMap(Depth.init(rawValue:)) ?? .fixed,
            loadLanes: environment[Switches.loadLanesSwitch].flatMap(Int.init) ?? 3,
            widthInvariant: environment[Switches.widthInvariantSwitch] == "1")
    }

    /// The process's own policy, read once (`GLM5NextTensorParallelResidentRuntime.load`
    /// refuses a malformed one before anything is loaded).
    static let environment = Result { try Self(environment: ProcessInfo.processInfo.environment) }
    static var current: Self { (try? environment.get()) ?? .fixed }

    /// The load agreement's fields; none for the default.
    var loadAgreementFields: [String] {
        self == .fixed ? [] : ["glm5-next-tp-decode-policy-v1", depth.rawValue,
            "load-lanes=\(loadLanes)", widthInvariant ? "padded" : "unpadded"]
    }

    /// Proposals a round may verify when `lanes` lanes decode in the step,
    /// of at most `maximum` (the speculation's depth).
    func depth(maximum: Int, lanes: Int) -> Int {
        depth == .load && lanes >= loadLanes ? min(maximum, 1) : maximum
    }

    /// The proposals a request's round verifies when `lanes` lanes decode in
    /// the step and `outputLeft` (at least 1) of its tokens are still to come.
    func window(maximum: Int, lanes: Int, outputLeft: Int) -> Int {
        max(0, min(depth(maximum: maximum, lanes: lanes), outputLeft - 1))
    }
}
