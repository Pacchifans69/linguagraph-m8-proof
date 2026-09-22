#!/usr/bin/env python3
"""Verify the M8 closure receipt.

Read-only verifier for the M8-HSDR-F02 closure receipt. It hashes the exact
file bytes, checks that every required field path is present with the correct
type, and enforces the receipt's semantic cross-binding rules. A receipt is
valid only when it is a PASS receipt: no FAIL or INDETERMINATE receipt is ever
accepted.

The receipt hash is always taken over the exact input bytes; the document is
never re-serialized or reformatted before hashing.

Standard library only. No network. No subprocess.
"""

import argparse
import hashlib
import json
import os
import re
import sys

FAIL_MARKER = "FAIL: "

RECEIPT_SCHEMA = "linguagraph-m8-closure-receipt/v1"

EXPECTED_FIELDS = [
    ("schema", "str"),
    ("closure_outcome", "str"),
    ("authorization_kind", "str"),
    ("authorization_sha256", "sha256"),
    ("semantic_auth_sha256", "sha256"),
    ("retry_auth_sha256", "sha256_or_null"),
    ("claim_sha256", "sha256"),
    ("claim_object", "str"),
    ("issued_object", "str"),
    ("issued_document_sha256", "sha256"),
    ("oss_trust_profile_sha256", "sha256"),
    ("proof_sha", "sha40"),
    ("proof_tree", "sha40"),
    ("candidate_sha", "sha40"),
    ("candidate_tree", "sha40"),
    ("candidate_parent", "sha40"),
    ("frozen_main", "sha40"),
    ("executor_id", "str"),
    ("authorized_executor_id", "str"),
    ("provider_identity.instance_id", "str"),
    ("provider_identity.region_id", "str"),
    ("provider_identity.zone_id", "str"),
    ("provider_identity.instance_type", "str"),
    ("provider_identity.image_id", "str"),
    ("provider_identity.identity_document_sha256", "sha256"),
    ("provider_identity.identity_pkcs7_sha256", "sha256"),
    ("run_prefix", "str"),
    ("archive_name", "str"),
    ("archive_object", "str"),
    ("archive_sha256", "sha256"),
    ("archive_size_bytes", "int"),
    ("artifact_manifest_sha256", "sha256"),
    ("package_index_sha256", "sha256"),
    ("package_index_object", "str"),
    ("core_exit_code", "int"),
    ("adapter_exit_code", "int"),
    ("formal_execution_rc", "int"),
    ("playwright_effective_retries", "int"),
    ("formal_command_rc", "int"),
    ("execution_started_utc", "str"),
    ("committed_utc", "str"),
    ("cross_binding.sealed_archive_sha256", "sha256"),
    ("cross_binding.package_index_archive_sha256", "sha256"),
    ("cross_binding.manifest_sha256", "sha256"),
    ("cross_binding.issued_document_sha256", "sha256"),
    ("cross_binding.oss_trust_profile_sha256", "sha256"),
    ("cross_binding.claim_object_sha256", "sha256"),
]

SHA256_FIELDS = [path for path, kind in EXPECTED_FIELDS if kind == "sha256"]
SHA40_FIELDS = [path for path, kind in EXPECTED_FIELDS if kind == "sha40"]

HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")

_MISSING = object()


class _ArgumentParser(argparse.ArgumentParser):
    """Argument parser that reports usage errors as FAIL lines with exit 1."""

    def error(self, message):
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
        self.print_usage(sys.stderr)
        raise SystemExit(1)


def parse_args(argv):
    parser = _ArgumentParser(prog="verify-m8-closure-receipt.py")
    parser.add_argument("--receipt", required=True,
                        help="closure receipt JSON file")
    parser.add_argument("--expect-sha256", default=None,
                        help="expected sha256 over the exact receipt bytes")
    parser.add_argument("--expect-proof-sha", default=None)
    parser.add_argument("--expect-candidate-sha", default=None)
    parser.add_argument("--expect-authorization-sha", default=None)
    parser.add_argument("--expect-archive-sha256", default=None)
    parser.add_argument("--expect-oss-trust-profile-sha256", default=None,
                        help="expected OSS trust-profile digest bound by the authorization")
    parser.add_argument("--json-out", default=None,
                        help="optional machine-readable PASS summary")
    return parser.parse_args(argv)


def fail_all(messages):
    for message in messages:
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
    raise SystemExit(1)


