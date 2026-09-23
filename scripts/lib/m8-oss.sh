#!/usr/bin/env bash
# shellcheck shell=bash
# LinguaGraph M8 durable-evidence OSS client.
#
# Contract (R2B + R2I-C4/B03):
#   * official `ossutil api <operation>` commands ONLY;
#   * no custom OSS request signing, no Alibaba OSS SDK dependency;
#   * the proof harness NEVER installs ossutil (host provisioning supplies it);
#   * every network-capable invocation carries the five CLI-pinned global flags:
#     --config-file <proof-tree IMDSv2 role-bound config>  --region cn-hongkong
#     --endpoint https://oss-cn-hongkong-internal.aliyuncs.com
#     --addressing-style virtual  --ignore-env-var
#     There is NO CLI --mode and NO CLI --ecs-role-name: ossutil 2.4.0 rejects
#     "unknown flag: --ecs-role-name" and refuses Ali-EcsRamRole via CLI --mode.
#     The ECS role binding lives in the proof-tree canonical config and is
#     cross-bound against a FRESH IMDSv2 role-name observation (durable provider
#     helper) before every network-capable call;
#     never --skip-verify-cert, never AK/STS/RamRoleArn credential flags;
#   * the official ossutil Ali-EcsRamRole credential provider MAY internally
#     retrieve temporary credentials through IMDSv2. Our harness never prints,
#     persists or places those credential values in evidence, and never supplies
#     AK/SK/STS credential flags;
#   * ambient config selection is impossible: M8_OSSUTIL_CONFIG_FILE is rejected
#     by the closed trust-environment guard and is never consumed here, and the
#     default ~/.ossutilconfig is never relied upon;
#   * every canonical object is created with atomic create-if-absent
#     (put-object ... --forbid-overwrite true), never HEAD-then-unconditional-PUT;
#   * every PutObject body uses the official file form `--body file://<path>`;
#     a bare local path is never passed as a body;
#   * GetObject stays byte-exact: the response body goes straight from ossutil
#     stdout into a file, never through shell command substitution or a variable;
#   * bucket location must be cn-hongkong and bucket versioning must be
#     unversioned before any PutObject; the harness has no PutBucketVersioning
#     authority;
#   * existing objects are never overwritten and ETag is never treated as SHA-256.
#
# Configuration:
#   M8_OSS_BUCKET                required canonical bucket name
#   M8_OSSUTIL_BIN               offline synthetic stub ONLY (rejected in
#                                production by the C1 seam guard)
#   M8_OSS_ECS_ROLE_NAME         runtime observed ECS RAM role name (never a
#                                caller-selected override in production)
#   M8_OSSUTIL_GET_OUTPUT_FLAG   synthetic response-body flag for get-object
#                                (rejected in production by the C1 seam guard)
#
# Return codes:
#   M8_OSS_OK=0  M8_OSS_EXISTS=10  M8_OSS_ERROR=11  M8_OSS_ABSENT=12

readonly M8_OSS_OK=0
readonly M8_OSS_EXISTS=10
readonly M8_OSS_ERROR=11
readonly M8_OSS_ABSENT=12

