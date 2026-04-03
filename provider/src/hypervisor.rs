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
//! ## Architecture
//!
//! macOS 26 requires `hv_vm_map` mappings to be 16 MB-aligned (both
//! address and size). To satisfy this while giving Metal arbitrary-sized
//! buffers, we pre-allocate a large pool via `mmap`, VM-map it in 16 MB
//! chunks, and then carve Metal buffers from it with
//! `makeBuffer(bytesNoCopy:)`. This gives 100% coverage for all model
//! sizes and quantization formats.
//!
//! ```text
//! ┌──────────────────────────────────────────────────┐
//! │  mmap pool (e.g. 64 GB)                         │
//! │  ┌──────────┬──────────┬──────────┬───────────┐  │
//! │  │  16 MB   │  16 MB   │  16 MB   │    ...    │  │
//! │  │ chunk 0  │ chunk 1  │ chunk 2  │           │  │
//! │  │ (VM-map) │ (VM-map) │ (VM-map) │ (VM-map)  │  │
//! │  └──────────┴──────────┴──────────┴───────────┘  │
//! │  ▲                                               │
//! │  │ makeBuffer(bytesNoCopy:) → Metal buffers      │
//! │  │ for weights, activations, KV cache             │
//! └──────────────────────────────────────────────────┘
//! ```

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// macOS 26 Hypervisor.framework requires 16 MB alignment for
/// `hv_vm_map` host virtual addresses and sizes.
const CHUNK_SIZE: usize = 16 * 1024 * 1024;

/// Guest physical address base — start at 4 GB to avoid conflicts.
const GPA_BASE: u64 = 0x1_0000_0000;

// ── Hypervisor.framework FFI ────────────────────────────────

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

// ── Pool state ──────────────────────────────────────────────

/// Global hypervisor state. Only one VM per process.
static ACTIVE: AtomicBool = AtomicBool::new(false);

struct PoolState {
    /// Base address of the mmap'd pool (before alignment).
    pool_base: *mut u8,
    /// Total size of the mmap'd region.
    pool_mmap_size: usize,
    /// First 16 MB-aligned address within the pool.
    aligned_base: *mut u8,
    /// Usable size (pool minus alignment waste).
    usable_size: usize,
    /// Number of 16 MB chunks successfully VM-mapped.
    mapped_chunks: usize,
    /// Next available offset within the pool for sub-allocation.
    alloc_offset: usize,
}

// SAFETY: The pool pointer is allocated once at startup and never
// moved. Access is serialized through the Mutex.
unsafe impl Send for PoolState {}

static POOL: Mutex<Option<PoolState>> = Mutex::new(None);

// ── Public API ──────────────────────────────────────────────

/// Create a Hypervisor VM for memory isolation.
///
/// The VM has no vCPUs and no guest OS. It exists solely for its Stage 2
/// page tables. Call `allocate_pool()` after model selection to create
/// the VM-mapped memory pool sized to the model.
///
/// Safe to call multiple times (subsequent calls are no-ops).
pub fn create_vm(_pool_bytes: usize) -> Result<(), String> {
    if ACTIVE.load(Ordering::Relaxed) {
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        let result = unsafe { ffi::hv_vm_create(std::ptr::null()) };
        if result != ffi::HV_SUCCESS {
            return Err(format!(
                "hv_vm_create failed (code {result:#x}) — \
                 hypervisor entitlement may be missing"
            ));
        }
        ACTIVE.store(true, Ordering::Release);
        tracing::info!("Hypervisor VM created — call allocate_pool() to set up memory isolation");
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("Hypervisor.framework is only available on macOS".to_string())
    }
}

/// Allocate a VM-mapped memory pool sized to fit the model.
///
/// `pool_bytes` is the desired pool size (rounded up to 16 MB chunks).
/// The pool is backed by anonymous mmap and VM-mapped in 16 MB chunks.
/// All subsequent `alloc_buffer()` calls return pointers within this pool.
///
/// **Security invariant:** Once the pool is allocated, ALL inference
/// memory MUST come from the pool. If the pool is exhausted, inference
/// requests MUST be refused rather than falling back to unprotected
/// memory. This is enforced by the inference engine checking
/// `pool_has_capacity()` before each allocation.
pub fn allocate_pool(pool_bytes: usize) -> Result<(), String> {
    if !is_active() {
        return Err("hypervisor VM not active — call create_vm() first".to_string());
    }

    // Don't re-allocate if pool already exists
    if POOL.lock().unwrap().is_some() {
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        // Allocate with extra room for 16 MB alignment
        let mmap_size = pool_bytes + CHUNK_SIZE;
        let pool = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                mmap_size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_ANON | libc::MAP_PRIVATE,
                -1,
                0,
            )
        };
        if pool == libc::MAP_FAILED {
            return Err("mmap failed for hypervisor memory pool".to_string());
        }
        let pool = pool as *mut u8;

        // Find the first 16 MB-aligned address
        let pool_addr = pool as usize;
        let aligned_addr = (pool_addr + CHUNK_SIZE - 1) & !(CHUNK_SIZE - 1);
        let aligned_base = aligned_addr as *mut u8;
        let usable_size = mmap_size - (aligned_addr - pool_addr);
        let num_chunks = usable_size / CHUNK_SIZE;

        // VM-map each 16 MB chunk
        let flags = ffi::HV_MEMORY_READ | ffi::HV_MEMORY_WRITE;
        let mut gpa = GPA_BASE;
        let mut mapped_chunks = 0;

        for i in 0..num_chunks {
            let chunk_ptr = unsafe { aligned_base.add(i * CHUNK_SIZE) };
            let r = unsafe {
                ffi::hv_vm_map(
                    chunk_ptr as *const std::os::raw::c_void,
                    gpa,
                    CHUNK_SIZE,
                    flags,
                )
            };
            if r == ffi::HV_SUCCESS {
                mapped_chunks += 1;
                gpa += CHUNK_SIZE as u64;
            } else {
                tracing::warn!(
                    "hv_vm_map chunk {i} failed (err={r:#x}), \
                     mapped {mapped_chunks}/{num_chunks}"
                );
                break;
            }
        }

        let mapped_mb = mapped_chunks * CHUNK_SIZE / (1024 * 1024);
        tracing::info!(
            "Hypervisor pool: {mapped_mb} MB VM-mapped ({mapped_chunks} x 16 MB chunks)"
        );

        *POOL.lock().unwrap() = Some(PoolState {
            pool_base: pool,
            pool_mmap_size: mmap_size,
            aligned_base,
            usable_size,
            mapped_chunks,
            alloc_offset: 0,
        });

        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = pool_bytes;
        Ok(())
    }
}

