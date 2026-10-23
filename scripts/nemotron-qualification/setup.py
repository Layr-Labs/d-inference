#!/usr/bin/env python3
"""Create isolated fixture harnesses; never resolve packages, build or run MLX."""
import argparse
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent


def setup(checkout, sdk, mlx, output):
    checkout, sdk, mlx = (Path(p).resolve(strict=True) for p in (checkout, sdk, mlx))
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("output must be a NEW directory")
    output = output.resolve()
    for source in (checkout, sdk, mlx):
        if output == source or source in output.parents:
            raise ValueError("output must be outside source checkouts")
    required = [checkout / "provider-swift/Sources", checkout / "provider-swift/Tests",
                sdk / "Package.swift", mlx / "Package.swift"]
    wrapper_dirs = ["Libraries", "Executables", "Tests", "Sources", "benchmarks", "Plugins"]
    required += [sdk / name for name in wrapper_dirs]
    for path in required:
        if not path.exists():
            raise ValueError(f"missing source: {path}")
    # All checks precede creation. Never overwrite or alter source manifests.
    output.mkdir(mode=0o700)
    sdk_harness = output / "sdk"
    provider = output / "provider"
    sdk_harness.mkdir(); provider.mkdir()
    for name, source in [("source-d-inference", checkout), ("source-mlx-swift-lm", sdk),
                         ("source-mlx-swift", mlx)]:
        (sdk_harness / name).symlink_to(source, target_is_directory=True)
    shutil.copyfile(HERE / "templates/SDK.Package.swift", sdk_harness / "Package.swift")
    shutil.copyfile(HERE / "templates/Provider.Package.swift", provider / "Package.swift")
    for name, directory in (("SDK", sdk_harness), ("Provider", provider)):
        shutil.copyfile(HERE / f"templates/{name}.Package.resolved", directory / "Package.resolved")
    for name in ("Sources", "Tests"):
        (provider / name).symlink_to(checkout / "provider-swift" / name, target_is_directory=True)
    packages = provider / "packages"
    packages.mkdir()
    (packages / "mlx-swift").symlink_to(mlx, target_is_directory=True)
    wrapper = packages / "mlx-swift-lm"
    wrapper.mkdir()
    shutil.copyfile(HERE / "templates/SDKWrapper.Package.swift", wrapper / "Package.swift")
    for name in wrapper_dirs:
        (wrapper / name).symlink_to(sdk / name, target_is_directory=True)
    return {"sdk_harness": str(sdk_harness), "provider_harness": str(provider),
            "built": False, "downloaded": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, default=HERE.parents[1])
    parser.add_argument("--sdk", type=Path, help="default: CHECKOUT/libs/mlx-swift-lm")
    parser.add_argument("--mlx", type=Path, help="default: CHECKOUT/libs/mlx-swift")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(setup(args.checkout, args.sdk or args.checkout / "libs/mlx-swift-lm",
                           args.mlx or args.checkout / "libs/mlx-swift", args.output), indent=2))


if __name__ == "__main__":
    main()
