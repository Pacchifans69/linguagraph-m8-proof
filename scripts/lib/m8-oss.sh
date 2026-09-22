#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 durable-evidence OSS client.
#
# Contract (R2B):
#   * official `ossutil api <operation>` commands ONLY;
#   * no custom OSS request signing, no Alibaba OSS SDK dependency;
#   * the proof harness NEVER installs ossutil (host provisioning supplies it);
#   * every canonical object is created with atomic create-if-absent
#     (put-object ... --forbid-overwrite true), never HEAD-then-unconditional-PUT;
#   * every PutObject body uses the official file form `--body file://<path>`;
#     a bare local path is never passed as a body;
#   * GetObject stays byte-exact: the response body goes straight from ossutil
#     stdout into a file, never through shell command substitution or a variable;
#   * bucket versioning is verified read-only and must be unversioned before any
#     PutObject; the harness has no PutBucketVersioning authority;
#   * existing objects are never overwritten and ETag is never treated as SHA-256.
#
# Configuration:
#   M8_OSS_BUCKET                required canonical bucket name
#   M8_OSSUTIL_BIN               executable (default: ossutil); synthetic tests
#                                point this at a stub binary
#   M8_OSSUTIL_CONFIG_FILE       optional ossutil config file (-c)
#   M8_OSSUTIL_GET_OUTPUT_FLAG   optional response-body flag for get-object
#                                (default: capture stdout, byte-exact)
#
# Return codes:
#   M8_OSS_OK=0  M8_OSS_EXISTS=10  M8_OSS_ERROR=11  M8_OSS_ABSENT=12

readonly M8_OSS_OK=0
readonly M8_OSS_EXISTS=10
readonly M8_OSS_ERROR=11
readonly M8_OSS_ABSENT=12

m8_python_bin() { printf '%s' "${M8_PYTHON_BIN:-python3}"; }

m8_oss_die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }

m8_oss_bucket() { printf '%s' "${M8_OSS_BUCKET:-}"; }
m8_ossutil_bin() { printf '%s' "${M8_OSSUTIL_BIN:-ossutil}"; }

# Validate bucket/executable configuration. Fails closed on anything unset,
# malformed or non-executable.
m8_oss_require_config() {
  local bucket
  bucket=$(m8_oss_bucket)
  [[ -n "$bucket" ]] || { m8_oss_die 'M8_OSS_BUCKET is not configured'; return 1; }
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || { m8_oss_die "M8_OSS_BUCKET is not a canonical bucket name: $bucket"; return 1; }

  local bin
  bin=$(m8_ossutil_bin)
  [[ -n "$bin" ]] || { m8_oss_die 'M8_OSSUTIL_BIN is empty'; return 1; }
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] || { m8_oss_die "ossutil executable is not executable: $bin"; return 1; }
  else
    command -v "$bin" >/dev/null 2>&1 || { m8_oss_die "ossutil executable is absent from PATH: $bin"; return 1; }
  fi
  return 0
}

# Run one official ossutil api operation. No shell evaluation of arguments.
m8_oss_api() {
  local bin config
  bin=$(m8_ossutil_bin)
  config="${M8_OSSUTIL_CONFIG_FILE:-}"
  if [[ -n "$config" ]]; then
    "$bin" --config-file "$config" api "$@"
  else
    "$bin" api "$@"
  fi
}

