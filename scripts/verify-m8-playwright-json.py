#!/usr/bin/env python3
"""Verify the frozen M8 Playwright JSON report.

Fail-closed verifier for the Playwright JSON reporter output used as formal
runtime evidence by the M8 proof harness. It asserts that the report was
produced with retries disabled, that the run contains exactly the expected
number of tests, and that the report's spec-file set equals the frozen expected
spec set exactly.

Namespace contract: the reporter runs with rootDir = `<candidate>/apps/web`, so
the JSON reporter's suite `file` values are relative to that rootDir, e.g.
`e2e/golden-path.spec.ts`. Expected spec paths are compared after the same
normalization, as an exact relative-path SET. Suffix or basename matching is
deliberately not used: it would accept `apps/web/e2e/<spec>` or a duplicated
basename in an unrelated directory.

On success it atomically materializes the effective-retries evidence file.
A failing run never creates (and never leaves behind) that output file.

Standard library only. No network. No subprocess.
"""

import argparse
import json
import os
import sys

FAIL_MARKER = "FAIL: "


class _ArgumentParser(argparse.ArgumentParser):
    """Argument parser that reports usage errors as FAIL lines with exit 1."""

    def error(self, message):
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
        self.print_usage(sys.stderr)
        raise SystemExit(1)


def parse_args(argv):
    parser = _ArgumentParser(prog="verify-m8-playwright-json.py")
    parser.add_argument("--report", required=True,
                        help="Playwright JSON report to validate")
    parser.add_argument("--out", required=True,
                        help="destination of the effective-retries file")
    parser.add_argument("--expected-tests", type=int, default=34,
                        help="number of expected tests (default: 34)")
    parser.add_argument("--expected-project", default="chromium",
                        help="the only permitted project name (default: chromium)")
    parser.add_argument("--spec", action="append", default=[],
                        help="exact spec file path that must appear (repeatable)")
    parser.add_argument("--json-out", default=None,
                        help="optional machine-readable PASS summary")
    return parser.parse_args(argv)


def cleanup_final(paths):
    """Remove the named output files and their .tmp siblings if present."""
    for path in paths:
        if not path:
            continue
        for candidate in (path + ".tmp", path):
            try:
                os.remove(candidate)
            except OSError:
                pass


def cleanup_tmp(paths):
    """Remove only the .tmp siblings of the named output paths."""
    for path in paths:
        if not path:
            continue
        try:
            os.remove(path + ".tmp")
        except OSError:
            pass


def atomic_write_bytes(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(payload)
    os.replace(tmp, path)


def fail(message):
    sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
    raise SystemExit(1)


def fail_all(messages):
    for message in messages:
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
    raise SystemExit(1)


def iter_file_values(node):
    """Yield every string value of a `file` key anywhere in the node tree."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "file" and isinstance(value, str):
                yield value
            else:
                for item in iter_file_values(value):
                    yield item
    elif isinstance(node, list):
        for entry in node:
            for item in iter_file_values(entry):
                yield item


def normalize_spec_path(value):
    """Normalize a reporter path for exact, namespace-preserving comparison."""
    normalized = value.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    out_paths = [args.out]
    json_tmp_paths = [args.json_out] if args.json_out else []

    try:
        with open(args.report, "r", encoding="utf-8") as handle:
            report = json.load(handle)
    except Exception:
        cleanup_final(out_paths)
        cleanup_tmp(json_tmp_paths)
        fail("playwright JSON report is missing or unparseable")

    if not isinstance(report, dict):
        cleanup_final(out_paths)
        cleanup_tmp(json_tmp_paths)
        fail("playwright JSON report is missing or unparseable")

    failures = []

    config = report.get("config")
    projects = config.get("projects") if isinstance(config, dict) else None
    project_names = []
    project_retries = []
    if not isinstance(projects, list) or not projects:
        failures.append("config.projects is missing or not a non-empty list")
    else:
        for index, project in enumerate(projects):
            if not isinstance(project, dict):
                failures.append("config.projects[%d] is not an object" % index)
                continue
            name = project.get("name")
            retries = project.get("retries")
            if not isinstance(name, str) or not name:
                failures.append(
                    "config.projects[%d].name is missing or not a string" % index)
            else:
                project_names.append(name)
            project_retries.append(retries)
            if type(retries) is not int or retries != 0:
                failures.append(
                    "config.projects[%d] (%r) has retries=%r (expected 0)"
                    % (index, name, retries))
        if set(project_names) != {args.expected_project}:
            failures.append(
                "project names %s do not equal {%s}"
                % (sorted(set(project_names)), args.expected_project))

    stats = report.get("stats")
    if not isinstance(stats, dict):
        failures.append("stats is missing or not an object")
    else:
        for key, wanted in (("expected", args.expected_tests),
                            ("unexpected", 0),
                            ("flaky", 0),
                            ("skipped", 0)):
            value = stats.get(key)
            if type(value) is not int or value != wanted:
                failures.append(
                    "stats.%s is %r (expected %d)" % (key, value, wanted))

    observed_specs = {normalize_spec_path(value)
                      for value in iter_file_values(report.get("suites"))}
    expected_specs = {normalize_spec_path(spec) for spec in args.spec}
    for spec in sorted(expected_specs - observed_specs):
        failures.append("required spec not present in report suites: %s" % spec)
    for spec in sorted(observed_specs - expected_specs):
        failures.append("unexpected spec present in report suites: %s" % spec)

    if failures:
        cleanup_final(out_paths)
        cleanup_tmp(json_tmp_paths)
        fail_all(failures)

    try:
        atomic_write_bytes(args.out, b"PLAYWRIGHT_EFFECTIVE_RETRIES=0\n")
    except OSError as exc:
        cleanup_final(out_paths)
        cleanup_tmp(json_tmp_paths)
        fail("cannot write %s: %s" % (args.out, exc))

    if args.json_out:
        summary = {
            "schema": "linguagraph-m8-playwright-json-verify/v1",
            "expected": stats["expected"],
            "unexpected": stats["unexpected"],
            "flaky": stats["flaky"],
            "skipped": stats["skipped"],
            "projects": project_names,
            "retries": project_retries,
            "specs": list(args.spec),
            "status": "PASS",
        }
        payload = (json.dumps(summary, indent=2, sort_keys=True,
                              ensure_ascii=False) + "\n").encode("utf-8")
        try:
            atomic_write_bytes(args.json_out, payload)
        except OSError as exc:
            cleanup_final(out_paths)
            cleanup_tmp(json_tmp_paths)
            fail("cannot write %s: %s" % (args.json_out, exc))

    sys.stdout.write(
        "PLAYWRIGHT_JSON_VERIFY=PASS expected=%d unexpected=%d flaky=%d "
        "skipped=%d projects=%s specs=%d\n"
        % (stats["expected"], stats["unexpected"], stats["flaky"],
           stats["skipped"], ",".join(project_names), len(args.spec)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
