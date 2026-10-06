import unittest

from .exclusive_host import classify_processes


class ExclusiveHostTests(unittest.TestCase):
    def test_owned_tree_and_idle_listener_are_allowed(self):
        text = "1 99 1 /usr/bin/python3\n2 1 22 /usr/bin/swift-frontend\n3 2 33 /tmp/DarkbloomProviderPackageTests\n4 99 4 /tmp/Runner.Listener\n"
        self.assertEqual(classify_processes(text, 22, 1), {})

    def test_new_ci_or_gpu_work_fails_closed_without_identifiers(self):
        text = "41 99 40 /tmp/Runner.Worker\n51 99 50 /some/private/path/darkbloom\n61 99 60 /usr/bin/python3\n71 99 70 /usr/bin/swift-frontend\n"
        self.assertEqual(classify_processes(text, 22, 1), {
            "ci_worker": 1, "compiler": 1, "inference_or_test_runner": 1, "other_python_work": 1})