m8_oss_run() {
  local bin config
  bin=$(m8_ossutil_bin)
  config="${M8_OSSUTIL_CONFIG_FILE:-}"
  if [[ -n "$config" ]]; then
    "$bin" --config-file "$config" "$@"
  else
    "$bin" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Capability guard (spec section 4).
#
# Establishes that the provisioned ossutil supports the exact operations the
# harness depends on, including the --forbid-overwrite parameter of put-object.
# Fails CLOSED when any capability cannot be demonstrated.
# ---------------------------------------------------------------------------
m8_oss_capability_guard() {
  local evidence=${1:-'-'} op probe_output='' aggregate='' probe_ok=0
  local -a operations=(put-object get-object head-object get-bucket-versioning)
  local help_output='' help_ok=0 probes_ok=0

  m8_oss_require_config || return 1

  if [[ "$evidence" != '-' ]]; then
    mkdir -p "$evidence" || { m8_oss_die "cannot create $evidence"; return 1; }
  fi

  # Version banner is provenance only; the record is always kept.
  local version_output='' version_rc=0
  version_output=$(m8_oss_run version 2>&1) || version_rc=$?
  if [[ "$evidence" != '-' ]]; then
    {
      printf 'ossutil_bin=%s\n' "$(m8_ossutil_bin)"
      printf 'ossutil_version_rc=%s\n' "$version_rc"
      printf 'ossutil_version_output:\n%s\n' "$version_output"
    } >> "$evidence/ossutil-capability.txt"
  fi

  # The global api help page documents the generated operations and may be the
  # only place parameters are listed.
  if help_output=$(m8_oss_run help api 2>&1); then
    help_ok=1
    aggregate+=$'\n'"$help_output"
  fi

  # Per-operation help is the strongest evidence, but ossutil versions differ in
  # whether `api <op> --help` is supported. A failed probe is tolerated only when
  # the global help page still documents the operation and its parameters; the
  # actual parameter support is enforced at runtime, where an unsupported
  # --forbid-overwrite makes the PutObject fail closed.
  for op in "${operations[@]}"; do
    probe_output=''
    probe_ok=0
    if probe_output=$(m8_oss_api "$op" --help 2>&1); then
      probe_ok=1
    elif probe_output=$(m8_oss_api "$op" -h 2>&1); then
      probe_ok=1
    fi
    (( probe_ok == 1 )) && probes_ok=$((probes_ok + 1))
    aggregate+=$'\n'"$probe_output"
    if [[ "$evidence" != '-' ]]; then
      {
        printf '\n[probe] ossutil api %s --help\n' "$op"
        printf 'probe_ok=%s\n' "$probe_ok"
        printf '%s\n' "$probe_output"
      } >> "$evidence/ossutil-capability.txt"
    fi
  done

  (( help_ok == 1 || probes_ok >= 1 )) ||
    { m8_oss_die 'ossutil does not expose a usable api command surface'; return 1; }

  local op
  for op in "${operations[@]}"; do
    grep -Eq "(^|[^a-z-])${op}([^a-z-]|$)" <<<"$aggregate" ||
      { m8_oss_die "ossutil help does not list operation '$op'"; return 1; }
  done
  grep -Eiq 'forbid[-_]overwrite' <<<"$aggregate" ||
    { m8_oss_die "ossutil does not demonstrate the '--forbid-overwrite' put-object parameter"; return 1; }

  if [[ "$evidence" != '-' ]]; then
    printf 'ossutil_capability=PASS\n' >> "$evidence/ossutil-capability.txt"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Bucket versioning guard (spec section 5).
#
# Read-only. Only an unversioned bucket (empty/Null/absent Status) is eligible.
# Enabled, Suspended, unknown, unparseable and access-denied all FAIL CLOSED.
# ---------------------------------------------------------------------------
m8_oss_versioning_guard() {
  local evidence=${1:-'-'} raw='' rc=0 verdict='' classification='' raw_file=''
  m8_oss_require_config || return 1

  raw=$(m8_oss_api get-bucket-versioning --bucket "$(m8_oss_bucket)" 2>&1) || rc=$?

  if [[ "$evidence" != '-' ]]; then
    mkdir -p "$evidence" 2>/dev/null || true
    {
      printf 'get_bucket_versioning_rc=%s\n' "$rc"
      printf 'get_bucket_versioning_output:\n%s\n' "$raw"
    } >> "$evidence/oss-versioning-guard.txt"
  fi

  if (( rc != 0 )); then
    m8_oss_die "bucket versioning query failed (rc=$rc); refusing any PutObject"
    return 1
  fi

  # The classifier program is supplied on stdin, so the API response is
  # classified from a file: it must not also try to read the response from stdin.
  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-versioning.XXXXXX")
  printf '%s' "$raw" > "$raw_file"
  verdict=$("$(m8_python_bin)" - "$raw_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    raw = handle.read()

def emit(value):
    sys.stdout.write(value + "\n")
    sys.exit(0)

stripped = raw.strip()
if stripped == "":
    emit("UNVERSIONED")

status = None
match = re.search(r"<Status>\s*([^<]*?)\s*</Status>", stripped)
if match:
    status = match.group(1)
else:
    doc = None
    try:
        doc = json.loads(stripped)
    except Exception:
        doc = None
    if isinstance(doc, dict):
        value = None
        for key in ("Status", "status"):
            if key in doc:
                value = doc[key]
                break
        if value is None:
            inner = doc.get("VersioningConfiguration")
            if isinstance(inner, dict):
                value = inner.get("Status", inner.get("status"))
        if value is None:
            if len(doc) == 0 or set(doc).issubset({"VersioningConfiguration", "ResponseMetadata"}):
                emit("UNVERSIONED")
            else:
                emit("UNPARSEABLE")
        status = str(value)
    elif doc is None:
        if re.fullmatch(r"(?is)(<\?xml[^>]*\?>\s*)?<VersioningConfiguration\s*/>", stripped) or \
           re.fullmatch(r"(?is)(<\?xml[^>]*\?>\s*)?<VersioningConfiguration>\s*</VersioningConfiguration>", stripped):
            emit("UNVERSIONED")
        emit("UNPARSEABLE")
    else:
        emit("UNPARSEABLE")

normalised = (status or "").strip().lower()
if normalised in ("", "null", "unversioned", "none"):
    emit("UNVERSIONED")
if normalised == "enabled":
    emit("ENABLED")
if normalised == "suspended":
    emit("SUSPENDED")
emit("UNKNOWN:" + (status or "").strip())
PY
  ) || {
    rm -f "$raw_file"
    m8_oss_die 'bucket versioning response could not be classified; refusing any PutObject'
    return 1
  }
  rm -f "$raw_file"

  case "$verdict" in
    UNVERSIONED)
      if [[ "$evidence" != '-' ]]; then
        printf 'bucket_versioning=UNVERSIONED\n' >> "$evidence/oss-versioning-guard.txt"
      fi
      return 0
      ;;
    ENABLED)
      classification='versioning Enabled'
      ;;
    SUSPENDED)
      classification='versioning Suspended'
      ;;
    UNPARSEABLE)
      classification='unparseable versioning response'
      ;;
    UNKNOWN:*)
      classification="unknown versioning status '${verdict#UNKNOWN:}'"
      ;;
    *)
      classification="unexpected versioning verdict '$verdict'"
      ;;
  esac

  if [[ "$evidence" != '-' ]]; then
    printf 'bucket_versioning=REJECTED:%s\n' "$classification" >> "$evidence/oss-versioning-guard.txt"
  fi
  m8_oss_die "bucket is not eligible for create-if-absent writes: $classification"
  return 1
}

