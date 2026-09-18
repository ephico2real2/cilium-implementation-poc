#!/usr/bin/env python3
"""Contract tests shared with the Go sibling: duration spellings and the percentile method."""
import unittest

import shopctl


class DurationFlags(unittest.TestCase):
    def test_duration_and_timeout_accept_bare_seconds_and_go_units(self):
        for spelled, want in {"3": 3.0, "3s": 3.0, "0.5": 0.5, "500ms": 0.5, "1m": 60.0}.items():
            ns = shopctl.parse_args(["load", "--url", "https://x", "--rate", "1", "--duration", spelled, "--timeout", spelled])
            self.assertEqual((ns.duration, ns.timeout), (want, want), spelled)

    def test_rejects_garbage(self):
        with self.assertRaises(SystemExit):
            shopctl.parse_args(["probe", "--url", "https://x", "--timeout", "soon"])


class Percentiles(unittest.TestCase):
    def test_nearest_rank_matches_go(self):
        hits = [{"latency_ms": float(i)} for i in range(1, 11)]
        self.assertEqual(shopctl.latency_summary(hits), (5.0, 9.0, 9.0, 10.0))


if __name__ == "__main__":
    unittest.main()
