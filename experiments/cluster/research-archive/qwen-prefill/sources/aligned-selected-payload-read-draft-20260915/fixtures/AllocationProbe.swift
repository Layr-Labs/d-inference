import Darwin
import Foundation
@main struct AllocationProbe {
 static func main() {
  for size in [16384, 32768, 49152, 8*1024*1024] {
   var ptr: UnsafeMutableRawPointer?
   let rc=posix_memalign(&ptr,16384,size)
   if let p=ptr { print("requested=\(size) return=\(rc) actual=\(malloc_size(p)) mod=\(UInt(bitPattern:p)%16384)");free(p) }
  }
 }
}
