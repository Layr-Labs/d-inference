"""Strict primitive adapter for the byte-identical aligned-read validator."""
from binding_common import fields, require, same
from binding_common import integer as bounded_integer

exact = same


def integer(value):
    return bounded_integer(value, 'selected-read counter')
