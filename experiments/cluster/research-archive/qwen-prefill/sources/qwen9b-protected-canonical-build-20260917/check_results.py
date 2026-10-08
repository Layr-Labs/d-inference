"""Require every selected actual test result, including the retained controls."""
import json
import re


def require_tests(raw, expected):
    text = raw.decode('utf-8', errors='strict')
    actual = re.findall(r"Test Case '-\[[^.\s]+\.([A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]' passed \(", text)
    names = [suite + '.' + method for suite, method in actual]
    if sorted(names) != sorted(expected['xctest']):
        raise ValueError('Selected XCTest pass membership differs: ' + json.dumps(names))
    swift = re.findall(r'Test ([A-Za-z0-9_]+)\(\) passed after ', text)
    if sorted(swift) != sorted(expected['swiftTesting']):
        raise ValueError('Selected Swift Testing pass membership differs')
    if any(word in text for word in ["' failed (", ' recorded an issue ', ' skipped (']):
        raise ValueError('A selected test failed or skipped')
    return dict(xctestPassed=names, swiftTestingPassed=swift)