/// Check whether the hypervisor VM is active in this process.
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// Allocate `size` bytes from the VM-mapped pool.
///
/// Returns a pointer that is:
/// - Within the pre-mapped pool (hardware-isolated from RDMA)
/// - 4 KB page-aligned (suitable for `makeBuffer(bytesNoCopy:)`)
/// - Valid for the lifetime of the process
///
/// This is the function that MLX's Metal buffer creation should use
/// instead of the default allocator. Create Metal buffers with:
/// ```
/// device.makeBuffer(bytesNoCopy: ptr, length: size,
///                   options: .storageModeShared, deallocator: nil)
/// ```
pub fn alloc_buffer(size: usize) -> Result<*mut u8, String> {
    if !is_active() {
        return Err("hypervisor VM not active".to_string());
    }

    let mut pool = POOL.lock().unwrap();
    let pool = pool.as_mut().ok_or("hypervisor pool not initialized")?;

    // Page-align the offset for Metal compatibility
    let aligned_offset = (pool.alloc_offset + 4095) & !4095;
    let mapped_size = pool.mapped_chunks * CHUNK_SIZE;

    if aligned_offset + size > mapped_size {
        return Err(format!(
            "hypervisor pool exhausted: need {} bytes, {} available",
            size,
            mapped_size.saturating_sub(aligned_offset)
        ));
    }

    let ptr = unsafe { pool.aligned_base.add(aligned_offset) };
    pool.alloc_offset = aligned_offset + size;
    Ok(ptr)
}

/// Check if the pool has capacity for an allocation of `size` bytes.
///
/// Used by the inference engine to enforce the fail-closed invariant:
/// if this returns false, the request MUST be refused rather than
/// letting MLX allocate from unprotected memory.
pub fn pool_has_capacity(size: usize) -> bool {
    POOL.lock()
        .ok()
        .and_then(|p| {
            p.as_ref().map(|p| {
                let aligned = (p.alloc_offset + 4095) & !4095;
                aligned + size <= p.mapped_chunks * CHUNK_SIZE
            })
        })
        .unwrap_or(false)
}

/// Total bytes allocated from the VM-mapped pool.
pub fn allocated_bytes() -> usize {
    POOL.lock()
        .ok()
        .and_then(|p| p.as_ref().map(|p| p.alloc_offset))
        .unwrap_or(0)
}

/// Total bytes available in the VM-mapped pool.
pub fn pool_capacity() -> usize {
    POOL.lock()
        .ok()
        .and_then(|p| p.as_ref().map(|p| p.mapped_chunks * CHUNK_SIZE))
        .unwrap_or(0)
}

/// Destroy the hypervisor VM and release the memory pool.
pub fn destroy_vm() {
    if !ACTIVE.load(Ordering::Relaxed) {
        return;
    }

    #[cfg(target_os = "macos")]
    {
        let pool = POOL.lock().unwrap().take();
        if let Some(pool) = pool {
            // Unmap all chunks
            let mut gpa = GPA_BASE;
            for _ in 0..pool.mapped_chunks {
                unsafe { ffi::hv_vm_unmap(gpa, CHUNK_SIZE) };
                gpa += CHUNK_SIZE as u64;
            }
            // Free the mmap'd region
            unsafe {
                libc::munmap(pool.pool_base as *mut libc::c_void, pool.pool_mmap_size);
            }
        }
        unsafe { ffi::hv_vm_destroy() };
    }

    ACTIVE.store(false, Ordering::Release);
    tracing::info!("Hypervisor VM destroyed");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_active_default() {
        assert!(!is_active());
    }

    #[test]
    fn test_alloc_without_vm() {
        let result = alloc_buffer(4096);
        assert!(result.is_err());
    }

    #[test]
    fn test_pool_capacity_without_vm() {
        assert_eq!(pool_capacity(), 0);
        assert_eq!(allocated_bytes(), 0);
    }
}
