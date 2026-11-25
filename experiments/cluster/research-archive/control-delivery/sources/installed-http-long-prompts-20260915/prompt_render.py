"""Exact single-user/no-tools branch, checked against the complete pinned Jinja."""
import json
import re
import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment
import tokenizers
from tokenizers import Tokenizer

PREFIX = '<|im_start|>user\n'
SUFFIX = '<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'

class Renderer:
    def __init__(self, inputs):
        if tokenizers.__version__ != '0.22.2' or jinja2.__version__ != '3.1.6':
            raise ValueError('Use the pinned existing tokenizer/Jinja versions')
        raw = inputs['template'].decode('utf-8')
        # Actual LocalTokenizerBridge normalizes these four constructs. For this
        # pinned template the normalization is an identity and no date is read.
        normalized = re.sub(r'-#\}\s*', '#}', raw)
        normalized = re.sub(r'\s*\{#-', '{#', normalized)
        normalized = re.sub(r'\{\s+\{\{-', "{{ '{' -}}{{-", normalized)
        normalized = re.sub(r'\{\s+\{%-', "{{ '{' -}}{%-", normalized)
        if normalized != raw or 'strftime_now' in raw:
            raise ValueError('Template normalization/date assumptions differ')
        environment = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
        def refused(message):
            raise ValueError(message)
        environment.globals['raise_exception'] = refused
        self.template = environment.from_string(raw)
        self.tokenizer = Tokenizer.from_str(inputs['tokenizer'].decode('utf-8'))
        config = json.loads(inputs['config'])
        if config['bos_token'] is not None or config['eos_token'] != '<|im_end|>':
            raise ValueError('Tokenizer special-token configuration differs')
        if self.tokenizer.get_vocab_size(False) != 248044 or self.tokenizer.get_vocab_size(True) != 248077:
            raise ValueError('Tokenizer entry count differs from pinned metadata')

    def render(self, prompt):
        expected = PREFIX + prompt.strip() + SUFFIX
        actual = self.template.render(messages=[dict(role='user', content=prompt)],
                                      add_generation_prompt=True, enable_thinking=False)
        if actual != expected:
            raise ValueError('Full Jinja and source-derived single-user branch differ')
        return actual

    def encode(self, prompt):
        rendered = self.render(prompt)
        ids = self.tokenizer.encode(rendered, add_special_tokens=False).ids
        if not ids or any(type(x) is not int or not 0 <= x < 248320 for x in ids):
            raise ValueError('Native vocabulary bound exceeded')
        return rendered, ids
