"""Explicit registered metadata/request scope; never inferred from a candidate."""
from dataclasses import dataclass
import json
from pathlib import Path
from recorded_math import canonical, require

CATALOG = json.loads((Path(__file__).with_name('registered_profiles.json')).read_text())


@dataclass(frozen=True)
class AuditScope:
    model_id: str = 'registered_qwen35_9b'
    prompt: int = 8192
    chunk: int = 512
    output: int = 128
    cut: int = 4

    def __post_init__(self):
        require(type(self.model_id) is str and self.model_id in CATALOG, 'Unregistered comparison model')
        for value, maximum in ((self.prompt, 8192), (self.chunk, 512), (self.output, 128)):
            require(type(value) is int and 1 <= value <= maximum, 'Request geometry outside profile')
        require(self.prompt + self.output <= 8320 and type(self.cut) is int
                and str(self.cut) in self.model['plans'], 'Unpinned comparison cut/capacity')

    @property
    def model(self):
        return CATALOG[self.model_id]

    @property
    def plan(self):
        return self.model['plans'][str(self.cut)]

    @property
    def frontier(self):
        return self.prompt + self.output - 1

    @property
    def prefill_frames(self):
        return (self.prompt - 1) // self.chunk + 1

    @property
    def frames(self):
        return self.prefill_frames + self.output - 1

    @property
    def ranges(self):
        return ((0, self.cut), (self.cut, self.model['layers']))


LEGACY = AuditScope()


def scope_for(context=None):
    value = LEGACY if context is None else context.get('scope', LEGACY)
    require(type(value) is AuditScope, 'Explicit comparison scope required')
    return value


def pinned_scope(request, plan):
    require(type(request) is dict and type(plan) is dict, 'Pinned request and Plan objects required')
    scope = AuditScope(request['model'], request['promptCount'], request['chunkSize'],
                       request['outputCount'], request['stageCut'])
    require(request['stopTokenIDs'] == [] and request['mtp'] is False, 'Only length-ended target requests supported')
    expected = {'artifactSHA256': scope.model['artifact'], 'configurationSHA256': scope.model['configuration'],
                'manifestSHA256': scope.model['manifest']}
    for key, value in expected.items():
        require(canonical(request[key]) == canonical(value), 'Request registered identity differs: ' + key)
        require(canonical(plan[key]) == canonical(value), 'Plan registered identity differs: ' + key)
    for key, value in dict(modelID=scope.model_id, stageCut=scope.cut,
                           planSHA256=scope.plan['fingerprint'], stagePlanSHA256=scope.plan['stages'],
                           constructionConfigurationSHA256=scope.plan['constructions']).items():
        require(value is not None and canonical(plan[key]) == canonical(value), 'Pinned Plan differs: ' + key)
    # Both supported models retain interval4 and their exact disjoint state map.
    require(scope.model['interval'] == 4 and scope.cut % 4 == 0, 'Layer phase differs')
    return scope
