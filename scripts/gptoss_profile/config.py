"""Explicit workload and process-environment contract."""

from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class Cell:
    phase: str
    context: int
    batch: int = 1

    @property
    def name(self):
        return f"{self.phase}-{self.context}" + (f"-b{self.batch}" if self.phase == "decode" else "")

    def record(self):
        return {"name": self.name, **asdict(self)}


def cells(phase="all", selected=None):
    matrix = [Cell("prefill", n) for n in (512, 4096, 8192, 16384, 32768)]
    matrix += [Cell("decode", n, b) for n in (512, 8192, 32768) for b in (1, 2, 4, 8)]
    matrix += [Cell("arrival", 512), Cell("arrival", 8192), Cell("arrival", 32768)]
    matrix = [c for c in matrix if phase == "all" or c.phase == phase]
    if selected:
        requested = set(selected.split(","))
        unknown = requested - {c.name for c in matrix}
        if unknown:
            raise ValueError(f"Unknown cells for phase {phase}: {sorted(unknown)}")
        matrix = [c for c in matrix if c.name in requested]
    return matrix


def command(binary: Path, model: str, config: Path | None, cell: Cell,
            iterations: int, decode_tokens: int, backend: str):
    result = [str(binary), "benchmark", "--model", model, "--kv-backend", backend]
    if config:
        result += ["--config", str(config)]
    if cell.phase == "prefill":
        result += ["--scheduler-prefill", "--prefill-lengths", str(cell.context),
                   "--prefill-iterations", str(iterations)]
    elif cell.phase == "decode":
        result += ["--sweep", "--prefill-lengths", "128", "--batch-sizes", str(cell.batch),
                   "--decode-prompt-tokens", str(cell.context), "--decode-tokens", str(decode_tokens),
                   "--decode-iterations", str(iterations)]
    else:
        result += ["--arrival-invariance", "--arrival-prompt-lengths", f"{cell.context},512,512,512",
                   "--arrival-decode-tokens", str(decode_tokens), "--arrival-iterations", str(iterations)]
    return result


# Clear inherited experimental knobs rather than silently timing somebody's
# interactive shell configuration. Never capture the complete environment.
CONTROL_PREFIXES = ("DARKBLOOM_", "MLX_", "DYLD_", "MTL_", "METAL_")
FIXED_CONTROLS = {"DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_CBV2_MTP": "0"}


def environment(inherited, overrides=()):
    result = {k: v for k, v in inherited.items() if not k.startswith(CONTROL_PREFIXES)}
    explicit = {}
    for override in overrides:
        key, separator, value = override.partition("=")
        if not separator or not key.startswith(CONTROL_PREFIXES):
            raise ValueError("--env requires a DARKBLOOM_/MLX_/DYLD_/MTL_/METAL_ KEY=VALUE")
        if key in FIXED_CONTROLS and value != "0":
            raise ValueError("Prefix reuse and speculation must remain disabled")
        explicit[key] = value
    result.update(explicit)
    result.update(FIXED_CONTROLS)
    return result, {k: result[k] for k in sorted(set(explicit) | set(FIXED_CONTROLS))}