def atomic_write_bytes(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(payload)
    os.replace(tmp, path)


def type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def check_type(value, kind):
    if kind == "str":
        return isinstance(value, str)
    if kind == "int":
        return type(value) is int
    if kind == "sha256":
        return isinstance(value, str)
    if kind == "sha40":
        return isinstance(value, str)
    if kind == "sha256_or_null":
        return value is None or isinstance(value, str)
    raise ValueError("unknown field kind: %s" % kind)


def resolve_path(document, path):
    """Resolve a dotted path.

    Returns ("ok", None, value), ("missing", path, None), or
    ("type", prefix, value) when an intermediate value is not an object.
    """
    node = document
    parts = path.split(".")
    for index, part in enumerate(parts):
        if not isinstance(node, dict):
            return ("type", ".".join(parts[:index]), node)
        if part not in node:
            return ("missing", path, None)
        node = node[part]
    return ("ok", path, node)


def contains_key(node, key):
    if isinstance(node, dict):
        if key in node:
            return True
        return any(contains_key(value, key) for value in node.values())
    if isinstance(node, list):
        return any(contains_key(value, key) for value in node)
    return False


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        with open(args.receipt, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        fail_all(["receipt is missing or unreadable: %s: %s"
                  % (args.receipt, exc)])

    receipt_sha = hashlib.sha256(raw).hexdigest()

    failures = []

    if args.expect_sha256 is not None and args.expect_sha256 != receipt_sha:
        failures.append("--expect-sha256 mismatch: expected %s, got %s"
                        % (args.expect_sha256, receipt_sha))

    try:
        document = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as exc:
        fail_all(failures + ["receipt is not valid UTF-8 JSON: %s" % exc])
    except ValueError as exc:
        fail_all(failures + ["receipt is not valid JSON: %s" % exc])

    if not isinstance(document, dict):
        fail_all(failures + ["receipt JSON is not an object: got %s"
                             % type_name(document)])

    if contains_key(document, "terminal_line"):
        failures.append("forbidden key present anywhere in receipt: terminal_line")

    values = {}
    for path, kind in EXPECTED_FIELDS:
        status, where, value = resolve_path(document, path)
        if status == "missing":
            failures.append("missing required field: %s" % path)
            continue
        if status == "type":
            failures.append(
                "required field path is not an object: %s (got %s)"
                % (where, type_name(value)))
            continue
        if not check_type(value, kind):
            failures.append(
                "required field %s has wrong type: %s" % (path, type_name(value)))
            continue
        values[path] = value

    # -- semantic rules ---------------------------------------------------
    if "schema" in values and values["schema"] != RECEIPT_SCHEMA:
        failures.append("schema is %r (expected %s)"
                        % (values["schema"], RECEIPT_SCHEMA))

    if "closure_outcome" in values and values["closure_outcome"] != "PASS":
        failures.append("closure_outcome is %r (expected PASS)"
                        % (values["closure_outcome"],))

    for path in ("formal_command_rc", "core_exit_code", "adapter_exit_code",
                 "formal_execution_rc"):
        if path in values and values[path] != 0:
            failures.append("%s is %r (expected 0)" % (path, values[path]))

    if ("playwright_effective_retries" in values
            and values["playwright_effective_retries"] != 0):
        failures.append("playwright_effective_retries is %r (expected 0)"
                        % (values["playwright_effective_retries"],))

    if "archive_size_bytes" in values and values["archive_size_bytes"] <= 0:
        failures.append("archive_size_bytes is not a positive integer: %r"
                        % (values["archive_size_bytes"],))

    kind = values.get("authorization_kind")
    if kind is not None and kind not in ("SEMANTIC", "DURABILITY_RETRY"):
        failures.append("authorization_kind is %r (expected SEMANTIC or "
                        "DURABILITY_RETRY)" % (kind,))
    elif kind == "SEMANTIC":
        retry = values.get("retry_auth_sha256", _MISSING)
        if retry is not _MISSING and retry is not None:
            failures.append(
                "SEMANTIC authorization must set retry_auth_sha256 to null")
        auth = values.get("authorization_sha256", _MISSING)
        sem = values.get("semantic_auth_sha256", _MISSING)
        if auth is not _MISSING and sem is not _MISSING and auth != sem:
            failures.append(
                "SEMANTIC authorization_sha256 must equal semantic_auth_sha256")
    elif kind == "DURABILITY_RETRY":
        retry = values.get("retry_auth_sha256", _MISSING)
        auth = values.get("authorization_sha256", _MISSING)
        sem = values.get("semantic_auth_sha256", _MISSING)
        if retry is not _MISSING and auth is not _MISSING and retry != auth:
            failures.append(
                "DURABILITY_RETRY retry_auth_sha256 must equal "
                "authorization_sha256")
        if sem is not _MISSING and auth is not _MISSING and sem == auth:
            failures.append(
                "DURABILITY_RETRY semantic_auth_sha256 must differ from "
                "authorization_sha256")

    for path in SHA256_FIELDS:
        if path in values and not HEX64.match(values[path]):
            failures.append("%s is not lowercase 64-hex: %r"
                            % (path, values[path]))
    if "retry_auth_sha256" in values and values["retry_auth_sha256"] is not None:
        if not HEX64.match(values["retry_auth_sha256"]):
            failures.append("retry_auth_sha256 is not lowercase 64-hex: %r"
                            % (values["retry_auth_sha256"],))

    for path in SHA40_FIELDS:
        if path in values and not HEX40.match(values[path]):
            failures.append("%s is not lowercase 40-hex: %r"
                            % (path, values[path]))

    def get(path):
        return values.get(path, _MISSING)

    proof_sha = get("proof_sha")
    semantic_sha = get("semantic_auth_sha256")
    auth_sha = get("authorization_sha256")
    archive_name = get("archive_name")
    run_prefix = get("run_prefix")
    archive_sha = get("archive_sha256")
    manifest_sha = get("artifact_manifest_sha256")
    claim_sha = get("claim_sha256")

    expected_run_prefix = None
    if proof_sha is not _MISSING and semantic_sha is not _MISSING:
        expected_run_prefix = "runs/%s/%s" % (proof_sha, semantic_sha)
        if run_prefix is not _MISSING and run_prefix != expected_run_prefix:
            failures.append("run_prefix is %r (expected %r)"
                            % (run_prefix, expected_run_prefix))

    if run_prefix is not _MISSING and archive_name is not _MISSING:
        expected = "%s/%s" % (run_prefix, archive_name)
        if get("archive_object") not in (_MISSING, expected):
            failures.append("archive_object is %r (expected %r)"
                            % (get("archive_object"), expected))

    if run_prefix is not _MISSING:
        expected = "%s/package-index.json" % run_prefix
        if get("package_index_object") not in (_MISSING, expected):
            failures.append("package_index_object is %r (expected %r)"
                            % (get("package_index_object"), expected))

    if auth_sha is not _MISSING:
        expected_claim = "authorizations/%s/claim.json" % auth_sha
        if get("claim_object") not in (_MISSING, expected_claim):
            failures.append("claim_object is %r (expected %r)"
                            % (get("claim_object"), expected_claim))
        expected_issued = "authorizations/%s/issued.json" % auth_sha
        if get("issued_object") not in (_MISSING, expected_issued):
            failures.append("issued_object is %r (expected %r)"
                            % (get("issued_object"), expected_issued))

    cross_checks = (
        ("cross_binding.sealed_archive_sha256", archive_sha),
        ("cross_binding.package_index_archive_sha256", archive_sha),
        ("cross_binding.manifest_sha256", manifest_sha),
        ("cross_binding.issued_document_sha256", get("issued_document_sha256")),
        ("cross_binding.oss_trust_profile_sha256", get("oss_trust_profile_sha256")),
        ("cross_binding.claim_object_sha256", claim_sha),
    )
    for path, expected in cross_checks:
        if expected is _MISSING or path not in values:
            continue
        if values[path] != expected:
            failures.append("%s is %r (expected %r)"
                            % (path, values[path], expected))

    executor_id = get("executor_id")
    authorized_executor_id = get("authorized_executor_id")
    if (executor_id is not _MISSING and authorized_executor_id is not _MISSING
            and executor_id != authorized_executor_id):
        failures.append("executor_id %r does not equal authorized_executor_id %r"
                        % (executor_id, authorized_executor_id))

    expectations = (
        ("--expect-proof-sha", args.expect_proof_sha, "proof_sha"),
        ("--expect-candidate-sha", args.expect_candidate_sha, "candidate_sha"),
        ("--expect-authorization-sha", args.expect_authorization_sha,
         "authorization_sha256"),
        ("--expect-archive-sha256", args.expect_archive_sha256, "archive_sha256"),
        ("--expect-oss-trust-profile-sha256", args.expect_oss_trust_profile_sha256,
         "oss_trust_profile_sha256"),
    )
    for flag, expected, path in expectations:
        if expected is None or path not in values:
            continue
        if values[path] != expected:
            failures.append("%s mismatch: expected %s, got %s"
                            % (flag, expected, values[path]))

    if failures:
        fail_all(failures)

    if args.json_out:
        document_out = {
            "schema": "linguagraph-m8-closure-receipt-check/v1",
            "receipt_sha256": receipt_sha,
            "status": "PASS",
            "formal_command_rc": 0,
            "closure_outcome": "PASS",
        }
        payload = (json.dumps(document_out, indent=2, sort_keys=True,
                              ensure_ascii=False) + "\n").encode("utf-8")
        try:
            atomic_write_bytes(args.json_out, payload)
        except OSError as exc:
            try:
                os.remove(args.json_out + ".tmp")
            except OSError:
                pass
            fail_all(["cannot write %s: %s" % (args.json_out, exc)])

    sys.stdout.write("CLOSURE_RECEIPT_VERIFY=PASS sha256=%s\n" % receipt_sha)
    return 0


if __name__ == "__main__":
    sys.exit(main())