# Did the ossutil output indicate that the object already exists?
m8_oss_output_is_already_exists() {
  grep -Eiq 'FileAlreadyExists|ObjectAlreadyExists|(^|[^0-9])409([^0-9]|$)' <<<"$1"
}

m8_oss_output_is_absent() {
  grep -Eiq 'NoSuchKey|NoSuchObject|SymlinkTargetNotExist|NotFound|(^|[^0-9])404([^0-9]|$)' <<<"$1"
}

# ---------------------------------------------------------------------------
# Atomic create-if-absent upload (spec section 6).
#
#   m8_oss_put_object_no_overwrite <key> <local_file> [evidence_log]
#
# Returns M8_OSS_OK on create, M8_OSS_EXISTS when the object already existed
# (never overwritten), M8_OSS_ERROR on any other failure.
# ---------------------------------------------------------------------------
m8_oss_put_object_no_overwrite() {
  local key=$1 file=$2 log=${3:-'-'} output='' rc=0
  m8_oss_require_config || return "$M8_OSS_ERROR"
  [[ -n "$key" ]] || { m8_oss_die 'object key is empty'; return "$M8_OSS_ERROR"; }
  [[ -f "$file" ]] || { m8_oss_die "upload body is not a regular file: $file"; return "$M8_OSS_ERROR"; }

  # Official ossutil PutObject file-body form. The bare path is NOT the file
  # body form: an absolute path such as /tmp/foo.tar.gz must be presented as
  # file:///tmp/foo.tar.gz. --forbid-overwrite true keeps the no-overwrite model.
  output=$(m8_oss_api put-object \
    --bucket "$(m8_oss_bucket)" \
    --key "$key" \
    --body "file://$file" \
    --forbid-overwrite true 2>&1) || rc=$?

  if [[ "$log" != '-' ]]; then
    {
      printf 'put_object key=%s rc=%s\n' "$key" "$rc"
      printf '%s\n' "$output"
    } >> "$log"
  fi

  if (( rc == 0 )); then
    return "$M8_OSS_OK"
  fi
  if m8_oss_output_is_already_exists "$output"; then
    return "$M8_OSS_EXISTS"
  fi
  m8_oss_die "put-object failed for $key (rc=$rc): $(printf '%s' "$output" | head -c 400)"
  return "$M8_OSS_ERROR"
}

# ---------------------------------------------------------------------------
# Existence probe. Returns M8_OSS_OK (exists), M8_OSS_ABSENT, or M8_OSS_ERROR.
# Never mutates. ETag is deliberately not interpreted as a content digest.
# ---------------------------------------------------------------------------
m8_oss_object_probe() {
  local key=$1 log=${2:-'-'} output='' rc=0
  m8_oss_require_config || return "$M8_OSS_ERROR"
  output=$(m8_oss_api head-object --bucket "$(m8_oss_bucket)" --key "$key" 2>&1) || rc=$?
  if [[ "$log" != '-' ]]; then
    {
      printf 'head_object key=%s rc=%s\n' "$key" "$rc"
      printf '%s\n' "$output"
    } >> "$log"
  fi
  if (( rc == 0 )); then
    return "$M8_OSS_OK"
  fi
  if m8_oss_output_is_absent "$output"; then
    return "$M8_OSS_ABSENT"
  fi
  m8_oss_die "head-object failed for $key (rc=$rc): $(printf '%s' "$output" | head -c 400)"
  return "$M8_OSS_ERROR"
}

