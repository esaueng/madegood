"""Regress the credential boundary with no production credentials."""
from pathlib import Path
import re
import unittest

WORKFLOWS = Path(__file__).parents[1] / "workflows"


class WorkflowTrustTests(unittest.TestCase):
    def setUp(self):
        self.text = (WORKFLOWS / "history-privacy.yml").read_text()
        self.events = self.text.split("\npermissions:", 1)[0]

    def test_only_main_defined_triggers(self):
        # Each of these runs the copy of this file on main. pull_request and
        # merge_group would run a branch-controlled copy.
        for event in ("pull_request_target:", "workflow_dispatch:", "schedule:"):
            self.assertIn(event, self.events)
        self.assertIn("  push:\n    branches: [main]\n", self.events)
        self.assertNotRegex(self.events, r"(?m)^  (pull_request|merge_group|workflow_run):")
        self.assertNotIn("tags:", self.events)

    def test_scanner_never_comes_from_the_incoming_head(self):
        self.assertIn("ref: ${{ github.workflow_sha }}", self.text)
        self.assertNotIn("github.event.pull_request.head", self.text)
        self.assertNotIn("github.head_ref", self.text)
        self.assertIn("persist-credentials: false", self.text)

    def test_secrets_stay_in_the_protected_environment_and_app_token(self):
        self.assertIn("environment: history-privacy", self.text)
        self.assertRegex(self.text, r"(?m)^permissions:\n  contents: read\n")
        writes = [line.strip() for line in self.text.splitlines() if re.search(r":\s*write\s*$", line)]
        self.assertEqual(writes, ["permission-checks: write"])
        self.assertIn("permission-checks: write", self.text)
        self.assertRegex(self.text, r"uses: actions/create-github-app-token@[0-9a-f]{40}")
        self.assertRegex(self.text, r"uses: actions/checkout@[0-9a-f]{40}")
        self.assertEqual(self.text.count("GH_TOKEN: ${{ steps.publisher.outputs.token }}"), 2)
        # Fetching this private repository, and reading commit metadata.
        self.assertEqual(self.text.count("GH_READ_TOKEN: ${{ github.token }}"), 2)

    def test_both_required_checks_have_one_protected_publisher(self):
        self.assertIn("python3 .github/privacy/history_privacy.py --ci", self.text)
        self.assertIn("python3 .github/privacy/commit_privacy.py", self.text)
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            if path.name == "history-privacy.yml":
                continue
            other = path.read_text()
            with self.subTest(workflow=path.name):
                self.assertNotIn("history_privacy.py --ci", other)
                self.assertNotIn("commit_privacy.py", other)
                self.assertNotRegex(other, r"(?m)^\s+(name|context):\s*['\"]?(history|commit)-privacy['\"]?\s*$")

    def test_test_workflow_has_no_credentials(self):
        text = (WORKFLOWS / "privacy-tests.yml").read_text()
        self.assertNotIn("secrets.", text)
        self.assertNotIn("environment:", text)
        self.assertNotRegex(text, r":\s*write\b")


if __name__ == "__main__":
    unittest.main()
