#!/usr/bin/env python3

import json
import sys
from pathlib import Path


REQUIRED_PASSES = {
    "TestSoonClientPrefaceWithStreamId",
    "TestSoonClientShortSettings",
    "TestSoonShortPreface",
    "TestSoonUnknownFrameType",
    "TestSoonAllSettingsFramesAcked",
}
UPSTREAM_HARNESS_LIMITATIONS = {
    "TestSoonSmallMaxFrameSize",
}
EXPECTED_SKIPS = {
    "TestSoonTLSApplicationProtocol",
    "TestSoonTLSMaxVersion",
    "TestSoonTLSBadCipherSuites",
}


def load_report(path: Path) -> dict:
    for line in reversed(path.read_text(encoding="utf-8").splitlines()):
        if line.startswith('{"cases":'):
            return json.loads(line)
    raise ValueError("HTTP/2 report JSON was not found")


def validate(report: dict) -> list[str]:
    entries = report.get("cases")
    if not isinstance(entries, list):
        return ["HTTP/2 report does not contain a cases list"]

    cases = {entry.get("name"): entry for entry in entries}
    expected = REQUIRED_PASSES | UPSTREAM_HARNESS_LIMITATIONS | EXPECTED_SKIPS
    errors = [
        f"missing expected case: {name}" for name in sorted(expected - cases.keys())
    ]

    for name in sorted(REQUIRED_PASSES & cases.keys()):
        case = cases[name]
        if not case.get("passed") or case.get("skipped"):
            errors.append(f"required framing case did not pass: {name}")

    for name in sorted(UPSTREAM_HARNESS_LIMITATIONS & cases.keys()):
        case = cases[name]
        if case.get("skipped"):
            errors.append(
                f"upstream harness limitation was unexpectedly skipped: {name}"
            )
        if case.get("passed"):
            errors.append(f"upstream harness limitation unexpectedly passed: {name}")

    for name in sorted(EXPECTED_SKIPS & cases.keys()):
        if not cases[name].get("skipped"):
            errors.append(f"out-of-scope TLS case was not skipped: {name}")

    for name in sorted(cases.keys() - expected):
        case = cases[name]
        if not case.get("passed") or case.get("skipped"):
            errors.append(f"new framing case is not passing: {name}")

    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} REPORT", file=sys.stderr)
        return 2

    try:
        report = load_report(Path(sys.argv[1]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1

    errors = validate(report)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    limitations = sorted(UPSTREAM_HARNESS_LIMITATIONS)
    print(
        "HTTP/2 framing report validated; upstream harness limitations: "
        + ", ".join(limitations)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