# ---------------------------------------------------------------------------
# Byte-exact object download. The caller is responsible for digest/size
# verification; this function only guarantees the local file was written
# successfully.
# ---------------------------------------------------------------------------
m8_oss_get_object() {
  local key=$1 out=$2 log=${3:-'-'} rc=0 tmp output_flag=''
  m8_oss_require_config || return "$M8_OSS_ERROR"
  [[ -n "$out" ]] || { m8_oss_die 'get-object destination is empty'; return "$M8_OSS_ERROR"; }

  tmp="${out}.part"
  rm -f "$tmp"
  output_flag="${M8_OSSUTIL_GET_OUTPUT_FLAG:-}"

  if [[ -n "$output_flag" ]]; then
    if ! m8_oss_api get-object --bucket "$(m8_oss_bucket)" --key "$key" \
      "$output_flag" "$tmp" >"${tmp}.stdout" 2>&1; then
      rc=1
    fi
  else
    if ! m8_oss_api get-object --bucket "$(m8_oss_bucket)" --key "$key" >"$tmp" 2>"${tmp}.stderr"; then
      rc=1
    fi
  fi

  if [[ "$log" != '-' ]]; then
    {
      printf 'get_object key=%s rc=%s bytes=%s\n' "$key" "$rc" \
        "$([[ -f "$tmp" ]] && wc -c <"$tmp" || printf 0)"
      [[ -f "${tmp}.stderr" ]] && cat "${tmp}.stderr"
      [[ -f "${tmp}.stdout" ]] && cat "${tmp}.stdout"
    } >> "$log"
  fi

  if (( rc != 0 )); then
    local diagnosis=''
    [[ -f "${tmp}.stderr" ]] && diagnosis="$(cat "${tmp}.stderr" 2>/dev/null || printf '')"
    rm -f "$tmp" "${tmp}.stderr" "${tmp}.stdout"
    if m8_oss_output_is_absent "$diagnosis"; then
      return "$M8_OSS_ABSENT"
    fi
    return "$M8_OSS_ERROR"
  fi

  rm -f "${tmp}.stderr" "${tmp}.stdout"
  mv -f "$tmp" "$out" || return "$M8_OSS_ERROR"
  return "$M8_OSS_OK"
}

# ---------------------------------------------------------------------------
# Read-back verification of an uploaded object against locally expected bytes.
#
#   m8_oss_verify_object <key> <expected_file> [evidence_log]
#
# Downloads the object and requires the fetched bytes' SHA-256 and size to equal
# the local file's. Never trusts ETag as a content digest.
# ---------------------------------------------------------------------------
m8_oss_verify_object() {
  local key=$1 expected=$2 log=${3:-'-'} fetched='' rc=0
  local expected_sha expected_size fetched_sha fetched_size
  fetched=$(mktemp "${TMPDIR:-/tmp}/m8-oss-readback.XXXXXX")

  # Capture the real return code (a leading `!` would invert it).
  m8_oss_get_object "$key" "$fetched" "$log" || rc=$?
  if (( rc != 0 )); then
    rm -f "$fetched"
    if (( rc == M8_OSS_ABSENT )); then
      m8_oss_die "read-back failed: object is absent: $key"
    else
      m8_oss_die "read-back failed: object could not be fetched: $key"
    fi
    return "$M8_OSS_ERROR"
  fi

  expected_sha=$(sha256sum "$expected" | cut -d' ' -f1)
  fetched_sha=$(sha256sum "$fetched" | cut -d' ' -f1)
  expected_size=$(wc -c <"$expected")
  fetched_size=$(wc -c <"$fetched")

  if [[ "$expected_sha" != "$fetched_sha" || "$expected_size" != "$fetched_size" ]]; then
    rm -f "$fetched"
    m8_oss_die "read-back digest mismatch for $key (expected $expected_sha/$expected_size; got $fetched_sha/$fetched_size)"
    return "$M8_OSS_ERROR"
  fi

  if [[ "$log" != '-' ]]; then
    {
      printf 'readback key=%s sha256=%s size=%s status=MATCH\n' "$key" "$fetched_sha" "$expected_size"
    } >> "$log"
  fi

  rm -f "$fetched"
  return "$M8_OSS_OK"
}
