"""Stricter new-command swap gate; all legacy resource behavior stays intact."""
from decimal import Decimal
from .common import require
from .resources import MemoryGate as BaseMemoryGate, sample_memory


class MemoryGate(BaseMemoryGate):
    def __init__(self, sample=sample_memory):
        # The coordinator retains this owner before the first failing sample.
        self.sample, self.samples = sample, []

    def observe(self):
        value = super().observe()
        require(Decimal(value['swap_used_bytes']) == 0, 'Long profile requires zero reported swap at every observation')
        return value
