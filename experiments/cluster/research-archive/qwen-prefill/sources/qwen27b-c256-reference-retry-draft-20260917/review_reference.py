"""Reuse the source-reviewed independent replay with only prepared retry paths."""
import importlib.util
import sys
from retry_inputs import ROOT, INPUTS, REFERENCE, verify_prepared


if __name__ == '__main__':
    verify_prepared()
    sys.dont_write_bytecode = True
    path = ROOT/'qwen27b-c256-reference-independent-review-20260917/review.py'
    spec = importlib.util.spec_from_file_location('independent_c256_reference_review', path)
    review = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(review)
    review.INPUTS, review.REFERENCE = INPUTS, REFERENCE
    raise SystemExit(review.main())
