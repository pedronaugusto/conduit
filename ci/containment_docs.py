#!/usr/bin/env python3
"""Keep the Darwin containment boundary beside the policy readers choose."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ContainmentDocs(unittest.TestCase):
    def check_boundary(self, text):
        text = text.lower()
        for term in ("observation", "kernel", "measured", "registration"):
            self.assertIn(term, text)
        self.assertIn("escape", text)

    def test_platform_table_states_the_measured_observation_boundary(self):
        row = next(line for line in (ROOT / "README.md").read_text().splitlines()
                   if line.startswith("| macOS |") and "lineage" in line)
        self.check_boundary(row)

    def test_policy_comment_states_the_measured_observation_boundary(self):
        policy = (ROOT / "src/Child.zig").read_text().split("pub const Descendants = enum {", 1)[1]
        self.check_boundary(policy.split("contain,", 1)[0])


if __name__ == "__main__":
    unittest.main()
