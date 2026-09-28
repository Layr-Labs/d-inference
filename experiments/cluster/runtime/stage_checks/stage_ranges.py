"""Short-rank ownership geometry only; native Plan owns configuration fingerprints."""
from .common import integer, require


def option(command, cut):
    if cut is not None:
        require(command == 'ranks', '--stage-cut is supported only by short ranks')
        integer(cut, 1, 127)
    return cut


def ranges(text, cut=None):
    layers = integer(text['num_hidden_layers'], 1, 128)
    interval = integer(text['full_attention_interval'], 2, 128)
    if cut is None:
        # Preserve the historical omitted-cut admission and exact half boundary.
        require(layers % 2 == 0 and (layers // 2) % interval == 0,
                'Native half-stage split is not phase-aligned')
        cut = layers // 2
    else:
        integer(cut, 1, 127)
        require(cut < layers and cut % interval == 0
                and cut >= interval and layers - cut >= interval,
                'Two stages must cover all layers with aligned starts and at least one interval each')
    # QwenLayerStagePlan aligns stage starts, not the final model end.
    return ((0, cut), (cut, layers))


def for_context(context):
    return ranges(context['text'], option(context['mode'], context.get('stage_cut')))
