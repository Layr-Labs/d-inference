#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation

/// Read-only identity of the actual existing native reservation. The public
/// CBv2 ID remains unchanged and the Pipe owner still creates the native UUID.
/// This exposes no new ownership, capacity, command or release authority.
public protocol DistributedResidentRequestProvenance: DistributedResidentRequestLease {
    var nativeRequestID: UUID { get }
}
#endif
