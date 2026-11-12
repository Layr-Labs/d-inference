import Foundation

/// How much of its caller's stack a planning entry point may use, the check's own call included: a quarter of the
/// 512 KiB a planning thread or a test's task runs on. In a debug build `decide`'s check used 72 KiB with the planning on
/// its own stack, against 390 KiB without (2026-11-10).
let planningCallerStackBudget = 128 * 1024

/// The stack `body` uses, on a thread of its own whose 16 MiB stack is filled with a pattern beforehand: the lowest byte
/// `body` changed gives its depth. That stack never runs out, so a planner that grows too deep fails a check instead of
/// killing the test process with a stack overflow, as a 512 KiB test task's would (SIGBUS). The caller waits for the
/// thread, so `body` may write the caller's variables.
func stackUsed(_ body: @escaping () -> Void) -> Int {
    let size = 16 << 20
    let stack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
    defer { stack.deallocate() }
    memset(stack, 0xA5, size)
    var attributes = pthread_attr_t()
    pthread_attr_init(&attributes)
    defer { pthread_attr_destroy(&attributes) }
    pthread_attr_setstack(&attributes, stack, size)
    let job = Unmanaged.passRetained(StackProbeJob(body)).toOpaque()
    var thread: pthread_t?
    let created = pthread_create(&thread, &attributes, { job in
        Unmanaged<StackProbeJob>.fromOpaque(job).takeRetainedValue().body()
        return nil
    }, job)
    precondition(created == 0, "pthread_create: \(created)")
    pthread_join(thread!, nil)
    let bytes = stack.assumingMemoryBound(to: UInt8.self)
    var untouched = 0
    while untouched < size, bytes[untouched] == 0xA5 { untouched += 1 }
    return size - untouched
}

/// `stackUsed`'s body on its way to the thread, which runs it while the caller waits.
private final class StackProbeJob: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}
