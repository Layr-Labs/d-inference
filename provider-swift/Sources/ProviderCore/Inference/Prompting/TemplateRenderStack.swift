import Foundation

/// The stack a chat template renders on. A request renders its prompt on its caller's thread, a Swift concurrency
/// cooperative thread with a 512 KiB stack, and a template that formats a tool schema with a recursive macro
/// (Gemma 4's `format_parameters`, GPT-OSS's `render_typescript_type`) recurses in the Jinja interpreter once per
/// schema level. Measured with swift-jinja 2.3.6, the 64 levels a request may nest (`JSONNestingLimit`) need up to
/// 3 MiB of stack in a release build and up to 8 MiB in a debug build with GPT-OSS's template (Gemma 4's needs about
/// half), more than that thread has. So a render runs on a thread of its own with `bytes` of stack while the caller
/// waits: a caller's stack holds only that wait.
enum TemplateRenderStack {
    /// 16 MiB: twice what a debug build used for the deepest schema a request may carry, and five times a release
    /// build's.
    static let bytes = 16 << 20

    /// `body`'s value, or its error, from a thread with `bytes` of stack. `body` need not escape: the caller waits for
    /// the thread, which lets go of it before the caller goes on. The thread runs at its caller's quality of service,
    /// so a request's render keeps the request's priority and the prompt token cache's background comparison stays
    /// in the background. A thread inherits no task-local value; a render reads none (its filters and bindings arrive
    /// in the render context).
    static func run<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure) -> Value {
        let result: Result<Value, Failure> = withoutActuallyEscaping(body) { body in
            let job = Job(body)
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                job.run()
                done.signal()
            }
            thread.stackSize = bytes
            thread.qualityOfService = QualityOfService(rawValue: Int(qos_class_self().rawValue)) ?? .default
            thread.start()
            done.wait()
            return job.result!
        }
        return try result.get()
    }

    /// The render a thread runs, and its outcome: written once on that thread before it signals, read after.
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
