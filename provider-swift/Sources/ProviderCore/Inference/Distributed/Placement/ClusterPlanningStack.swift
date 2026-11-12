import Foundation

/// The stack the planning runs on. A plan is asked for on its caller's thread: the onboarding's and the service's
/// planning threads (`Thread.detachNewThread`), the automatic replacement's task, `darkbloom cluster plan`'s task and a
/// test's task, each with a 512 KiB stack. A debug build's planner frames are large: on 2026-11-10,
/// `ClusterPlacementFlow.decide` used 387 KiB of a test's stack planning a tensor-parallel width, and the guided step
/// (`ClusterSetupPlanning.decide`) 692 KiB planning one; a release build's used about 120 and 220 KiB. So both
/// planning entry points run on a thread of their own with `bytes` of stack while the caller waits: a caller's stack
/// holds only that wait.
enum ClusterPlanningStack {
    /// 16 MiB, the stack the guided step's tests gave it before this type: over twenty times what a debug build used.
    static let bytes = 16 << 20

    /// `body`'s value, or its error, from a thread with `bytes` of stack. `body` need not escape: the caller waits for
    /// the thread, which lets go of it before the caller goes on. A thread inherits no task-local value, so the one the
    /// planning reads (`ClusterPublicModels.declarationOverride`, which only a test binds) is bound again there.
    static func run<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure) -> Value {
        let result: Result<Value, Failure> = withoutActuallyEscaping(body) { body in
            let job = Job(body)
            let declaration = ClusterPublicModels.declarationOverride
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                ClusterPublicModels.$declarationOverride.withValue(declaration) { job.run() }
                done.signal()
            }
            thread.stackSize = bytes
            thread.start()
            done.wait()
            return job.result!
        }
        return try result.get()
    }

    /// The planning a thread runs, and its outcome: written once on that thread before it signals, read after.
    private final class Job<Value, Failure: Error>: @unchecked Sendable {
        private var body: (() throws(Failure) -> Value)?
        private(set) var result: Result<Value, Failure>?
        init(_ body: @escaping () throws(Failure) -> Value) { self.body = body }

        /// Runs the body once and lets go of it, so the caller's closure is not held once its call returns.
        func run() {
            guard let body else { return }
            self.body = nil
            result = Result { () throws(Failure) -> Value in try body() }
        }
    }
}
