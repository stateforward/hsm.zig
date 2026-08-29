#!/usr/bin/env python3
"""Run the bounded Zig conformance runner over a JSON corpus."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=Path)
    parser.add_argument("cases", type=Path)
    args = parser.parse_args()

    case_paths = sorted(args.cases.glob("*.json"))
    if not case_paths:
        print(f"no conformance case files found in {args.cases}", file=sys.stderr)
        return 2

    counts = {"pass": 0, "skip": 0, "fail": 0, "crash": 0}
    for case_path in case_paths:
        completed = subprocess.run(
            [str(args.runner), str(case_path)],
            capture_output=True,
            text=True,
        )
        try:
            result = json.loads(completed.stdout)
            status = result["status"]
            if status not in ("pass", "skip", "fail"):
                raise ValueError("unknown status")
            expected_returncode = {"pass": 0, "skip": 77, "fail": 1}[status]
            if completed.returncode != expected_returncode:
                raise ValueError(
                    f"status {status!r} returned exit code {completed.returncode}, "
                    f"expected {expected_returncode}"
                )
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            counts["crash"] += 1
            print(f"crash {case_path}: {completed.stderr.strip()}", file=sys.stderr)
            continue
        counts[status] += 1
        if status == "fail":
            print(f"fail {case_path}: {result.get('reason', 'unknown')}", file=sys.stderr)

    print(json.dumps({"cases": sum(counts.values()), **counts}, sort_keys=True))
    return 1 if counts["fail"] or counts["crash"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
