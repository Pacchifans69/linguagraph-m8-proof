#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 shared Alibaba ECS provider identity authority.
#
# This file is the SINGLE SOURCE OF TRUTH for the reviewed immutable execution
# identity of the M8 hosted proof host. It is sourced (never executed) by:
#
#   scripts/run-m8-proof.sh                 pre-claim provider identity verification
#   scripts/run-m8-proof-alibaba-ecs.sh     post-claim defence-in-depth re-verification
#   scripts/preflight-m8-alibaba-ecs.sh     read-only discovery / binding report
#
# Contract:
#   * read-only IMDS access only (no provider mutation, no credential provisioning);
#   * no independent duplicate copies of these constants anywhere else in the repo;
#   * the reviewed tuple may only be changed by a separately authorized Human
#     provider re-binding, never by a runtime value.
#
# The functions here are pure with respect to provider state. Only
# m8_provider_identity_verify() writes, and it writes exclusively inside the
# caller-supplied evidence capture directory.

if [[ -n "${M8_PROVIDER_IDENTITY_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
M8_PROVIDER_IDENTITY_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Reviewed immutable provider tuple (established by the read-only M8 provider
# preflight; recorded in README.md).
# ---------------------------------------------------------------------------
readonly EXPECTED_INSTANCE_ID='i-j6c9854oyawy89fcdxy2'
readonly EXPECTED_REGION_ID='cn-hongkong'
readonly EXPECTED_ZONE_ID='cn-hongkong-d'
readonly EXPECTED_INSTANCE_TYPE='ecs.g9i.xlarge'
readonly EXPECTED_IMAGE_ID='ubuntu_24_04_x64_20G_alibase_20260916.vhd'
readonly EXPECTED_IDENTITY_DOCUMENT_SHA256='60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d'
readonly EXPECTED_IDENTITY_PKCS7_SHA256='89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211'

readonly M8_PROVIDER_BINDING_READY='YES'
readonly M8_PROVIDER_EXECUTOR_ID="alibaba-ecs:${EXPECTED_INSTANCE_ID}"

readonly M8_IMDS_DEFAULT_BASE='http://100.100.100.200/latest'
readonly M8_IMDS_TOKEN_TTL_DEFAULT='21600'

m8_provider_die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
m8_provider_expect() {
  [[ "$1" == "$2" ]] || { m8_provider_die "Mismatch: $3 (expected $2; got $1)"; return 1; }
}

# ---------------------------------------------------------------------------
# Configuration seams.
#
# M8_IMDS_BASE_URL / M8_IMDS_CURL_BIN exist so that offline synthetic tests can
# drive the same code paths without touching a real metadata service. Formal
# execution never sets them; the wrapper records them in provenance so a
# redirected metadata source is always visible in evidence.
# ---------------------------------------------------------------------------
m8_imds_base_url() { printf '%s' "${M8_IMDS_BASE_URL:-$M8_IMDS_DEFAULT_BASE}"; }
m8_imds_curl_bin() { printf '%s' "${M8_IMDS_CURL_BIN:-curl}"; }
m8_imds_token_ttl() { printf '%s' "${M8_IMDS_TOKEN_TTL:-$M8_IMDS_TOKEN_TTL_DEFAULT}"; }

m8_provider_identity_executor_id() { printf '%s' "$M8_PROVIDER_EXECUTOR_ID"; }

# Fail closed unless the reviewed tuple is fully bound (no placeholder values).
m8_provider_binding_ready() {
  [[ "$M8_PROVIDER_BINDING_READY" == 'YES' ]] || { m8_provider_die 'M8 Alibaba provider binding is not established'; return 1; }
  local name value
  for name in EXPECTED_INSTANCE_ID EXPECTED_REGION_ID EXPECTED_ZONE_ID \
    EXPECTED_INSTANCE_TYPE EXPECTED_IMAGE_ID \
    EXPECTED_IDENTITY_DOCUMENT_SHA256 EXPECTED_IDENTITY_PKCS7_SHA256; do
    value="${!name}"
    [[ -n "$value" && "$value" != 'UNBOUND' && "$value" != 'unbound' ]] || { m8_provider_die "$name is unbound"; return 1; }
  done
  [[ "$EXPECTED_IDENTITY_DOCUMENT_SHA256" =~ ^[0-9a-f]{64}$ ]] || { m8_provider_die 'EXPECTED_IDENTITY_DOCUMENT_SHA256 is not a SHA-256'; return 1; }
  [[ "$EXPECTED_IDENTITY_PKCS7_SHA256" =~ ^[0-9a-f]{64}$ ]] || { m8_provider_die 'EXPECTED_IDENTITY_PKCS7_SHA256 is not a SHA-256'; return 1; }
}

# Emit the expected tuple as deterministic key=value lines.
m8_provider_identity_expected_lines() {
  printf 'instance_id=%s\n' "$EXPECTED_INSTANCE_ID"
  printf 'region_id=%s\n' "$EXPECTED_REGION_ID"
  printf 'zone_id=%s\n' "$EXPECTED_ZONE_ID"
  printf 'instance_type=%s\n' "$EXPECTED_INSTANCE_TYPE"
  printf 'image_id=%s\n' "$EXPECTED_IMAGE_ID"
  printf 'identity_document_sha256=%s\n' "$EXPECTED_IDENTITY_DOCUMENT_SHA256"
  printf 'identity_pkcs7_sha256=%s\n' "$EXPECTED_IDENTITY_PKCS7_SHA256"
}

# ---------------------------------------------------------------------------
# Read-only IMDS access.
# ---------------------------------------------------------------------------
m8_imds_plain_status() {
  local rel=$1
  "$(m8_imds_curl_bin)" --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 5 "$(m8_imds_base_url)/$rel"
}

m8_imds_obtain_token() {
  "$(m8_imds_curl_bin)" --fail --silent --show-error --max-time 5 -X PUT \
    -H "X-aliyun-ecs-metadata-token-ttl-seconds: $(m8_imds_token_ttl)" \
    "$(m8_imds_base_url)/api/token"
}

m8_imds_get() {
  local token=$1 rel=$2
  "$(m8_imds_curl_bin)" --fail --silent --show-error --max-time 5 \
    -H "X-aliyun-ecs-metadata-token: $token" \
    "$(m8_imds_base_url)/$rel"
}

# Capture a single optional IMDS value; absence is recorded, never fatal.
m8_imds_capture() {
  local token=$1 rel=$2 out=$3 value=''
  if value=$(m8_imds_get "$token" "$rel" 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s\n' "$value" > "$out"
  else
    printf 'unavailable\n' > "$out"
  fi
}

# ---------------------------------------------------------------------------
# R2I-C7: binary-safe immutable provider-identity inputs.
#
# The seven immutable inputs (instance-id, region-id, zone-id, instance-type,
# image-id, the instance identity document and the PKCS7) are raw IMDS bodies.
# A Bash variable cannot preserve a NUL byte, so capturing a body with $(...)
# silently DELETES every NUL and can normalise a malformed response into the
# frozen expected value -- e.g. "cn-\0hongkong" becomes "cn-hongkong", which
# equals EXPECTED_REGION_ID. Byte loss is therefore NOT a fail-closed event.
#
# Every immutable body now flows:
#
#   IMDS stdout -> scratch file -> Python byte classifier -> validated value
#
# and no raw body is ever materialised in a shell variable. Only the validated
# scalar (or the canonical digest) leaves the classifier, and only the IMDS
# token, scratch paths and numeric RCs are held in shell variables.
#
# Distinct exit codes let the instance-type fallback distinguish "the primary
# request failed" (fallback is allowed) from "the primary response was malformed"
# (fallback is FORBIDDEN; fail closed).
# ---------------------------------------------------------------------------
readonly M8_PROVIDER_SCALAR_OK=0
readonly M8_PROVIDER_SCALAR_REQUEST_FAILED=20
readonly M8_PROVIDER_SCALAR_INVALID=21

# Raw-to-file primitive: the response body goes straight from the configured
# IMDS client's stdout into OUTPUT_FILE. It is never stored in a variable, never
# printed, and no repository/evidence/host-state path is written.
m8_imds_get_to_file() {
  local token=$1 rel=$2 out=$3
  "$(m8_imds_curl_bin)" --fail --silent --show-error --max-time 5 \
    -H "X-aliyun-ecs-metadata-token: $token" \
    "$(m8_imds_base_url)/$rel" >"$out"
}

# One shared byte classifier for all seven immutable inputs.
#
#   m8_provider_bytes_classify scalar <raw_file>
#       prints the validated scalar (terminal LF removed, no other stripping)
#   m8_provider_bytes_classify digest <raw_file> <capture|->
#       prints SHA256 of the canonical bytes and optionally writes them
#
# The program is supplied on stdin, so both the payload and the capture path are
# passed as arguments: nothing is piped into the interpreter.
m8_provider_bytes_classify() {
  local mode=$1 raw_file=$2 capture=${3:-'-'}
  "$(m8_python_bin)" - "$mode" "$raw_file" "$capture" <<'PY'
import hashlib
import sys

mode, raw_path, capture = sys.argv[1:4]

with open(raw_path, "rb") as handle:
    raw = handle.read()


def fail(message):
    sys.stderr.write('FAIL: %s\n' % message)
    raise SystemExit(1)


# --- rejected BEFORE any normalisation, for every mode ---------------------
if b"\x00" in raw:
    fail(
        'Alibaba IMDS response contains %d NUL byte(s); refusing lossy '
        'shell-variable normalisation' % raw.count(b"\x00")
    )

if mode == "scalar":
    # Reproduce ONLY the terminal-newline behaviour of the former command
    # substitution: strip trailing LFs, then require a single logical line.
    canonical = raw.rstrip(b"\n")
    if b"\n" in canonical:
        fail('Alibaba IMDS response contains an embedded line feed')
    if b"\r" in canonical:
        fail('Alibaba IMDS response contains a CR byte')
    try:
        text = canonical.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail('Alibaba IMDS response is not valid UTF-8: %s' % exc)
    if text == "":
        fail('Alibaba IMDS response is an empty scalar')
    for character in text:
        if ord(character) < 0x20 or ord(character) == 0x7F:
            fail('Alibaba IMDS response contains a control character')
    sys.stdout.write(text)
    raise SystemExit(0)

if mode == "digest":
    # Frozen digest contract: canonical = trailing LFs removed + exactly one LF.
    # This is byte-identical to the former `printf '%s\n' "$(get)" | sha256sum`.
    canonical = raw.rstrip(b"\n")
    if canonical == b"":
        fail('Alibaba IMDS response is empty')
    payload = canonical + b"\n"
    if capture != "-":
        with open(capture, "wb") as handle:
            handle.write(payload)
    sys.stdout.write(hashlib.sha256(payload).hexdigest() + "\n")
    raise SystemExit(0)

fail('unknown byte-classifier mode: %r' % mode)
PY
}

# Read one immutable scalar. Prints the validated scalar on stdout and returns
# M8_PROVIDER_SCALAR_REQUEST_FAILED / M8_PROVIDER_SCALAR_INVALID on failure, so
# the caller can tell a transport failure from a malformed response. The scratch
# file is removed on every path.
m8_provider_identity_scalar_read() {
  local token=$1 rel=$2
  local raw_file='' rc=0 scalar=''
  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-provider-scalar.XXXXXX") || {
    m8_provider_die 'cannot create a scratch file for the immutable identity response'
    return "$M8_PROVIDER_SCALAR_INVALID"
  }
  if ! m8_imds_get_to_file "$token" "$rel" "$raw_file"; then
    rm -f "$raw_file"
    return "$M8_PROVIDER_SCALAR_REQUEST_FAILED"
  fi
  scalar="$(m8_provider_bytes_classify scalar "$raw_file")" || rc=$?
  rm -f "$raw_file"
  (( rc == 0 )) || return "$M8_PROVIDER_SCALAR_INVALID"
  printf '%s' "$scalar"
  return 0
}

# Read one immutable binary document. Prints its canonical SHA-256 on stdout and,
# when CAPTURE is not '-', writes the exact canonical bytes there. The scratch
# file is removed on every path.
m8_provider_identity_digest_read() {
  local token=$1 rel=$2 capture=$3
  local raw_file='' rc=0 digest=''
  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-provider-document.XXXXXX") || {
    m8_provider_die 'cannot create a scratch file for the immutable identity response'
    return 1
  }
  if ! m8_imds_get_to_file "$token" "$rel" "$raw_file"; then
    rm -f "$raw_file"
    m8_provider_die "Alibaba IMDS request failed: $rel"
    return 1
  fi
  digest="$(m8_provider_bytes_classify digest "$raw_file" "$capture")" || rc=$?
  rm -f "$raw_file"
  (( rc == 0 )) || return 1
  printf '%s\n' "$digest"
  return 0
}

# ---------------------------------------------------------------------------
# Pure tuple comparison. No I/O, no writes: the reviewed constants are compared
# to caller-supplied observed values. Used directly by offline synthetic tests.
# ---------------------------------------------------------------------------
m8_provider_identity_assert() {
  local instance_id=$1 region=$2 zone=$3 itype=$4 image=$5 doc_sha=$6 pkcs7_sha=$7
  m8_provider_binding_ready
  m8_provider_expect "$instance_id" "$EXPECTED_INSTANCE_ID" provider_instance_id || return 1
  m8_provider_expect "$region" "$EXPECTED_REGION_ID" provider_region_id || return 1
  m8_provider_expect "$zone" "$EXPECTED_ZONE_ID" provider_zone_id || return 1
  m8_provider_expect "$itype" "$EXPECTED_INSTANCE_TYPE" provider_instance_type || return 1
  m8_provider_expect "$image" "$EXPECTED_IMAGE_ID" provider_image_id || return 1
  m8_provider_expect "$doc_sha" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" provider_identity_document_sha256 || return 1
  m8_provider_expect "$pkcs7_sha" "$EXPECTED_IDENTITY_PKCS7_SHA256" provider_identity_pkcs7_sha256 || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Full read-only verification.
#
# m8_provider_identity_verify <capture_dir|-> [label]
#
#   capture_dir  directory receiving raw observed values and their digests
#                ('-' disables capture)
#   label        optional sub-directory name for the capture (used for the
#                post-claim defence-in-depth second pass)
#
# Returns 0 only when the observed live tuple AND both identity digests match the
# reviewed constants exactly.
# ---------------------------------------------------------------------------
m8_provider_identity_verify() {
  local capture_dir=${1:-'-'} label=${2:-primary}
  local target='' token='' status='' itype_rc=0
  local instance_id region zone itype image mac
  local doc_sha='' pkcs7_sha=''
  local document_capture='-' pkcs7_capture='-'

  m8_provider_binding_ready

  if [[ "$capture_dir" != '-' ]]; then
    target="$capture_dir/$label"
    mkdir -p "$target" || { m8_provider_die "cannot create identity capture directory $target"; return 1; }
  fi

  status=$(m8_imds_plain_status meta-data/instance-id) || { m8_provider_die 'Alibaba IMDS tokenless probe failed'; return 1; }
  m8_provider_expect "$status" '403' imds_tokenless_instance_id_http_status || return 1

  token=$(m8_imds_obtain_token) || { m8_provider_die 'Alibaba IMDS token mode request failed'; return 1; }
  [[ -n "$token" ]] || { m8_provider_die 'Alibaba IMDS token mode returned an empty token'; return 1; }

  # R2I-C7: every immutable input is read byte-safely. The raw response body is
  # never materialised in a shell variable; only the validated scalar leaves the
  # classifier, and a NUL anywhere fails closed before terminal-LF normalisation.
  instance_id=$(m8_provider_identity_scalar_read "$token" meta-data/instance-id) ||
    { m8_provider_die 'Alibaba IMDS token-mode instance-id read failed (byte-safe)'; return 1; }
  region=$(m8_provider_identity_scalar_read "$token" meta-data/region-id) ||
    { m8_provider_die 'Alibaba IMDS region-id read failed (byte-safe)'; return 1; }
  zone=$(m8_provider_identity_scalar_read "$token" meta-data/zone-id) ||
    { m8_provider_die 'Alibaba IMDS zone-id read failed (byte-safe)'; return 1; }

  # Instance type: the fallback endpoint is used ONLY when the primary REQUEST
  # failed. A primary response that arrived but was malformed fails closed and
  # never falls back.
  itype=''
  itype_rc=0
  itype=$(m8_provider_identity_scalar_read "$token" meta-data/instance/instance-type) || itype_rc=$?
  if (( itype_rc == M8_PROVIDER_SCALAR_REQUEST_FAILED )); then
    itype_rc=0
    itype=$(m8_provider_identity_scalar_read "$token" meta-data/instance-type) || itype_rc=$?
  fi
  (( itype_rc == 0 )) ||
    { m8_provider_die 'Alibaba IMDS instance-type read failed (byte-safe)'; return 1; }

  image=$(m8_provider_identity_scalar_read "$token" meta-data/image-id) ||
    { m8_provider_die 'Alibaba IMDS image-id read failed (byte-safe)'; return 1; }

  # The identity document and PKCS7 are canonicalised and digested from the raw
  # scratch file. With capture enabled the classifier writes the exact canonical
  # bytes into the evidence file, preserving the pre-C7 digest contract.
  if [[ "$capture_dir" != '-' ]]; then
    document_capture="$target/instance-identity-document.json"
    pkcs7_capture="$target/instance-identity-pkcs7.txt"
  fi
  doc_sha=$(m8_provider_identity_digest_read "$token" dynamic/instance-identity/document "$document_capture") ||
    { m8_provider_die 'Alibaba instance identity document read failed (byte-safe)'; return 1; }
  pkcs7_sha=$(m8_provider_identity_digest_read "$token" dynamic/instance-identity/pkcs7 "$pkcs7_capture") ||
    { m8_provider_die 'Alibaba instance identity PKCS7 read failed (byte-safe)'; return 1; }

  if [[ "$capture_dir" != '-' ]]; then
    printf '%s\n' "$instance_id" > "$target/instance-id.txt"
    printf '%s\n' "$region" > "$target/region-id.txt"
    printf '%s\n' "$zone" > "$target/zone-id.txt"
    printf '%s\n' "$itype" > "$target/instance-type.txt"
    printf '%s\n' "$image" > "$target/image-id.txt"
    m8_imds_capture "$token" meta-data/instance/instance-name "$target/instance-name.txt"
    m8_imds_capture "$token" meta-data/hostname "$target/hostname.txt"
    m8_imds_capture "$token" meta-data/serial-number "$target/serial-number.txt"
    m8_imds_capture "$token" meta-data/vpc-id "$target/vpc-id.txt"
    m8_imds_capture "$token" meta-data/vswitch-id "$target/vswitch-id.txt"
    m8_imds_capture "$token" meta-data/private-ipv4 "$target/private-ipv4.txt"
    m8_imds_capture "$token" meta-data/public-ipv4 "$target/public-ipv4.txt"
    m8_imds_capture "$token" meta-data/eipv4 "$target/eipv4.txt"
    m8_imds_capture "$token" meta-data/mac "$target/primary-mac.txt"
    mac=$(cat "$target/primary-mac.txt" 2>/dev/null || printf '')
    if [[ -n "$mac" && "$mac" != 'unavailable' ]]; then
      m8_imds_capture "$token" \
        "meta-data/network/interfaces/macs/$mac/network-interface-id" "$target/primary-eni.txt"
      m8_imds_capture "$token" \
        "meta-data/network/interfaces/macs/$mac/primary-ip-address" "$target/primary-eni-private-ipv4.txt"
    else
      printf 'unavailable\n' > "$target/primary-eni.txt"
      printf 'unavailable\n' > "$target/primary-eni-private-ipv4.txt"
    fi
  fi

  m8_provider_identity_assert \
    "$instance_id" "$region" "$zone" "$itype" "$image" "$doc_sha" "$pkcs7_sha" ||
    return 1

  if [[ "$capture_dir" != '-' ]]; then
    printf '%s\n' "$doc_sha" > "$target/instance-identity-document.sha256"
    printf '%s\n' "$pkcs7_sha" > "$target/instance-identity-pkcs7.sha256"
    {
      printf 'observed_utc=%s\n' "$(date -u +%FT%TZ)"
      printf 'imds_endpoint=%s\n' "$(m8_imds_base_url)"
      printf 'imds_tokenless_instance_id_http_status=%s\n' "$status"
      printf 'imds_token_mode=successful\n'
      m8_provider_identity_expected_lines
      printf 'note=public IP, ENI, hostname, kernel and boot observations are provenance, not immutable execution identity\n'
    } > "$target/provider-identity-result.txt"
  fi

  return 0
}

# Read-only discovery report for the preflight: prints observed values and the
# match/mismatch verdict for each element of the reviewed tuple. Never fails on
# mismatch by itself; the caller decides.
m8_provider_identity_report() {
  local capture_dir=${1:-'-'}
  if m8_provider_identity_verify "$capture_dir" preflight; then
    printf 'provider_identity_match=PASS\n'
  else
    printf 'provider_identity_match=FAIL\n'
    return 1
  fi
}

# ---------------------------------------------------------------------------
# R2I-C4 / B03: read-only observation of the ECS instance RAM role NAME.
#
# Only the role-name LIST endpoint is queried:
#
#   meta-data/ram/security-credentials/
#
# The per-role endpoint meta-data/ram/security-credentials/<role-name> RETURNS
# TEMPORARY CREDENTIALS (AccessKeyId / AccessKeySecret / SecurityToken) and is
# therefore never requested here. No credential payload is read, printed or
# persisted; only the non-secret role name is emitted.
#
# Fail-closed conditions: token failure, HTTP failure, empty response, more than
# one role name, or any CR/NUL/control-character ambiguity.
# ---------------------------------------------------------------------------
readonly M8_IMDS_ECS_ROLE_LIST_REL='meta-data/ram/security-credentials/'

# Self-contained interpreter resolution for offline direct-function tests that
# source only this library. The canonical definition lives in m8-manifest.sh /
# m8-oss.sh and is reused whenever it is already loaded.
if ! declare -F m8_python_bin >/dev/null 2>&1; then
  m8_python_bin() { printf '%s' "${M8_PYTHON_BIN:-python3}"; }
fi

m8_provider_identity_observe_ecs_role_name() {
  local token='' raw_file=''
  m8_provider_binding_ready || return 1

  token=$(m8_imds_obtain_token) || { m8_provider_die 'Alibaba IMDS token mode request failed'; return 1; }
  [[ -n "$token" ]] || { m8_provider_die 'Alibaba IMDS token mode returned an empty token'; return 1; }

  # R2I-C6: the raw LIST body is binary-unsafe in Bash. A shell variable cannot
  # preserve a NUL byte, so capturing the response with $(...) and re-printing it
  # silently normalises "RoleA\0RoleB\n" into a single "RoleARoleB\n" BEFORE the
  # byte classifier runs, converting a must-fail-closed response into an accepted
  # role. The raw bytes therefore flow straight from the IMDS client's stdout
  # into a scratch file and are classified from that file; no raw-response shell
  # variable is ever materialised.
  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-ecs-role.XXXXXX") || {
    token=''
    m8_provider_die 'cannot create a scratch file for the role-name response'
    return 1
  }

  # LIST endpoint only: this response contains role NAMES, never credentials.
  if ! m8_imds_get "$token" "$M8_IMDS_ECS_ROLE_LIST_REL" >"$raw_file"; then
    token=''
    rm -f "$raw_file"
    m8_provider_die 'Alibaba IMDS role-name list request failed'
    return 1
  fi
  token=''

  # The classifier program is supplied on stdin, so the raw response is passed as
  # a file argument rather than piped (a pipe would be consumed by the
  # interpreter reading the program itself).
  local rc=0
  "$(m8_python_bin)" - "$raw_file" <<'PY' || rc=$?
import sys

with open(sys.argv[1], "rb") as handle:
    raw = handle.read()

def fail(message):
    sys.stderr.write('FAIL: %s\n' % message)
    raise SystemExit(1)

if b"\x00" in raw:
    fail('ECS role-name response contains a NUL byte')
if b"\r" in raw:
    fail('ECS role-name response contains a CR byte')
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError as exc:
    fail('ECS role-name response is not valid UTF-8: %s' % exc)
if any(ord(character) < 0x20 for character in text.replace("\n", "")):
    fail('ECS role-name response contains a control character')

names = [line.strip() for line in text.split("\n")]
names = [name for name in names if name]
if not names:
    fail('ECS instance has no attached RAM role (empty role-name list)')
if len(names) > 1:
    fail('ECS instance reports %d RAM roles; exactly one is required' % len(names))
name = names[0]
if any(character.isspace() for character in name):
    fail('ECS role name contains whitespace')
if name in ('.', '..') or '/' in name or '\\' in name:
    fail('ECS role name is not a plain role name: %r' % name)
sys.stdout.write(name + "\n")
PY
  # The scratch file is removed on classifier PASS and on classifier FAIL.
  rm -f "$raw_file"
  return "$rc"
}