# --- R2I-C4 frozen trust constants (from the Human contract) -----------------
readonly M8_OSS_TRUST_PROFILE_SCHEMA='linguagraph-m8-oss-trust-profile/v1'
readonly M8_OSS_REGION='cn-hongkong'
readonly M8_OSS_ENDPOINT='https://oss-cn-hongkong-internal.aliyuncs.com'
readonly M8_OSS_ENDPOINT_CLASS='INTERNAL'
readonly M8_OSS_NETWORK_POLICY='SAME_REGION_INTERNAL_ONLY'
readonly M8_OSS_ADDRESSING_STYLE='virtual'
# R2I-C11: the CLI --mode / --ecs-role-name flags are NOT supported by ossutil
# 2.4.0 (live: "unknown flag: --ecs-role-name" and CLI --mode rejects
# Ali-EcsRamRole). The role binding therefore lives in the proof-tree canonical
# config and is cross-bound against a fresh IMDSv2 role-name observation.
readonly M8_OSS_AUTH_MODE='Ali-EcsRamRole'
readonly M8_OSS_TLS_VERIFICATION='required'
readonly M8_OSS_CONFIG_RELPATH='scripts/config/m8-ossutil-formal.ini'
readonly M8_OSS_CONFIG_PROFILE='default'
readonly M8_OSS_CONFIG_POLICY_ID='m8-proof-tree-imdsv2-role-config/v1'
readonly M8_OSS_ENV_POLICY_ID='m8-oss-env-closed/v1'
readonly M8_OSS_IGNORE_ENV_VARS='true'
readonly M8_OSS_CONFIG_SHA256='43b384710e4d0944fa3fea3f4daf4dcaba280739cc40d9c31bdbd6c54772c47a'
readonly M8_OSS_CONFIG_BYTES='81'
readonly M8_OSS_MIN_VERSION='2.2.0'
readonly M8_OSS_BUCKET_LOCATION='oss-cn-hongkong'

m8_python_bin() { printf '%s' "${M8_PYTHON_BIN:-python3}"; }

m8_oss_die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }

m8_oss_bucket() { printf '%s' "${M8_OSS_BUCKET:-}"; }
m8_ossutil_bin() { printf '%s' "${M8_OSSUTIL_BIN:-ossutil}"; }
m8_oss_ecs_role_name() { printf '%s' "${M8_OSS_ECS_ROLE_NAME:-}"; }

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

# --- canonical proof-tree IMDSv2 role-bound configuration identity ----------
m8_oss_proof_root() {
  local root=${M8_PROOF_ROOT:-}
  [[ -n "$root" ]] || { m8_oss_die 'M8_PROOF_ROOT is not set; cannot resolve the canonical OSS config'; return 1; }
  printf '%s' "$root"
}

m8_oss_canonical_config_path() {
  local root
  root=$(m8_oss_proof_root) || return 1
  printf '%s/%s' "$root" "$M8_OSS_CONFIG_RELPATH"
}

