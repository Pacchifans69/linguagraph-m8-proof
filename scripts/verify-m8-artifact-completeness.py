#!/usr/bin/env python3
"""Verify M8 execution-artifact completeness and sealed-manifest integrity.

This verifier owns two independent, explicit responsibilities.

1. REQUIRED-SET VALIDATION AND SET CLOSURE (pre-seal).

   The required list is parsed as a canonical, EXPLICIT, relative-path set:
   duplicate entries, absolute paths, ``.``/``..`` components, any ``..``
   traversal component, empty or non-canonical forms, backslash separators and
   glob metacharacters are all rejected, and the reserved root manifest path may
   not appear. Blank and comment lines are ignored deterministically.

   The set of regular files actually present under the evidence root, minus the
   reserved ROOT-RELATIVE manifest path ``artifact-manifest.sha256``, must then
   equal the required set EXACTLY. A missing required artifact and an
   unexpected/unclassified artifact are both fatal.

   The exclusion is exact-path based and NEVER basename based. Only the one
   formal manifest at the evidence root is reserved; a same-basename file at any
   deeper path (for example ``rogue/artifact-manifest.sha256``) is an ordinary
   actual evidence artifact. If it is not explicitly present in the canonical
   required set it must cause completeness failure, and it may never disappear
   from actual-set or manifest-set accounting. The root manifest is excluded
   only because it is a seal-phase output that does not exist yet at the
   pre-manifest stage; the archive, package index and closure receipt live
   outside the evidence root and are never members of this set.

2. MANIFEST SET AND HASH VALIDATION (post-manifest, ``--manifest``).

   Every recorded manifest path must be a normalized, relative, non-traversing,
   non-duplicated path; only the reserved root-relative manifest path is barred
   from hashing itself; the manifest entry set must equal the required set
   exactly; and every recorded digest must equal the SHA-256 of the
   corresponding file on disk.

Standard library only. No network. No subprocess.
"""

import argparse
import hashlib
import json
import os
import re
import sys

FAIL_MARKER = "FAIL: "

# The ONE reserved formal manifest, expressed as an exact root-relative path.
# It is deliberately not a basename: a file named artifact-manifest.sha256 at
# any deeper path is ordinary evidence and takes part in set accounting.
RESERVED_MANIFEST_PATH = "artifact-manifest.sha256"
GLOB_CHARACTERS = "*?[]"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
_WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:")


class _ArgumentParser(argparse.ArgumentParser):
    """Argument parser that reports usage errors as FAIL lines with exit 1."""

    def error(self, message):
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
        self.print_usage(sys.stderr)
        raise SystemExit(1)


def parse_args(argv):
    parser = _ArgumentParser(prog="verify-m8-artifact-completeness.py")
    parser.add_argument("--root", required=True,
                        help="evidence root directory")
    parser.add_argument("--required", required=True,
                        help="required-artifact list file")
    parser.add_argument("--manifest", default=None,
                        help="optional artifact-manifest.sha256 to validate")
    parser.add_argument("--json-out", default=None,
                        help="optional machine-readable PASS summary")
    parser.add_argument("--label", default="required execution artifact",
                        help="label used in failure messages")
    return parser.parse_args(argv)


def fail(messages):
    if isinstance(messages, str):
        messages = [messages]
    for message in messages:
        sys.stderr.write("%s%s\n" % (FAIL_MARKER, message))
    raise SystemExit(1)


