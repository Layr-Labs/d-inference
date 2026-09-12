"""Native byte decoding and explicitly labeled round-to-nearest-even casts."""

import numpy as np

ITEM_BYTES = {"float16": 2, "bfloat16": 2, "float32": 4}


def decode(raw, dtype, shape):
    """Promote native values to FP32; callers retain raw bytes as the bit oracle."""
    if dtype == "bfloat16":
        bits = np.frombuffer(raw, dtype="<u2").astype(np.uint32) << np.uint32(16)
        result = bits.view(np.float32)
    elif dtype == "float16":
        bits = np.frombuffer(raw, dtype="<u2").astype(np.uint32)
        sign = (bits & np.uint32(0x8000)) << np.uint32(16)
        exponent = (bits >> np.uint32(10)) & np.uint32(31)
        mantissa = bits & np.uint32(1023)
        normal = ((exponent + np.uint32(112)) << np.uint32(23)) | (mantissa << np.uint32(13))
        subnormal = (mantissa.astype(np.float32) * np.float32(2**-24)).view(np.uint32)
        special = np.uint32(0x7f800000) | (mantissa << np.uint32(13))
        promoted = np.where(exponent == 0, subnormal, np.where(exponent == 31, special, normal))
        # Bit promotion preserves signed zero and signaling/quiet NaN payloads.
        result = (sign | promoted).view(np.float32)
    else:
        result = np.frombuffer(raw, dtype="<f4").astype(np.float32)
    return result.reshape(shape)


def encode(values, dtype):
    """Explicit FP32-to-native rounding for counterfactuals and test fixtures."""
    values = np.asarray(values, dtype=np.float32)
    if dtype == "bfloat16":
        bits = values.view(np.uint32)
        # RNE at the retained mantissa's least significant bit. NaNs must not
        # round to infinity when their payload occupies only discarded bits.
        rounded = bits + np.uint32(0x7fff) + ((bits >> np.uint32(16)) & np.uint32(1))
        upper = (rounded >> np.uint32(16)).astype(np.uint16)
        nan = np.isnan(values)
        upper = np.where(nan, (bits >> np.uint32(16)).astype(np.uint16) | np.uint16(0x40), upper)
        return upper.astype("<u2").tobytes(order="C")
    with np.errstate(over="ignore", invalid="ignore"):
        return values.astype("<f2" if dtype == "float16" else "<f4").tobytes(order="C")


def rounded(values, dtype):
    return decode(encode(values, dtype), dtype, values.shape)


def packed_strides(shape):
    strides, stride = [], 1
    for size in reversed(shape):
        strides.append(stride)
        stride *= size
    return list(reversed(strides))
