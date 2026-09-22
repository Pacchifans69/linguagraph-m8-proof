#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 seal / durability artifact helpers.
#
# Responsibilities (single implementation, shared by the semantic core and the
# formal wrapper so the deterministic manifest and archive semantics cannot
# drift):
#   * deterministic artifact-manifest.sha256 generation and verification;
#   * exactly one deterministic canonical tar.gz archive (create-if-absent);
#   * embedded-manifest extraction for durability read-back;
#   * canonical JSON normalisation and scalar extraction (stdlib python3 only).
#
# No archive file-mode normalisation is performed here: the pre-existing
# deterministic tar/gzip semantics are retained unchanged.

if [[ -n "${M8_MANIFEST_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
M8_MANIFEST_LIB_LOADED=1

m8_python_bin() { printf '%s' "${M8_PYTHON_BIN:-python3}"; }
m8_manifest_die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }

m8_sha256_file() {
  sha256sum "$1" | cut -d' ' -f1
}

m8_size_bytes() {
  wc -c <"$1" | tr -d '[:space:]'
}

readonly M8_MANIFEST_NAME='artifact-manifest.sha256'

# The reserved formal manifest is exactly ONE root-relative path,
# ./artifact-manifest.sha256, plus its atomic root temporary. Exclusion must be
# EXACT-PATH based and never basename based: a same-basename file at any deeper
# path (for example ./rogue/artifact-manifest.sha256) is an ordinary evidence
# artifact, must enter the manifest stream, and must therefore fail exact-set
# closure unless it is canonically required. Restricting `name` to a plain
# basename keeps a wildcard out of the find expression, so glob semantics can
# never re-widen the match.
m8_manifest_require_plain_name() {
  case "$1" in
    '' | '.' | '..' | */* | *'*'* | *'?'* | *'['* | *']'* | *\\*)
      m8_manifest_die "manifest name must be a plain basename without path or glob characters: $1"
      return 1
      ;;
  esac
  return 0
}

# Deterministic "<sha256>  ./<relative-path>" stream for <dir>, byte-sorted by
# path, excluding exactly the reserved root manifest and its root temporary.
# Single implementation, shared by generation and verification, so the two can
# never drift.
m8_manifest_stream() {
  local dir=$1 name=$2
  (
    cd "$dir" || exit 1
    find . -type f \
      ! -path "./$name" \
      ! -path "./.${name}.tmp" \
      -print0 | sort -z | xargs -0 -r sha256sum
  )
}

# Deterministic manifest of every regular file under <dir>, excluding exactly the
# reserved root manifest object and its atomic root temporary. Format retained
# from the original harness: "<sha256>  ./<relative-path>", byte-sorted by path.
m8_manifest_generate() {
  local dir=$1 name=${2:-$M8_MANIFEST_NAME}
  local tmp
  m8_manifest_require_plain_name "$name" || return 1
  tmp="$dir/.${name}.tmp"
  rm -f "$tmp"
  if m8_manifest_stream "$dir" "$name" >"$tmp"; then
    mv -f "$tmp" "$dir/$name" || {
      rm -f "$tmp"
      m8_manifest_die "could not install $name for $dir"
      return 1
    }
  else
    rm -f "$tmp"
    m8_manifest_die "could not generate $name for $dir"
    return 1
  fi
}

# Recompute the manifest and require it to be byte-identical to the frozen one.
# Any post-seal mutation of an execution artifact is therefore detected.
m8_manifest_verify() {
  local dir=$1 name=${2:-$M8_MANIFEST_NAME}
  local frozen="$dir/$name" recomputed=''
  m8_manifest_require_plain_name "$name" || return 1
  [[ -f "$frozen" ]] || { m8_manifest_die "frozen manifest is absent: $frozen"; return 1; }
  recomputed=$(mktemp "${TMPDIR:-/tmp}/m8-manifest.XXXXXX")
  m8_manifest_stream "$dir" "$name" >"$recomputed" || {
    rm -f "$recomputed"
    m8_manifest_die 'manifest recomputation failed'
    return 1
  }
  if ! cmp -s "$frozen" "$recomputed"; then
    rm -f "$recomputed"
    m8_manifest_die 'sealed artifact manifest no longer matches the current execution artifacts'
    return 1
  fi
  rm -f "$recomputed"
  return 0
}

# Build exactly one deterministic canonical archive.
#
#   m8_archive_build <root_dir> <archive_member> <archive_path>
#
# Both the archive and its sidecar are reserved with noclobber before any bytes
# are written, so an existing sealed archive can never be overwritten. Returns 2
# on reservation collision, 1 on failure, 0 on success.
m8_archive_build() {
  local root=$1 member=$2 archive=$3 sidecar="${3}.sha256"
  [[ -d "$root" ]] || { m8_manifest_die "archive root is not a directory: $root"; return 1; }
  [[ -n "$member" ]] || { m8_manifest_die 'archive member is empty'; return 1; }

  if ! (set -o noclobber; : >"$archive") 2>/dev/null; then
    return 2
  fi
  if ! (set -o noclobber; : >"$sidecar") 2>/dev/null; then
    rm -f "$archive"
    return 2
  fi
  rm -f "$archive"

  if ! tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$root" -cf - "$member" | gzip -n >"$archive"; then
    rm -f "$archive" "$sidecar"
    m8_manifest_die 'canonical archive creation failed'
    return 1
  fi
  if ! (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")" >"$(basename "$sidecar")"); then
    rm -f "$archive" "$sidecar"
    m8_manifest_die 'canonical archive sidecar failed'
    return 1
  fi
  return 0
}

# Extract "<member>/artifact-manifest.sha256" from an archive to stdout.
m8_archive_embedded_manifest() {
  local archive=$1 member=$2 manifest_name=${3:-$M8_MANIFEST_NAME}
  tar -xzOf "$archive" "$member/$manifest_name" || {
    m8_manifest_die "archive does not contain $member/$manifest_name"
    return 1
  }
}

# Canonical JSON: UTF-8, sorted keys, two-space indent, trailing newline.
m8_json_normalize() {
  local src=$1 dst=$2
  "$(m8_python_bin)" - "$src" "$dst" <<'PY' || return 1
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as handle:
    document = json.loads(handle.read().decode("utf-8"))
payload = json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
with open(dst, "wb") as handle:
    handle.write(payload.encode("utf-8"))
PY
}

# Print a scalar (or compact JSON for containers) at a dotted path.
m8_json_get() {
  local file=$1 path=$2
  "$(m8_python_bin)" - "$file" "$path" <<'PY'
import json
import sys

path, dotted = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as handle:
        node = json.loads(handle.read().decode("utf-8"))
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("FAIL: %s is not valid JSON: %s\n" % (path, exc))
    sys.exit(1)

for part in dotted.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.stderr.write("FAIL: %s is missing field %s\n" % (path, dotted))
        sys.exit(1)

if node is None:
    sys.stdout.write("null\n")
elif isinstance(node, bool):
    sys.stdout.write("true\n" if node else "false\n")
elif isinstance(node, (dict, list)):
    sys.stdout.write(json.dumps(node, sort_keys=True, separators=(",", ":")) + "\n")
else:
    sys.stdout.write(str(node) + "\n")
PY
}
