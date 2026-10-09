"""CPU numerical prototype; not a native serving implementation or full TurboQuant.

Signed full-width FWHT + norm separation + Gaussian Lloyd-Max scalar quantizer.
All padded coordinates are stored. Inverse transform precedes explicit cropping.
QJL residual correction, bias correction and paper quality claims are absent.
"""
from __future__ import annotations
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import math
import struct
import numpy as np
from scipy.special import ndtr, ndtri

VERSION = 'signed-fwht-gaussian-lloyd-max-v1'
MAX_PADDED_DIM = 4096


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def padded_width(width: int) -> int:
    if not isinstance(width, int) or width <= 0:
        raise ValueError('head width must be a positive integer')
    padded = 1 << (width - 1).bit_length()
    if padded > MAX_PADDED_DIM:
        raise ValueError('CPU prototype head width exceeds bounded experiment')
    return padded


def rotation_signs(width: int, seed: int) -> np.ndarray:
    """Serialized signs are authoritative; seed alone is not a decoder contract."""
    rng = np.random.Generator(np.random.PCG64(seed))
    return (2 * rng.integers(0, 2, padded_width(width), dtype=np.int8) - 1).astype(np.float32)


def exact_block_width(width: int) -> int:
    """Largest power-of-two divisor up to128; arbitrary widths need no padding."""
    padded_width(width)  # Keep the CPU experiment's explicit geometry bound.
    return min(128, width & -width)


