"""Pinned source contracts inspected for this experimental audit version."""

PRIVATE_SOURCES = {'owned_bundle_reference.py': {'path': 'owned_bundle_reference.py',
                               'sha256': 'c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4',
                               'size_bytes': 5742},
 'prefill_compute_archive.py': {'path': 'prefill_compute_archive.py',
                                'sha256': 'dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930',
                                'size_bytes': 5727},
 'run_short_parity.py': {'path': 'run_short_parity.py',
                         'sha256': 'b8130040c9c0c026026951ad0531fde358c131e7893eed64e7c445833837295e',
                         'size_bytes': 17296},
 'short_parity_contract.py': {'path': 'short_parity_contract.py',
                              'sha256': '10f2e6c4b82b3c441e7c06ea183c249cb6f0454c93a3b623fe423f4345fecfcb',
                              'size_bytes': 17976},
 'stage_load_contract.py': {'path': 'stage_load_contract.py',
                            'sha256': '8102af85633e949d53d81de605b1e8edd65792ecb47afe75cf7c5b49473e2d83',
                            'size_bytes': 9173},
 'tiny_support.py': {'path': 'tiny_support.py',
                     'sha256': '5af27994877cfae28ed18861382681e2247920e6a78004c1e9ee7324c853e607',
                     'size_bytes': 12407}}

PRIVATE_SOURCE_PINS = {'owned_bundle_reference.py': 'c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4',
 'prefill_compute_archive.py': 'dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930',
 'run_short_parity.py': 'b8130040c9c0c026026951ad0531fde358c131e7893eed64e7c445833837295e',
 'short_parity_contract.py': '10f2e6c4b82b3c441e7c06ea183c249cb6f0454c93a3b623fe423f4345fecfcb',
 'stage_load_contract.py': '8102af85633e949d53d81de605b1e8edd65792ecb47afe75cf7c5b49473e2d83',
 'tiny_support.py': '5af27994877cfae28ed18861382681e2247920e6a78004c1e9ee7324c853e607'}

SUPPORTED_NATIVE_SOURCE_PINS = {'experiments/cluster/inference/Sources/ClusterInference/QwenDenseShortParityTypes.swift': '5ec668c69b3123f698f354fe7661f3b3f348140d833def939a4b9c31b805187a',
 'experiments/cluster/inference/Sources/ClusterInference/QwenDenseStageLoadResources.swift': 'f7edbdd6694ed800da125baa8109ecff1c512b73cb4928ff4386abffd3c7aff2',
 'experiments/cluster/inference/Sources/ClusterInference/QwenLongPrefillArithmeticEnvironment.swift': 'b6b9036557a3a937a454d0a8e1b3ba6032954a93c2ded370a97b23d6f984454f',
 'experiments/cluster/runtime/__init__.py': '2f72acef3a6816a1aaa49820651479eb926a769e8a7c71a41fcefcb3feee38e5',
 'experiments/cluster/runtime/artifacts.py': '245a6bccda22952fb549a84386737b927c306bc7a460c051920389c28e33233d',
 'experiments/cluster/runtime/bundle.py': '835648055869d5b998b702cd5a7e21bd640bd1da0e30ed718467774c43051b96',
 'experiments/cluster/runtime/configuration.py': 'b4ad86b958b42a2fe5b1bf03fa7d56ae94e15a2ed4054c776bbe78e3d3e7b424',
 'experiments/cluster/runtime/processes.py': '1f8f5d45b9cdb4f3793947996cea67027d60373fc035df7e05e7a0a355f56932',
 'experiments/cluster/runtime/rank_worker.py': '2dbb639e3e112198f9a15cfeb98b21209657651e2126f6d59d7819202d55f5e3'}

PARENT_CONTRACT_PIN = 'd0189f4a003508f2c9b0c1672f6fe5f8f298a0b938fce1afa2aa597e730ad24b'

ARITHMETIC_ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}

PROFILE_POLICY = 'qwen_dense_metal_actual_device_query128_bf16_v1'
