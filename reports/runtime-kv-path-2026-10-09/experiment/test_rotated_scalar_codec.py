"""Meaningful numerical/serialization checks; synthetic values only for unit checks."""
import math
import unittest
from dataclasses import replace
import numpy as np
import rotated_scalar_codec as codec
from packet_reference import attention


class RotatedScalarCodecTests(unittest.TestCase):
    def test_integer_packing_edges_and_ragged_counts(self):
        for bits in (4, 8):
            for count in (0, 1, 3, 259):
                values = (np.arange(count) % (1 << bits)).astype(np.uint8)
                packed = codec.pack_codes(values, bits)
                self.assertEqual(len(packed), math.ceil(count * bits / 8))
                np.testing.assert_array_equal(codec.unpack_codes(packed, bits, count), values)
        with self.assertRaises(ValueError):
            codec.unpack_codes(b'\xf1', 4, 1)
        with self.assertRaises(ValueError):
            codec.pack_codes(np.array([16]), 4)
        with self.assertRaises(ValueError):
            codec.unpack_codes(b'', 8, 1)

    def test_full_rotation_inverse_norm_and_inner_product(self):
        rng = np.random.default_rng(713)
        for dim in (1, 3, 64, 80, 128, 192, 256, 512):
            x = rng.normal(size=(2, 3, dim)).astype(np.float32)
            y = rng.normal(size=(2, 3, dim)).astype(np.float32)
            signs = codec.rotation_signs(dim, 321)
            rx, ry = codec.rotate(x, signs), codec.rotate(y, signs)
            self.assertEqual(rx.shape[-1], codec.padded_width(dim))
            np.testing.assert_allclose(codec.inverse_rotate(rx, signs, dim), x, rtol=2e-5, atol=2e-6)
            np.testing.assert_allclose(np.sum(rx * rx, axis=-1), np.sum(x * x, axis=-1), rtol=2e-6, atol=2e-5)
            np.testing.assert_allclose(np.sum(rx * ry, axis=-1), np.sum(x * y, axis=-1), rtol=2e-5, atol=2e-5)

    def test_lloyd_codebooks_symmetry_stationarity_and_known_solution(self):
        for bits in (1, 2, 4, 8):
            book, meta = codec.gaussian_codebook(bits)
            self.assertTrue(np.all(np.diff(book) > 0))
            np.testing.assert_allclose(book, -book[::-1], atol=1e-6, rtol=1e-6)
            self.assertLess(meta['float32StationarityResidual'], 1e-6)
            self.assertEqual(meta['serializedBytes'], (1 << bits) * 4)
            self.assertEqual(codec.sha(book.tobytes()), meta['serializedSHA256'])
        one, _ = codec.gaussian_codebook(1)
        np.testing.assert_allclose(one, [-math.sqrt(2 / math.pi), math.sqrt(2 / math.pi)], rtol=1e-7)
        two, _ = codec.gaussian_codebook(2)
        np.testing.assert_allclose(two, [-1.5104176, -0.4527800, 0.4527800, 1.5104176], atol=2e-6)

    def test_exact_blocks_cover_arbitrary_dimensions_without_padding(self):
        rng = np.random.default_rng(827)
        for dim in (1, 3, 64, 80, 128, 160, 192, 256, 512):
            x = rng.normal(size=(2, 7, dim)).astype(np.float32)
            rotated, signs = codec.rotate_exact_blocks(x, 99)
            self.assertEqual(rotated.shape, x.shape)
            self.assertEqual(signs.size, min(128, dim & -dim))
            self.assertEqual(dim % signs.size, 0)
            np.testing.assert_allclose(codec.inverse_exact_blocks(rotated, signs), x, rtol=2e-5, atol=2e-6)
            np.testing.assert_allclose(np.sum(rotated * rotated, axis=-1), np.sum(x * x, axis=-1), rtol=2e-6, atol=2e-5)

    def test_serialized_decode_and_complete_padding_coordinates(self):
        rng = np.random.default_rng(719)
        for dim in (1, 3, 64, 80, 192, 256):
            x = rng.normal(size=(1, 2, 7, dim)).astype(np.float32)
            for bits in (4, 8):
                encoded = codec.encode(x, bits, 90)
                restored = codec.decode(encoded)
                self.assertEqual(restored.shape, x.shape)
                self.assertTrue(np.all(np.isfinite(restored)))
                self.assertEqual(len(encoded.codes), math.ceil(14 * codec.padded_width(dim) * bits / 8))
                # Signs, not implementation-specific PRNG recreation, drive restore.
                np.testing.assert_array_equal(codec.decode(replace(encoded, seed=12345)), restored)
                if dim >= 64:
                    rel = np.linalg.norm(restored - x) / np.linalg.norm(x)
                    self.assertLess(rel, 0.15 if bits == 4 else 0.02)
        zero = codec.decode(codec.encode(np.zeros((1, 2, 7, 80), np.float32), 4, 90))
        np.testing.assert_array_equal(zero, np.zeros_like(zero))
        with self.assertRaises(ValueError):
            codec.encode(np.array([np.nan], np.float32), 4, 90)

    def test_asymmetric_width_and_gqa_owner_reference(self):
        rng = np.random.default_rng(811)
        q = rng.normal(size=(1, 4, 1, 3)).astype(np.float32)
        k = rng.normal(size=(1, 2, 17, 3)).astype(np.float32)
        v = rng.normal(size=(1, 2, 17, 5)).astype(np.float32)
        out = attention(q, k, v, 0.5)
        self.assertEqual(out.shape, (1, 4, 1, 5))
        rk = codec.decode(codec.encode(k, 8, 71))
        rv = codec.decode(codec.encode(v, 8, 72))
        self.assertEqual(attention(q, rk, rv, 0.5).shape, out.shape)
        for head in range(4):
            owner = head // 2
            logits = k[0, owner] @ q[0, head, 0] * 0.5
            p = np.exp(logits - logits.max()); p /= p.sum()
            np.testing.assert_allclose(out[0, head, 0], p @ v[0, owner], atol=2e-7)


if __name__ == '__main__':
    unittest.main()
