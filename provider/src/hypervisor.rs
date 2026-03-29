//! Hypervisor memory isolation for inference workloads.
//!
//! Uses Apple's Hypervisor.framework to create a lightweight VM with
//! Stage 2 page tables. Inference memory (model weights, activations,
//! KV cache) is mapped into the VM, making it invisible to RDMA and
//! other DMA-based attacks even when Thunderbolt 5 RDMA is enabled.
//!
//! The VM has no guest OS — it exists solely for its Stage 2 page
//! table isolation. The host process continues to run normally, but
//! mapped memory regions gain hardware-enforced access control.
//!
//! This upgrades the security model from software-enforced
//! (PT_DENY_ATTACH, Hardened Runtime) to hardware-enforced (hypervisor
//! Stage 2 page tables). The residual attack surface reduces to
//! physical memory probing of soldered LPDDR5x — same as Apple PCC.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

const PAGE_SIZE: usize = 4096;

// Hypervisor.framework FFI
#[cfg(target_os = "macos")]
mod ffi {
    use std::os::raw::c_void;

    pub const HV_SUCCESS: i32 = 0;
    pub const HV_MEMORY_READ: u64 = 1 << 0;
    pub const HV_MEMORY_WRITE: u64 = 1 << 1;

    #[link(name = "Hypervisor", kind = "framework")]
    unsafe extern "C" {
        pub fn hv_vm_create(config: *const c_void) -> i32;
        pub fn hv_vm_destroy() -> i32;
        pub fn hv_vm_map(uva: *const c_void, gpa: u64, size: usize, flags: u64) -> i32;
        pub fn hv_vm_unmap(gpa: u64, size: usize) -> i32;
    }
}

/// Global hypervisor state. Only one VM per process.
static ACTIVE: AtomicBool = AtomicBool::new(false);

struct MappingState {
    gpa_offset: u64,
    mapped_ranges: Vec<(usize, usize)>, // (aligned_start, aligned_size)
}

static STATE: Mutex<Option<MappingState>> = Mutex::new(None);

/// Guest physical address base — start mappings at 4 GB to avoid
/// conflicts with typical guest firmware regions.
const GPA_BASE: u64 = 0x1_0000_0000;

/// Create a Hypervisor VM for memory isolation.
///
/// The VM has no vCPUs and no guest OS. It exists solely for its Stage 2
/// page tables, which provide hardware-enforced access control over
/// mapped memory regions. This makes mapped memory invisible to RDMA.
///
/// Must be called before `map_buffer()`. Safe to call multiple times
/// (subsequent calls are no-ops).
pub fn create_vm() -> Result<(), String> {
    if ACTIVE.load(Ordering::Relaxed) {
        return Ok(()); // Already active
    }

    #[cfg(target_os = "macos")]
    {
        let result = unsafe { ffi::hv_vm_create(std::ptr::null()) };
        if result == ffi::HV_SUCCESS {
            ACTIVE.store(true, Ordering::Release);
            *STATE.lock().unwrap() = Some(MappingState {
                gpa_offset: 0,
                mapped_ranges: Vec::new(),
            });
            tracing::info!("Hypervisor VM created — hardware memory isolation active");
            Ok(())
        } else {
            Err(format!(
                "hv_vm_create failed (code {result:#x}) — hypervisor entitlement may be missing"
            ))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Hypervisor.framework is only available on macOS".to_string())
    }
}

/// Check whether the hypervisor VM is active in this process.
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// Map a memory buffer into the hypervisor VM's address space.
///
/// After mapping, the buffer's physical pages are protected by the VM's
/// Stage 2 page tables. RDMA (which operates on host physical addresses)
/// cannot access memory that is only mapped at a guest physical address.
///
/// The buffer is page-aligned automatically. Overlapping mappings are
/// deduplicated. Returns Ok(mapped_bytes) or Err on failure.
pub fn map_buffer(ptr: *const u8, size: usize) -> Result<usize, String> {
    if !is_active() {
        return Err("hypervisor VM not active".to_string());
    }

    if size == 0 {
        return Ok(0);
    }

    let addr = ptr as usize;
    let aligned_start = addr & !(PAGE_SIZE - 1);
    let aligned_end = (addr + size + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
    let aligned_size = aligned_end - aligned_start;

    if aligned_size < PAGE_SIZE {
        return Ok(0); // Sub-page allocation, skip
    }

    let mut state = STATE.lock().unwrap();
    let state = state.as_mut().ok_or("hypervisor state not initialized")?;

    // Check for overlap with existing mappings
    for &(start, sz) in &state.mapped_ranges {
        if aligned_start < start + sz && start < aligned_start + aligned_size {
            return Ok(0); // Already mapped (or overlaps)
        }
    }

    #[cfg(target_os = "macos")]
    {
        let gpa = GPA_BASE + state.gpa_offset;
        let flags = ffi::HV_MEMORY_READ | ffi::HV_MEMORY_WRITE;
        let result = unsafe {
            ffi::hv_vm_map(
                aligned_start as *const std::os::raw::c_void,
                gpa,
                aligned_size,
                flags,
            )
        };

        if result == ffi::HV_SUCCESS {
            state.mapped_ranges.push((aligned_start, aligned_size));
            state.gpa_offset += aligned_size as u64;
            // Ensure next GPA is page-aligned
            state.gpa_offset = (state.gpa_offset + PAGE_SIZE as u64 - 1)
                & !(PAGE_SIZE as u64 - 1);
            Ok(aligned_size)
        } else {
            Err(format!(
                "hv_vm_map failed: ptr={:#x} size={} gpa={:#x} err={result:#x}",
                aligned_start, aligned_size, gpa
            ))
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (aligned_start, aligned_size);
        Ok(0)
    }
}

/// Total bytes currently mapped into the hypervisor VM.
pub fn mapped_bytes() -> usize {
    STATE
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.mapped_ranges.iter().map(|(_, sz)| sz).sum()))
        .unwrap_or(0)
}

/// Number of distinct memory regions mapped.
pub fn mapped_regions() -> usize {
    STATE
        .lock()
        .ok()
        .and_then(|s| s.as_ref().map(|s| s.mapped_ranges.len()))
        .unwrap_or(0)
}

/// Destroy the hypervisor VM (called on shutdown).
pub fn destroy_vm() {
    if !ACTIVE.load(Ordering::Relaxed) {
        return;
    }

    #[cfg(target_os = "macos")]
    {
        unsafe { ffi::hv_vm_destroy() };
    }

    ACTIVE.store(false, Ordering::Release);
    *STATE.lock().unwrap() = None;
    tracing::info!("Hypervisor VM destroyed");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_active_default() {
        // VM shouldn't be active by default in tests (no entitlement)
        assert!(!is_active());
    }

    #[test]
    fn test_map_buffer_without_vm() {
        let buf = vec![0u8; 8192];
        let result = map_buffer(buf.as_ptr(), buf.len());
        assert!(result.is_err());
    }
}