def rotate_exact_blocks(values: np.ndarray, seed: int) -> tuple[np.ndarray, np.ndarray]:
    width = values.shape[-1]
    block = exact_block_width(width)
    signs = rotation_signs(block, seed)
    tiled = values.reshape(*values.shape[:-1], width // block, block)
    return rotate(tiled, signs).reshape(values.shape), signs


def inverse_exact_blocks(values: np.ndarray, signs: np.ndarray) -> np.ndarray:
    width = values.shape[-1]
    if signs.size != exact_block_width(width):
        raise ValueError('exact block inverse geometry mismatch')
    tiled = values.reshape(*values.shape[:-1], width // signs.size, signs.size)
    return inverse_rotate(tiled, signs, signs.size).reshape(values.shape)


def fwht(values: np.ndarray) -> np.ndarray:
    result = np.asarray(values, dtype=np.float32).copy()
    width = result.shape[-1]
    if width <= 0 or width & (width - 1):
        raise ValueError('FWHT needs positive power-of-two width')
    step = 1
    while step < width:
        blocks = result.reshape(*result.shape[:-1], width // (step * 2), 2, step)
        left, right = blocks[..., 0, :].copy(), blocks[..., 1, :].copy()
        blocks[..., 0, :] = left + right
        blocks[..., 1, :] = left - right
        step *= 2
    result *= np.float32(1 / math.sqrt(width))
    return result


def rotate(values: np.ndarray, signs: np.ndarray) -> np.ndarray:
    width = values.shape[-1]
    if signs.size != padded_width(width):
        raise ValueError('rotation and tensor width mismatch')
    padded = np.zeros((*values.shape[:-1], signs.size), dtype=np.float32)
    padded[..., :width] = values
    return fwht(padded * signs)


def inverse_rotate(values: np.ndarray, signs: np.ndarray, width: int) -> np.ndarray:
    if values.shape[-1] != signs.size or signs.size != padded_width(width):
        raise ValueError('inverse rotation geometry mismatch')
    # Crop only after full inverse: no padded transformed coordinate is dropped.
    return (fwht(values) * signs)[..., :width].copy()


def gaussian_centroids_step(centroids: np.ndarray) -> np.ndarray:
    edges = np.concatenate(([-np.inf], (centroids[:-1] + centroids[1:]) / 2, [np.inf]))
    left, right = edges[:-1], edges[1:]
    phi_left = np.exp(-left * left / 2) / math.sqrt(2 * math.pi)
    phi_right = np.exp(-right * right / 2) / math.sqrt(2 * math.pi)
    mass = np.where(left >= 0, ndtr(-left) - ndtr(-right), ndtr(right) - ndtr(left))
    if np.any(mass <= 0):
        raise ValueError('Gaussian cell has no representable probability')
    return (phi_left - phi_right) / mass


@lru_cache(maxsize=8)
def gaussian_codebook(bits: int) -> tuple[np.ndarray, dict]:
    if bits not in (1, 2, 4, 8):
        raise ValueError('codebook bit width outside experiment')
    count = 1 << bits
    # High-rate point-density initialization f^(1/3); no KV data used to train.
    centers = math.sqrt(3) * ndtri((np.arange(count) + 0.5) / count)
    converged = False
    for iteration in range(100000):
        updated = gaussian_centroids_step(centers)
        delta = float(np.max(np.abs(updated - centers)))
        centers = updated
        if delta < 1e-10:
            converged = True
            break
    if not converged:
        raise RuntimeError('Gaussian Lloyd-Max codebook did not converge')
    # Bind the actual serialized FP32 codebook, not an assumed runtime rebuild.
    serialized = centers.astype('<f4').tobytes()
    loaded = np.frombuffer(serialized, dtype='<f4').copy()
    metadata = {
        'target': 'standard normal N(0,1), Gaussian approximation; not exact finite-dimensional sphere density',
        'levels': count, 'lloydIterations': iteration + 1, 'float64UpdateTolerance': 1e-10,
        'float64FinalUpdateDelta': delta,
        'float32StationarityResidual': float(np.max(np.abs(gaussian_centroids_step(loaded.astype(np.float64)) - loaded))),
        'serializedDType': 'float32 little endian', 'serializedBytes': len(serialized),
        'serializedSHA256': sha(serialized), 'centroids': loaded.tolist(),
    }
    loaded.flags.writeable = False
    return loaded, metadata


def pack_codes(codes: np.ndarray, bits: int) -> bytes:
    flat = np.asarray(codes).reshape(-1)
    if bits not in (4, 8) or np.any(flat < 0) or np.any(flat >= 1 << bits):
        raise ValueError('invalid integer codes or bit width')
    flat = flat.astype(np.uint8)
    if bits == 8:
        return flat.tobytes()
    padded = np.zeros((flat.size + 1) // 2 * 2, dtype=np.uint8)
    padded[:flat.size] = flat
    return (padded[0::2] | (padded[1::2] << 4)).tobytes()


def unpack_codes(raw: bytes, bits: int, count: int) -> np.ndarray:
    if bits not in (4, 8) or count < 0 or len(raw) != (count * bits + 7) // 8:
        raise ValueError('packed length or bit width mismatch')
    encoded = np.frombuffer(raw, dtype=np.uint8)
    if bits == 8:
        return encoded.copy()
    if count % 2 and encoded.size and encoded[-1] & 0xf0:
        raise ValueError('nonzero unused high nibble')
    result = np.empty(encoded.size * 2, dtype=np.uint8)
    result[0::2], result[1::2] = encoded & 15, encoded >> 4
    return result[:count].copy()


@dataclass(frozen=True)
class RotatedPayload:
    shape: tuple[int, ...]
    bits: int
    seed: int
    padded_dim: int
    codes: bytes
    norms: bytes
    signs: bytes
    codebook: bytes

    @property
    def storage_bytes(self) -> int:
        # Fixed seed explicitly counted even though serialized signs are authoritative.
        return len(self.codes) + len(self.norms) + len(self.signs) + len(self.codebook) + 8

    def description(self) -> dict:
        return {'version': VERSION, 'bits': self.bits, 'shape': list(self.shape),
                'paddedDimension': self.padded_dim, 'seed': self.seed, 'seedBytes': 8,
                'packedCodeBytes': len(self.codes), 'normFP32Bytes': len(self.norms),
                'signMaskBytes': len(self.signs), 'codebookFP32Bytes': len(self.codebook),
                'storageBytes': self.storage_bytes, 'codeSHA256': sha(self.codes),
                'normSHA256': sha(self.norms), 'signSHA256': sha(self.signs),
                'codebookSHA256': sha(self.codebook), 'packing': 'INT4 low nibble first; INT8 byte per code',
                'zeroPaddedCoordinatesRetained': True}


def encode(values: np.ndarray, bits: int, seed: int) -> RotatedPayload:
    values = np.asarray(values, dtype=np.float32)
    if values.ndim < 1 or not np.all(np.isfinite(values)):
        raise ValueError('finite tensor values required')
    width = values.shape[-1]
    signs = rotation_signs(width, seed)
    norms = np.sqrt(np.sum(values.astype(np.float64) ** 2, axis=-1)).astype('<f4')
    if not np.all(np.isfinite(norms)):
        raise ValueError('norm exceeds FP32 storage')
    denominator = np.where(norms > 0, norms, np.float32(1))
    rotated = rotate(values / denominator[..., None], signs) * np.float32(math.sqrt(signs.size))
    book, _ = gaussian_codebook(bits)
    edges = (book[:-1] + book[1:]) / np.float32(2)
    codes = np.searchsorted(edges, rotated, side='left').astype(np.uint8)
    return RotatedPayload(tuple(values.shape), bits, seed, signs.size, pack_codes(codes, bits),
                          norms.tobytes(), np.packbits(signs > 0, bitorder='little').tobytes(), book.tobytes())


def decode(payload: RotatedPayload) -> np.ndarray:
    shape = payload.shape
    width = shape[-1]
    if payload.padded_dim != padded_width(width):
        raise ValueError('padded width mismatch')
    vectors = math.prod(shape[:-1])
    if len(payload.norms) != vectors * 4 or len(payload.codebook) != (1 << payload.bits) * 4:
        raise ValueError('norm or codebook byte size mismatch')
    if len(payload.signs) != (payload.padded_dim + 7) // 8:
        raise ValueError('sign mask byte size mismatch')
    signs = (2 * np.unpackbits(np.frombuffer(payload.signs, dtype=np.uint8), bitorder='little')
             [:payload.padded_dim].astype(np.int8) - 1).astype(np.float32)
    book = np.frombuffer(payload.codebook, dtype='<f4')
    norms = np.frombuffer(payload.norms, dtype='<f4').reshape(shape[:-1])
    if not np.all(np.isfinite(book)) or not np.all(np.diff(book) > 0) or not np.all(np.isfinite(norms)) or np.any(norms < 0):
        raise ValueError('malformed codebook or norms')
    count = vectors * payload.padded_dim
    codes = unpack_codes(payload.codes, payload.bits, count).reshape(*shape[:-1], payload.padded_dim)
    rotated = book[codes] / np.float32(math.sqrt(payload.padded_dim))
    return inverse_rotate(rotated, signs, width) * norms[..., None]
