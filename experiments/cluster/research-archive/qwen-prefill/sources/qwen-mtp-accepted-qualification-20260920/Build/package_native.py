"""Copy actual successful products/resources into a fresh package after a grant."""
import argparse
import json
from pathlib import Path
import subprocess

from inputs import INPUTS, sha, verify_final, write_json

RESOURCES = [('mlx.metallib', 182425984, '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'),
             ('mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal', 24804, '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149')]


def pin(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Bundle input must be a regular file')
    return dict(bytes=path.stat().st_size, sha256=sha(path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-receipt', required=True)
    parser.add_argument('--build-receipt-sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    path = Path(args.build_receipt)
    if sha(path) != args.build_receipt_sha256:
        raise ValueError('Build receipt pin differs')
    build = json.loads(path.read_bytes())
    if build['schema'] != 'qwen_mtp_same_source_build_v1' or build['status'] != 'passed' or build['acceptedManifestSHA256'] != INPUTS['acceptedManifest']['sha256']:
        raise ValueError('Build authority differs')
    verify_final()
    products = {x['product']: x for x in build['products']}
    if set(products) != {'cluster-inference', 'darkbloom-cluster-worker'}:
        raise ValueError('Build products differ')
    pairs = [(name, Path(value['path']), dict(bytes=value['bytes'], sha256=value['sha256'])) for name, value in sorted(products.items())]
    old = Path(INPUTS['base']) / 'native-bundle'
    pairs += [(name, old / name, dict(bytes=size, sha256=digest)) for name, size, digest in RESOURCES]
    for _, source, wanted in pairs:
        if pin(source) != wanted:
            raise ValueError('Actual product/resource differs')
    output = Path(args.output)
    if not output.is_absolute() or output != output.resolve() or output.exists():
        raise ValueError('Bundle output must be fresh and canonical')
    output.mkdir(mode=0o700)
    files = []
    for name, source, wanted in pairs:
        target = output / name; target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True, timeout=30)
        if pin(source) != wanted or pin(target) != wanted:
            raise ValueError('Copied actual resource differs')
        files.append(dict(path=name, **wanted))
    result = dict(schema='qwen_mtp_accepted_native_bundle_v1', files=files,
                  buildReceiptSHA256=args.build_receipt_sha256, sourceSnapshotSHA256=build['sourceSnapshotSHA256'],
                  dependencySnapshotSHA256=build['dependencySnapshotSHA256'], acceptedManifestSHA256=build['acceptedManifestSHA256'],
                  nativeMTPQualified=False, correctnessOnly=True, servingEnabled=False, physicalExecuted=False)
    write_json(output / 'bundle.json', result)
    print(json.dumps(dict(bundleSHA256=sha(output / 'bundle.json'), files=files), sort_keys=True))


if __name__ == '__main__':
    main()
