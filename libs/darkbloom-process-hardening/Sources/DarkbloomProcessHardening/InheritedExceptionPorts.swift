import Darwin

/// Mach exception handlers of this task and of the calling thread. A process
/// starts with the task-level handlers of the process that started it; one it
/// did not choose must never remain while it holds keys, prompts or answers.
public enum InheritedExceptionPorts {
    /// Every exception type a handler can be registered for: `EXC_MASK_ALL`
    /// (which Swift cannot import, and which on arm64 adds no machine-specific
    /// type) plus crash and corpse notifications, which it leaves out and
    /// which are the ones an abnormal exit raises.
    public static let everyException: exception_mask_t = [
        EXC_MASK_BAD_ACCESS, EXC_MASK_BAD_INSTRUCTION, EXC_MASK_ARITHMETIC, EXC_MASK_EMULATION,
        EXC_MASK_SOFTWARE, EXC_MASK_BREAKPOINT, EXC_MASK_SYSCALL, EXC_MASK_MACH_SYSCALL,
        EXC_MASK_RPC_ALERT, EXC_MASK_RESOURCE, EXC_MASK_GUARD, EXC_MASK_CRASH, EXC_MASK_CORPSE_NOTIFY,
    ].reduce(0) { $0 | exception_mask_t($1) }

    /// The exception types that have a live handler, as a mask.
    public struct Handlers: Equatable, Sendable {
        public let task: exception_mask_t
        public let thread: exception_mask_t

        public init(task: exception_mask_t, thread: exception_mask_t) {
            self.task = task
            self.thread = thread
        }

        public var isEmpty: Bool { task == 0 && thread == 0 }
    }

    /// The live handlers now, or nil when the kernel refuses either query.
    public static func current() -> Handlers? {
        guard let taskMask = liveHandlerMask({ masks, count, ports, behaviors, flavors in
            task_get_exception_ports(mach_task_self_, everyException, masks, count, ports, behaviors, flavors)
        }) else { return nil }
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        guard let threadMask = liveHandlerMask({ masks, count, ports, behaviors, flavors in
            thread_get_exception_ports(thread, everyException, masks, count, ports, behaviors, flavors)
        }) else { return nil }
        return Handlers(task: taskMask, thread: threadMask)
    }

    /// Removes every task-level handler and every handler of the calling
    /// thread. Exceptions then go to the system's own handlers. True when the
    /// kernel accepted both removals.
    public static func removeAll() -> Bool {
        let behavior = exception_behavior_t(EXCEPTION_DEFAULT)
        let flavor = thread_state_flavor_t(THREAD_STATE_NONE)
        let taskResult = task_set_exception_ports(mach_task_self_, everyException, mach_port_t(MACH_PORT_NULL), behavior, flavor)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let threadResult = thread_set_exception_ports(thread, everyException, mach_port_t(MACH_PORT_NULL), behavior, flavor)
        return taskResult == KERN_SUCCESS && threadResult == KERN_SUCCESS
    }

    private typealias Query = (
        exception_mask_array_t, UnsafeMutablePointer<mach_msg_type_number_t>, exception_handler_array_t,
        exception_behavior_array_t, exception_flavor_array_t
    ) -> kern_return_t

    /// Runs one handler query and releases every send right it returned.
    private static func liveHandlerMask(_ query: Query) -> exception_mask_t? {
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        let result = query(&masks, &count, &ports, &behaviors, &flavors)
        guard result == KERN_SUCCESS else { return nil }
        var live: exception_mask_t = 0
        for index in 0 ..< min(Int(count), capacity) {
            let port = ports[index]
            guard port != mach_port_t(MACH_PORT_NULL) else { continue }
            // `MACH_PORT_DEAD`: the receiver is gone, nothing can be delivered.
            if port != mach_port_t.max { live |= masks[index] }
            mach_port_deallocate(mach_task_self_, port)
        }
        return live
    }
}