# Fail closed unless the canonical proof-tree config is an exact, regular,
# in-worktree file with the reviewed byte identity. There is no fallback to
# ~/.ossutilconfig, OSSUTIL_CONFIG_FILE or any caller-selected profile.
#
# R2I-C11: the config is no longer "inert" -- it carries the role binding that
# the ossutil 2.4.0 CLI cannot express as a flag. The guard therefore also
# establishes and exposes the canonical auth mode and role name.
m8_oss_canonical_config_guard() {
  local root config size sha
  root=$(m8_oss_proof_root) || return 1
  config="$root/$M8_OSS_CONFIG_RELPATH"

  [[ -e "$config" ]] || { m8_oss_die "canonical OSS config is absent: $M8_OSS_CONFIG_RELPATH"; return 1; }
  [[ -f "$config" && ! -L "$config" ]] ||
    { m8_oss_die "canonical OSS config must be a regular non-symlink file: $M8_OSS_CONFIG_RELPATH"; return 1; }

  case "$config" in
    "$root"/*) ;;
    *) m8_oss_die 'canonical OSS config escapes the proof worktree'; return 1 ;;
  esac

  size=$(wc -c <"$config" | tr -d '[:space:]')
  [[ "$size" == "$M8_OSS_CONFIG_BYTES" ]] ||
    { m8_oss_die "canonical OSS config size is $size (expected $M8_OSS_CONFIG_BYTES)"; return 1; }
  sha=$(sha256sum "$config" | cut -d' ' -f1)
  [[ "$sha" == "$M8_OSS_CONFIG_SHA256" ]] ||
    { m8_oss_die "canonical OSS config SHA-256 mismatch (expected $M8_OSS_CONFIG_SHA256; got $sha)"; return 1; }

  # Exact semantic content: profile header plus the language, mode and role keys.
  # No other key, no comment, no blank record is tolerated.
  local body role_now
  role_now=$(m8_oss_config_role_name) || return 1
  body=$(grep -vE '^[[:space:]]*(#|$)' "$config")
  [[ "$body" == "$(printf '[default]\nlanguage=EN\nmode=%s\necsRoleName=%s' "$M8_OSS_AUTH_MODE" "$role_now")" ]] ||
    { m8_oss_die 'canonical OSS config contains unexpected or missing keys'; return 1; }
  [[ "$(grep -c '^' <<<"$body")" == '4' ]] ||
    { m8_oss_die 'canonical OSS config must contain exactly four records'; return 1; }

  M8_OSS_CONFIG_AUTH_MODE=$(m8_oss_config_auth_mode) || return 1
  M8_OSS_CONFIG_ROLE_NAME=$role_now
  [[ "$M8_OSS_CONFIG_AUTH_MODE" == "$M8_OSS_AUTH_MODE" ]] ||
    { m8_oss_die "canonical config auth mode '$M8_OSS_CONFIG_AUTH_MODE' does not match the frozen '$M8_OSS_AUTH_MODE'"; return 1; }
  [[ -n "$M8_OSS_CONFIG_ROLE_NAME" ]] ||
    { m8_oss_die 'canonical config does not establish an ECS role name'; return 1; }
  export M8_OSS_CONFIG_AUTH_MODE M8_OSS_CONFIG_ROLE_NAME
  return 0
}

# --- canonical config bindings (single source of truth = frozen config bytes) -
m8_oss_config_auth_mode() {
  local config
  config=$(m8_oss_canonical_config_path) || return 1
  sed -n 's/^mode=//p' "$config" | head -n1
}

m8_oss_config_role_name() {
  local config
  config=$(m8_oss_canonical_config_path) || return 1
  sed -n 's/^ecsRoleName=//p' "$config" | head -n1
}

# --- role cross-binding -----------------------------------------------------
# A. stored/config binding: purely local, no provider access. The stored
#    observed role must equal the proof-tree config role, and the config auth
#    mode must equal the frozen auth mode.
m8_oss_role_binding_guard() {
  local observed config_role config_mode
  m8_oss_canonical_config_guard || return 1
  observed=$(m8_oss_ecs_role_name)
  [[ -n "$observed" ]] ||
    { m8_oss_die 'observed ECS RAM role name is not established; refusing any OSS call'; return 1; }
  config_role=$(m8_oss_config_role_name) || return 1
  [[ -n "$config_role" ]] ||
    { m8_oss_die 'proof-tree config does not establish an ECS role name'; return 1; }
  config_mode=$(m8_oss_config_auth_mode) || return 1
  [[ "$config_mode" == "$M8_OSS_AUTH_MODE" ]] ||
    { m8_oss_die "proof-tree config auth mode '$config_mode' is not '$M8_OSS_AUTH_MODE'"; return 1; }
  [[ "$observed" == "$config_role" ]] ||
    { m8_oss_die "stored observed ECS role '$observed' does not match the proof-tree config role '$config_role'"; return 1; }
  return 0
}

# B. fresh live cross-binding: required before EVERY network-capable invocation.
#    The durable IMDSv2 provider helper must be available (no fallback to the
#    stored value) and its fresh role-name LIST observation must equal both the
#    stored observed role and the proof-tree config role.
m8_oss_live_role_cross_binding_guard() {
  local live stored
  m8_oss_role_binding_guard || return 1
  declare -F m8_provider_identity_observe_ecs_role_name >/dev/null 2>&1 ||
    { m8_oss_die 'durable IMDSv2 provider role helper is unavailable; refusing any OSS network call'; return 1; }
  stored=$(m8_oss_ecs_role_name)
  live=$(m8_provider_identity_observe_ecs_role_name) || {
    m8_oss_die 'fresh IMDSv2 role-name observation failed; refusing any OSS network call'
    return 1
  }
  [[ -n "$live" ]] ||
    { m8_oss_die 'fresh IMDSv2 role-name observation was empty; refusing any OSS network call'; return 1; }
  [[ "$live" == "$stored" ]] ||
    { m8_oss_die "fresh live ECS role '$live' does not match the stored observed role '$stored'"; return 1; }
  [[ "$live" == "$(m8_oss_config_role_name)" ]] ||
    { m8_oss_die "fresh live ECS role '$live' does not match the proof-tree config role"; return 1; }
  M8_OSS_LIVE_ROLE_NAME="$live"
  export M8_OSS_LIVE_ROLE_NAME
  return 0
}

# --- ossutil executable identity --------------------------------------------
# Resolve the runtime ossutil, require an executable regular file, canonicalise
# symlinks to an absolute path, and record path/version/SHA-256. The version must
# parse as major.minor.patch and be >= 2.2.0 (required for --ignore-env-var).
# No live path/version/hash is hard-coded anywhere.
m8_ossutil_identity_guard() {
  local bin resolved version_line version
  bin=$(m8_ossutil_bin)
  m8_oss_require_config || return 1

  if [[ "$bin" == */* ]]; then
    resolved="$bin"
  else
    resolved=$(command -v "$bin" 2>/dev/null || printf '')
    [[ -n "$resolved" ]] || { m8_oss_die "ossutil executable is absent from PATH: $bin"; return 1; }
  fi
  [[ -f "$resolved" ]] || { m8_oss_die "ossutil is not a regular file: $resolved"; return 1; }
  [[ -x "$resolved" ]] || { m8_oss_die "ossutil is not executable: $resolved"; return 1; }
  resolved=$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")
  [[ "$resolved" == /* ]] || { m8_oss_die "ossutil path did not resolve to an absolute path: $resolved"; return 1; }
  [[ -f "$resolved" && -x "$resolved" ]] ||
    { m8_oss_die "resolved ossutil target is not an executable regular file: $resolved"; return 1; }

  version_line=$("$resolved" version 2>&1) || { m8_oss_die "ossutil version command failed"; return 1; }
  # The classifier program is supplied on stdin, so the version text is passed
  # as a file argument rather than piped (a pipe would be consumed by the
  # interpreter reading the program itself).
  local version_file
  version_file=$(mktemp "${TMPDIR:-/tmp}/m8-ossutil-version.XXXXXX")
  printf '%s\n' "$version_line" > "$version_file"
  version=$("$(m8_python_bin)" - "$version_file" "$M8_OSS_MIN_VERSION" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    text = handle.read()
minimum = sys.argv[2]
match = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
if not match:
    sys.stderr.write("FAIL: ossutil version output does not contain a major.minor.patch version: %r\n" % text[:200])
    raise SystemExit(1)
found = tuple(int(part) for part in match.groups())
want = tuple(int(part) for part in minimum.split("."))
if found < want:
    sys.stderr.write("FAIL: ossutil version %d.%d.%d is below the required minimum %s\n" % (found + (minimum,)))
    raise SystemExit(1)
sys.stdout.write("%d.%d.%d\n" % found)
PY
  ) || { rm -f "$version_file"; return 1; }
  rm -f "$version_file"

  M8_OSSUTIL_ABSOLUTE_PATH="$resolved"
  M8_OSSUTIL_VERSION="$version"
  M8_OSSUTIL_BINARY_SHA256="$(sha256sum "$resolved" | cut -d' ' -f1)"
  export M8_OSSUTIL_ABSOLUTE_PATH M8_OSSUTIL_VERSION M8_OSSUTIL_BINARY_SHA256
  return 0
}

# --- CLI-pinned OSS network target ------------------------------------------
# Every network-capable invocation performs the FRESH live role cross-binding
# first, then receives exactly the five pinned global arguments. The role is
# bound through the proof-tree config, NOT through a CLI flag: ossutil 2.4.0
# does not support --ecs-role-name and rejects Ali-EcsRamRole via CLI --mode.
m8_oss_global_args() {
  local config
  m8_oss_live_role_cross_binding_guard || return 1
  config=$(m8_oss_canonical_config_path) || return 1
  M8_OSS_GLOBAL_ARGS=(
    --config-file "$config"
    --region "$M8_OSS_REGION"
    --endpoint "$M8_OSS_ENDPOINT"
    --addressing-style "$M8_OSS_ADDRESSING_STYLE"
    --ignore-env-var
  )
  return 0
}

# Run one official ossutil api operation through the canonical trust target.
# No shell evaluation of arguments.
m8_oss_api() {
  local bin
  bin=$(m8_ossutil_bin)
  m8_oss_global_args || return 1
  "$bin" "${M8_OSS_GLOBAL_ARGS[@]}" api "$@"
}

m8_oss_run() {
  local bin
  bin=$(m8_ossutil_bin)
  m8_oss_global_args || return 1
  "$bin" "${M8_OSS_GLOBAL_ARGS[@]}" "$@"
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
  local -a operations=(put-object get-object head-object get-bucket-versioning get-bucket-location)
  local -a global_flags=(--config-file --region --endpoint --addressing-style --ignore-env-var)
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

  # R2I-C11: the five CLI-pinned global flags must be documented. --mode and
  # --ecs-role-name are deliberately NOT CLI pins: the role binding lives in the
  # proof-tree canonical config and is cross-bound live before every call.
  local flag
  for flag in "${global_flags[@]}"; do
    grep -Eq -- "(^|[^a-z-])${flag}([^a-z-]|$)" <<<"$aggregate" ||
      { m8_oss_die "ossutil help does not document the required global flag '$flag'"; return 1; }
  done

  if [[ "$evidence" != '-' ]]; then
    printf 'ossutil_capability=PASS\n' >> "$evidence/ossutil-capability.txt"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# R2I-C4 / B03: read-only bucket-location guard.
#
# The formal bucket MUST be in cn-hongkong. This runs through the canonical
# CLI-pinned trust target and must succeed before any PutObject. Empty, unknown,
# unparseable, AccessDenied, NoSuchBucket, wrong-region and any other API error
# all FAIL CLOSED. No fallback to a public or cross-region endpoint exists.
# ---------------------------------------------------------------------------
m8_oss_bucket_location_guard() {
  local evidence=${1:-'-'} raw='' rc=0 location='' raw_file=''
  m8_oss_require_config || return 1

  raw=$(m8_oss_api get-bucket-location --bucket "$(m8_oss_bucket)" 2>&1) || rc=$?

  if [[ "$evidence" != '-' ]]; then
    mkdir -p "$evidence" 2>/dev/null || true
    {
      printf 'get_bucket_location_rc=%s\n' "$rc"
      printf 'get_bucket_location_output:\n%s\n' "$raw"
    } >> "$evidence/oss-versioning-guard.txt"
  fi

  if (( rc != 0 )); then
    m8_oss_die "bucket location query failed (rc=$rc); refusing any PutObject"
    return 1
  fi

  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-location.XXXXXX")
  printf '%s' "$raw" > "$raw_file"
  location=$("$(m8_python_bin)" - "$raw_file" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    raw = handle.read()

def fail(message):
    sys.stderr.write("FAIL: %s\n" % message)
    raise SystemExit(1)

match = re.search(r"<LocationConstraint>\s*([^<]*?)\s*</LocationConstraint>", raw)
if not match:
    fail("bucket location response has no parseable LocationConstraint")
value = match.group(1).strip()
if not value:
    fail("bucket location response has an empty LocationConstraint")
sys.stdout.write(value + "\n")
PY
  ) || {
    rm -f "$raw_file"
    m8_oss_die 'bucket location response could not be classified; refusing any PutObject'
    return 1
  }
  rm -f "$raw_file"

  if [[ "$location" != "$M8_OSS_BUCKET_LOCATION" ]]; then
    if [[ "$evidence" != '-' ]]; then
      printf 'bucket_location=REJECTED:%s\n' "$location" >> "$evidence/oss-versioning-guard.txt"
    fi
    m8_oss_die "bucket is not formal-eligible: location '${location}' (required ${M8_OSS_BUCKET_LOCATION})"
    return 1
  fi

  if [[ "$evidence" != '-' ]]; then
    printf 'bucket_location=%s\n' "$location" >> "$evidence/oss-versioning-guard.txt"
  fi
  # The observed location is the live provenance value recorded in
  # wrapper-provenance.txt; it is derived here and never hard-coded.
  M8_OSS_BUCKET_LOCATION_OBSERVED="$location"
  export M8_OSS_BUCKET_LOCATION_OBSERVED
  return 0
}

# ---------------------------------------------------------------------------
# R2I-C4 / B03: exact 18-field trust-profile serialization.
#
# Records are UTF-8 `key=value\n` in the exact frozen field order, with exactly
# one LF after every record including the final one, and no CR/NUL. The digest is
# SHA256 of those exact bytes; JSON canonicalization is never used, and the
# digest is never a caller-supplied environment variable.
# ---------------------------------------------------------------------------
m8_oss_trust_profile_values() {
  local bucket role version binary config_sha
  bucket=$(m8_oss_bucket)
  role=$(m8_oss_ecs_role_name)
  version="${M8_OSSUTIL_VERSION:-}"
  binary="${M8_OSSUTIL_BINARY_SHA256:-}"
  config_sha="${M8_OSS_CONFIG_SHA256}"

  [[ -n "$bucket" ]] || { m8_oss_die 'trust profile: bucket name is not established'; return 1; }
  [[ -n "$role" ]] || { m8_oss_die 'trust profile: ECS role name is not established'; return 1; }
  [[ -n "$version" ]] || { m8_oss_die 'trust profile: ossutil version is not established'; return 1; }
  [[ -n "$binary" ]] || { m8_oss_die 'trust profile: ossutil binary SHA-256 is not established'; return 1; }

  printf 'schema=%s\n' "$M8_OSS_TRUST_PROFILE_SCHEMA"
  printf 'oss_bucket=%s\n' "$bucket"
  printf 'oss_region=%s\n' "$M8_OSS_REGION"
  printf 'effective_oss_endpoint=%s\n' "$M8_OSS_ENDPOINT"
  printf 'endpoint_class=%s\n' "$M8_OSS_ENDPOINT_CLASS"
  printf 'network_policy=%s\n' "$M8_OSS_NETWORK_POLICY"
  printf 'addressing_style=%s\n' "$M8_OSS_ADDRESSING_STYLE"
  printf 'oss_auth_mode=%s\n' "$M8_OSS_AUTH_MODE"
  printf 'ecs_role_name=%s\n' "$role"
  printf 'ossutil_version=%s\n' "$version"
  printf 'ossutil_binary_sha256=%s\n' "$binary"
  printf 'config_relpath=%s\n' "$M8_OSS_CONFIG_RELPATH"
  printf 'config_sha256=%s\n' "$config_sha"
  printf 'config_profile=%s\n' "$M8_OSS_CONFIG_PROFILE"
  printf 'config_policy_id=%s\n' "$M8_OSS_CONFIG_POLICY_ID"
  printf 'ignore_oss_env_vars=%s\n' "$M8_OSS_IGNORE_ENV_VARS"
  printf 'env_policy_id=%s\n' "$M8_OSS_ENV_POLICY_ID"
  printf 'tls_verification=%s\n' "$M8_OSS_TLS_VERIFICATION"
}

m8_oss_trust_profile_sha256() {
  m8_oss_trust_profile_values | sha256sum | cut -d' ' -f1
}

m8_oss_trust_profile_assert_canonical() {
  local bytes count
  # R2I-C11: eligibility requires the stored observed role to be cross-bound to
  # the proof-tree config role. This is a purely LOCAL check, so deterministic
  # profile serialization never performs provider network access. The fresh live
  # cross-binding happens in m8_oss_global_args before every OSS network call.
  m8_oss_role_binding_guard || return 1
  bytes=$(m8_oss_trust_profile_values | wc -c | tr -d '[:space:]')
  count=$(m8_oss_trust_profile_values | grep -c '^[a-z0-9_]*=')
  [[ "$count" == '18' ]] || { m8_oss_die "trust profile must contain exactly 18 records (got $count)"; return 1; }
  [[ "$bytes" -gt 0 ]] || { m8_oss_die 'trust profile serialization is empty'; return 1; }
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
  #
  # R2I-C12: the XML branch is STRUCTURED (xml.etree.ElementTree), never regex.
  # The exact live ossutil 2.4.0 response is
  #   <VersioningConfiguration xmlns="http://doc.oss-cn-hangzhou.aliyuncs.com"/>
  #   0.087913(s) elapsed
  # i.e. an official default namespace plus ONE terminal timing footer; the old
  # regex fullmatch classifier rejected that legitimate response as unparseable.
  # At most one terminal footer is recognised and removed; everything else stays
  # fail-closed.
  #
  # R2I-C12-A1: the payload reaches the parser unmodified. There is NO XML prolog
  # stripping (which could repair a malformed declaration), the footer line must
  # match the frozen grammar exactly, and comments/processing instructions are
  # made observable so they can never be silently dropped.
  raw_file=$(mktemp "${TMPDIR:-/tmp}/m8-versioning.XXXXXX")
  printf '%s' "$raw" > "$raw_file"
  verdict=$("$(m8_python_bin)" - "$raw_file" <<'PY'
import json
import re
import sys
import xml.etree.ElementTree as ET

OFFICIAL_NS = "http://doc.oss-cn-hangzhou.aliyuncs.com"
# Frozen footer grammar. The footer LINE must match this exactly: no leading or
# trailing whitespace is tolerated and the decimal syntax is not widened.
TIMING_FOOTER = re.compile(r"[0-9]+\.[0-9]+\(s\) elapsed")


class VersioningTreeBuilder(ET.TreeBuilder):
    # R2I-C12-A1: the default TreeBuilder SILENTLY DROPS comments and processing
    # instructions, which made
    #   <VersioningConfiguration><!--c--></VersioningConfiguration>
    #   <VersioningConfiguration><?m8 x?></VersioningConfiguration>
    # look structurally empty. insert_comments/insert_pis make them observable,
    # and the counter makes any comment/PI anywhere -- inside the root or at
    # document level before/after it -- fail closed.
    def __init__(self):
        super().__init__(insert_comments=True, insert_pis=True)
        self.non_element_nodes = 0

    def comment(self, text):
        self.non_element_nodes += 1
        return super().comment(text)

    def pi(self, target, text=None):
        self.non_element_nodes += 1
        return super().pi(target, text)


def emit(value):
    sys.stdout.write(value + "\n")
    sys.exit(0)


def classify_status(value):
    # Frozen C12 rule: only absent / empty / Null may mean UNVERSIONED.
    # Case-sensitive: the historical blanket lower() is deliberately dropped, and
    # the "unversioned"/"none" magic aliases are no longer recognised.
    if value is None:
        return "UNVERSIONED"
    text = value if isinstance(value, str) else str(value)
    if text.strip() == "":
        return "UNVERSIONED"
    if text == "Null":
        return "UNVERSIONED"
    if text == "Enabled":
        return "ENABLED"
    if text == "Suspended":
        return "SUSPENDED"
    return "UNKNOWN:" + text.strip()


def split_tag(tag):
    if not isinstance(tag, str):
        return "", None
    if tag.startswith("{"):
        namespace, _, local = tag[1:].partition("}")
        return namespace, local
    return "", tag


with open(sys.argv[1], "rb") as handle:
    data = handle.read()

# Strict UTF-8: a malformed byte sequence is never silently normalised.
try:
    text = data.decode("utf-8")
except UnicodeDecodeError:
    emit("UNPARSEABLE")

# At most ONE terminal timing footer may be removed. Trailing blank /
# whitespace-only LINES may be ignored, but the footer line itself must match the
# frozen grammar EXACTLY (no .strip() around the match): a line carrying leading
# or trailing whitespace is not a footer and is therefore parsed as payload.
lines = text.split("\n")
while lines and lines[-1].strip() == "":
    lines.pop()
if lines and TIMING_FOOTER.fullmatch(lines[-1]):
    lines.pop()
    while lines and lines[-1].strip() == "":
        lines.pop()
# A second timing-footer record is a failure, never a second removal.
if lines and TIMING_FOOTER.fullmatch(lines[-1]):
    emit("UNPARSEABLE")

# No blanket strip: the payload is handed to the parser unmodified (modulo the
# authorized footer removal), so a malformed XML declaration can never be
# repaired by trimming bytes. A whitespace-only successful response keeps the
# historical UNVERSIONED classification.
body = "\n".join(lines)
if body.strip() == "":
    emit("UNVERSIONED")

# Branch selection only: the parser still receives the unmodified payload, so
# leading whitespace before a root element follows XML parser semantics while a
# whitespace-preceded XML declaration stays malformed and is rejected.
if body.strip().startswith("<"):
    # DOCTYPE / ENTITY are rejected case-insensitively before parsing, and the
    # parser is never asked to expand external entities.
    lowered = body.lower()
    if "<!doctype" in lowered or "<!entity" in lowered:
        emit("UNPARSEABLE")

    # The ORIGINAL payload is parsed. A valid XML declaration is validated by the
    # parser itself; a malformed one is a hard ParseError. There is deliberately
    # NO prolog stripping, because removing bytes before parsing could turn
    # malformed XML into valid XML.
    builder = VersioningTreeBuilder()
    parser = ET.XMLParser(target=builder)
    try:
        parser.feed(body)
        root = parser.close()
    except ET.ParseError:
        emit("UNPARSEABLE")
    except Exception:
        emit("UNPARSEABLE")

    # Eligible XML contains no comment and no processing instruction anywhere,
    # including at document level around the root, where the default TreeBuilder
    # would have dropped them silently.
    if builder.non_element_nodes > 0:
        emit("UNPARSEABLE")
    if root is None:
        emit("UNPARSEABLE")

    root_ns, root_local = split_tag(root.tag)
    if root_local != "VersioningConfiguration":
        emit("UNPARSEABLE")
    if root_ns not in ("", OFFICIAL_NS):
        emit("UNPARSEABLE")
    if root.attrib:
        emit("UNPARSEABLE")
    if (root.text or "").strip():
        emit("UNPARSEABLE")

    children = list(root)
    for child in children:
        if (child.tail or "").strip():
            emit("UNPARSEABLE")
    if len(children) == 0:
        emit("UNVERSIONED")
    if len(children) > 1:
        emit("UNPARSEABLE")

    status = children[0]
    status_ns, status_local = split_tag(status.tag)
    if status_local != "Status":
        emit("UNPARSEABLE")
    if status_ns != root_ns:
        emit("UNPARSEABLE")
    if status.attrib:
        emit("UNPARSEABLE")
    if len(list(status)) != 0:
        emit("UNPARSEABLE")
    emit(classify_status(status.text))

# JSON compatibility branch, with the same frozen status semantics.
try:
    doc = json.loads(body)
except Exception:
    emit("UNPARSEABLE")

if not isinstance(doc, dict):
    emit("UNPARSEABLE")

found = False
value = None
for key in ("Status", "status"):
    if key in doc:
        value = doc[key]
        found = True
        break
if not found:
    inner = doc.get("VersioningConfiguration")
    if isinstance(inner, dict):
        for key in ("Status", "status"):
            if key in inner:
                value = inner[key]
                found = True
                break
if not found:
    if len(doc) == 0 or set(doc).issubset({"VersioningConfiguration", "ResponseMetadata"}):
        emit("UNVERSIONED")
    emit("UNPARSEABLE")
emit(classify_status(value))
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