def atomic_write_bytes(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(payload)
    os.replace(tmp, path)


def canonical_relative_path(entry):
    """Return the entry if it is a canonical explicit relative path, else None.

    Canonical means: no surrounding whitespace, not absolute, no Windows drive
    prefix, no backslash separator, no glob metacharacter, not ``.`` or ``..``,
    no empty path component, and no ``./`` prefix.
    """
    if not entry or entry != entry.strip():
        return None
    if entry.startswith("/") or entry.startswith("~"):
        return None
    if _WINDOWS_DRIVE.match(entry):
        return None
    if "\\" in entry:
        return None
    if any(character in GLOB_CHARACTERS for character in entry):
        return None
    if entry in (".", ".."):
        return None
    if entry.startswith("./"):
        return None
    parts = entry.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None
    return entry


def normalize_relative_path(entry):
    """Return a normalized relative path, or None when it is not representable.

    Accepts the ``./<relative>`` form emitted by the deterministic manifest
    generator and normalizes it away. Absolute paths, traversal components,
    backslash separators and empty components are still rejected.
    """
    if not entry or entry != entry.strip():
        return None
    if entry.startswith("/") or entry.startswith("~"):
        return None
    if _WINDOWS_DRIVE.match(entry):
        return None
    if "\\" in entry:
        return None
    while entry.startswith("./"):
        entry = entry[2:]
    if entry in ("", ".", ".."):
        return None
    parts = entry.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None
    return entry


def read_required_entries(path):
    entries = []
    seen = set()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        fail("required list cannot be read: %s: %s" % (path, exc))
    for number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            continue
        canonical = canonical_relative_path(line)
        if canonical is None:
            fail("required list line %d is not a canonical explicit relative "
                 "path: %r" % (number, line))
        if canonical == RESERVED_MANIFEST_PATH:
            fail("required list line %d names the reserved seal-phase manifest "
                 "%s" % (number, RESERVED_MANIFEST_PATH))
        if canonical in seen:
            fail("required list line %d duplicates required entry: %s"
                 % (number, canonical))
        seen.add(canonical)
        entries.append(canonical)
    if not entries:
        fail("required list is empty after comments: %s" % path)
    return entries


def actual_regular_files(root):
    """Return sorted evidence-root-relative paths of regular (non-link) files."""
    found = []
    for directory, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            found.append(os.path.relpath(path, root).replace(os.sep, "/"))
    return sorted(set(found))


def read_manifest_entries(path):
    entries = []
    seen = set()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        fail("artifact manifest cannot be read: %s: %s" % (path, exc))
    for number, line in enumerate(lines, start=1):
        if not line:
            continue
        if "  " not in line:
            fail("manifest line %d is malformed (expected '<sha256>  <path>'): "
                 "%r" % (number, line))
        digest, _, raw_path = line.partition("  ")
        if not HEX64.match(digest):
            fail("manifest line %d does not start with a lowercase 64-hex "
                 "SHA-256: %r" % (number, digest))
        relative = normalize_relative_path(raw_path)
        if relative is None:
            fail("manifest line %d is not a normalized relative path: %r"
                 % (number, raw_path))
        if relative == RESERVED_MANIFEST_PATH:
            fail("manifest must not hash itself: %s" % relative)
        if relative in seen:
            fail("manifest line %d duplicates manifest entry: %s"
                 % (number, relative))
        seen.add(relative)
        entries.append((relative, digest))
    if not entries:
        fail("artifact manifest is empty: %s" % path)
    return entries


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if not os.path.isdir(args.root):
        fail("evidence root is not a directory: %s" % args.root)

    if not os.path.isfile(args.required):
        fail("required list is missing: %s" % args.required)

    entries = read_required_entries(args.required)
    required_set = set(entries)

    # --- 1. pre-seal actual-set closure -----------------------------------
    # Exact root-relative path exclusion ONLY. A same-basename artifact at any
    # deeper path is ordinary evidence and must remain in actual-set accounting.
    actual = [relative for relative in actual_regular_files(args.root)
              if relative != RESERVED_MANIFEST_PATH]
    actual_set = set(actual)

    failures = []
    for entry in sorted(required_set - actual_set):
        failures.append("missing %s: %s" % (args.label, entry))
    for entry in sorted(actual_set - required_set):
        failures.append("unexpected unclassified artifact in the evidence "
                        "root: %s" % entry)
    if failures:
        if args.json_out:
            try:
                os.remove(args.json_out + ".tmp")
            except OSError:
                pass
        fail(failures)

    # --- 2. manifest set/hash validation ----------------------------------
    manifest_entries = []
    if args.manifest:
        if not os.path.isfile(args.manifest):
            fail("artifact manifest is missing: %s" % args.manifest)
        manifest_entries = read_manifest_entries(args.manifest)
        manifest_set = {relative for relative, _ in manifest_entries}
        failures = []
        for entry in sorted(required_set - manifest_set):
            failures.append("manifest is missing required entry: %s" % entry)
        for entry in sorted(manifest_set - required_set):
            failures.append("manifest records an entry outside the required "
                            "set: %s" % entry)
        for relative, digest in manifest_entries:
            path = os.path.join(args.root, relative)
            try:
                with open(path, "rb") as handle:
                    actual_digest = hashlib.sha256(handle.read()).hexdigest()
            except OSError as exc:
                failures.append("manifest entry cannot be read: %s: %s"
                                % (relative, exc))
                continue
            if actual_digest != digest:
                failures.append("manifest digest mismatch for %s (recorded %s; "
                                "actual %s)" % (relative, digest, actual_digest))
        if failures:
            if args.json_out:
                try:
                    os.remove(args.json_out + ".tmp")
                except OSError:
                    pass
            fail(failures)

    if args.json_out:
        document = {
            "schema": "linguagraph-m8-artifact-completeness/v1",
            "root": args.root,
            "required_count": len(entries),
            "actual_count": len(actual),
            "required": entries,
            "manifest": args.manifest,
            "manifest_count": len(manifest_entries),
            "closure": "EXACT",
            "status": "PASS",
        }
        payload = (json.dumps(document, indent=2, sort_keys=True,
                              ensure_ascii=False) + "\n").encode("utf-8")
        try:
            atomic_write_bytes(args.json_out, payload)
        except OSError as exc:
            try:
                os.remove(args.json_out + ".tmp")
            except OSError:
                pass
            fail("cannot write %s: %s" % (args.json_out, exc))

    sys.stdout.write(
        "ARTIFACT_COMPLETENESS=PASS required=%d actual=%d closure=EXACT\n"
        % (len(entries), len(actual)))
    if args.manifest:
        sys.stdout.write(
            "ARTIFACT_MANIFEST=PASS entries=%d set=EXACT hashes=VERIFIED\n"
            % len(manifest_entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
