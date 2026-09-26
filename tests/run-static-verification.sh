#!/usr/bin/env bash
# LinguaGraph M8-HSDR-F02 R2E-B01 offline verification.
#
# Runs ONLY offline/static/synthetic checks:
#   * bash -n and structural (grep) invariants over the proof harness;
#   * python3 stdlib fixture tests for the JSON verifiers;
#   * synthetic shell fixtures driving the real wrapper/OSS phase functions
#     against tests/fixtures/fake-ossutil.sh.
#
# It never calls a provider API, never contacts Alibaba OSS, never runs
# Playwright, pytest, Vitest or a Product build, and never installs anything.
#
# Every check is labelled V01..V40. Exit status is non-zero if any check fails.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FIXTURES="$REPO_ROOT/tests/fixtures"
readonly FAKE_OSSUTIL="$FIXTURES/fake-ossutil.sh"
readonly PYTHON="${M8_PYTHON_BIN:-python3}"

# R2I-C11: the proof-tree canonical config pins the ECS role name.
readonly C11_ROLE='LinguaGraphM8ProofExecutor'

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/m8-r2b-verify.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

STATIC_TOTAL=0
STATIC_PASS=0
SYNTH_TOTAL=0
SYNTH_PASS=0
CORR_TOTAL=0
CORR_PASS=0
R2I_TOTAL=0
R2I_PASS=0
R2I_C4_TOTAL=0
R2I_C4_PASS=0
R2I_C7_TOTAL=0
R2I_C7_PASS=0
R2I_C11_TOTAL=0
R2I_C11_PASS=0
R2I_C12_TOTAL=0
R2I_C12_PASS=0
R2I_C13_TOTAL=0
R2I_C13_PASS=0
R2I_C14_TOTAL=0
R2I_C14_PASS=0
R2I_C15_TOTAL=0
R2I_C15_PASS=0
declare -a FAILED_CHECKS=()

run_check() {
  local kind=$1 id=$2 desc=$3 fn=$4 out='' rc=0
  case "$kind" in
    static) STATIC_TOTAL=$((STATIC_TOTAL + 1)) ;;
    synth) SYNTH_TOTAL=$((SYNTH_TOTAL + 1)) ;;
    corr) CORR_TOTAL=$((CORR_TOTAL + 1)) ;;
    r2i) R2I_TOTAL=$((R2I_TOTAL + 1)) ;;
    r2i_c4) R2I_C4_TOTAL=$((R2I_C4_TOTAL + 1)) ;;
    r2i_c7) R2I_C7_TOTAL=$((R2I_C7_TOTAL + 1)) ;;
    r2i_c11) R2I_C11_TOTAL=$((R2I_C11_TOTAL + 1)) ;;
    r2i_c12) R2I_C12_TOTAL=$((R2I_C12_TOTAL + 1)) ;;
    r2i_c13) R2I_C13_TOTAL=$((R2I_C13_TOTAL + 1)) ;;
    r2i_c14) R2I_C14_TOTAL=$((R2I_C14_TOTAL + 1)) ;;
    r2i_c15) R2I_C15_TOTAL=$((R2I_C15_TOTAL + 1)) ;;
  esac
  out="$("$fn" 2>&1)" || rc=$?
  if (( rc == 0 )) && ! grep -q '^ASSERT_FAIL:' <<<"$out"; then
    printf 'PASS [%-6s] %s %s\n' "$kind" "$id" "$desc"
    case "$kind" in
      static) STATIC_PASS=$((STATIC_PASS + 1)) ;;
      synth) SYNTH_PASS=$((SYNTH_PASS + 1)) ;;
      corr) CORR_PASS=$((CORR_PASS + 1)) ;;
      r2i) R2I_PASS=$((R2I_PASS + 1)) ;;
      r2i_c4) R2I_C4_PASS=$((R2I_C4_PASS + 1)) ;;
      r2i_c7) R2I_C7_PASS=$((R2I_C7_PASS + 1)) ;;
      r2i_c11) R2I_C11_PASS=$((R2I_C11_PASS + 1)) ;;
      r2i_c12) R2I_C12_PASS=$((R2I_C12_PASS + 1)) ;;
      r2i_c13) R2I_C13_PASS=$((R2I_C13_PASS + 1)) ;;
      r2i_c14) R2I_C14_PASS=$((R2I_C14_PASS + 1)) ;;
      r2i_c15) R2I_C15_PASS=$((R2I_C15_PASS + 1)) ;;
    esac
  else
    printf 'FAIL [%-6s] %s %s\n' "$kind" "$id" "$desc"
    printf '     %s\n' "${out//$'\n'/$'\n'     }"
    FAILED_CHECKS+=("$id")
  fi
}

# --- assertion helpers ------------------------------------------------------
# A test function runs inside a command substitution and is therefore invoked in
# a condition context, where bash suppresses errexit for the whole dynamic
# extent of the call. Assertions must not rely on errexit: they abort their
# subshell explicitly and print a marker that run_check also looks for, so a
# failed assertion can never be silently overridden by a later success.
assert_fail() { printf 'ASSERT_FAIL: %s\n' "$*"; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || assert_fail "assert_eq: expected '$2', got '$1' (${3:-})"
}
assert_grep() {
  grep -Eq -e "$1" "$2" || assert_fail "assert_grep: '$1' not found in $2"
}
assert_no_grep() {
  if grep -Eq -e "$1" "$2"; then
    grep -En -- "$1" "$2" | head -n5 | sed 's/^/     /'
    assert_fail "assert_no_grep: '$1' unexpectedly present in $2"
  fi
}
assert_contains() {
  grep -Fq -- "$2" "$1" || assert_fail "assert_contains: '$2' not found in $1"
}
assert_no_contains() {
  grep -Fq -- "$2" "$1" && assert_fail "assert_no_contains: '$2' unexpectedly present in $1"
  return 0
}
assert_file() { [[ -f "$1" ]] || assert_fail "assert_file: $1 is not a regular file"; }
assert_no_file() { [[ ! -e "$1" ]] || assert_fail "assert_no_file: $1 unexpectedly exists"; }
assert_exit_fail() {
  "$@" >/dev/null 2>&1 && assert_fail "assert_exit_fail: $* unexpectedly succeeded"
  return 0
}
assert_exit_ok() {
  "$@" >/dev/null 2>&1 || assert_fail "assert_exit_ok: $* unexpectedly failed"
}
# Structural JSON edit used by the R2I-C4 negatives: drop or replace one field
# (dotted path supported) and rewrite the document canonically. Uses -c so the
# interpreter never competes with a pipe for stdin.
json_edit() {
  local in=$1 out=$2 mode=$3 field=${4:-} value=${5:-}
  "$PYTHON" -c '
import json
import sys

src, dst, mode, path, value = sys.argv[1:6]
with open(src, encoding="utf-8") as handle:
    document = json.load(handle)
if mode == "drop":
    head, _, leaf = path.rpartition(".")
    (document[head] if head else document).pop(leaf, None)
elif mode == "set":
    head, _, leaf = path.rpartition(".")
    (document[head] if head else document)[leaf] = value
else:
    raise SystemExit("json_edit: unknown mode %r" % mode)
with open(dst, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
' "$in" "$out" "$mode" "$field" "$value"
}

readonly CORE="$REPO_ROOT/scripts/run-m8-proof-core.sh"
readonly ADAPTER="$REPO_ROOT/scripts/run-m8-proof-alibaba-ecs.sh"
readonly WRAPPER="$REPO_ROOT/scripts/run-m8-proof.sh"
readonly PREFLIGHT="$REPO_ROOT/scripts/preflight-m8-alibaba-ecs.sh"
readonly OSS_LIB="$REPO_ROOT/scripts/lib/m8-oss.sh"
readonly IDENTITY_LIB="$REPO_ROOT/scripts/lib/m8-provider-identity.sh"
readonly MANIFEST_LIB="$REPO_ROOT/scripts/lib/m8-manifest.sh"
readonly SEAMS_LIB="$REPO_ROOT/scripts/lib/m8-synthetic-seams.sh"
readonly REQUIRED_LIST="$REPO_ROOT/scripts/lib/m8-required-artifacts.txt"

# Frozen seven-spec Playwright release surface in its two distinct namespaces.
# PLAYWRIGHT_INVOCATION_SPECS are the cwd-relative CLI selectors (they retain the
# `e2e/` prefix); PLAYWRIGHT_REPORT_SPECS are the Playwright testDir-relative
# suite.file values (no `e2e/`). Only PLAYWRIGHT_REPORT_SPECS may be expected
# from the JSON report.
readonly -a PLAYWRIGHT_INVOCATION_SPECS=(
  'e2e/golden-path.spec.ts'
  'e2e/unicode.spec.ts'
  'e2e/segmentation.spec.ts'
  'e2e/token-segmentation.spec.ts'
  'e2e/lemma-annotation.spec.ts'
  'e2e/pos-annotation.spec.ts'
  'e2e/workbench-information-architecture.spec.ts'
)
readonly -a PLAYWRIGHT_REPORT_SPECS=(
  'golden-path.spec.ts'
  'unicode.spec.ts'
  'segmentation.spec.ts'
  'token-segmentation.spec.ts'
  'lemma-annotation.spec.ts'
  'pos-annotation.spec.ts'
  'workbench-information-architecture.spec.ts'
)

# The seven production override seams owned by scripts/lib/m8-synthetic-seams.sh.
# This is the test-side copy used to build `env -u` argument lists; the
# independent exact-set oracle lives in I01 and hard-codes the same seven names.
readonly -a SYNTHETIC_SEAM_VARS=(
  M8_SYNTHETIC_TEST_MODE
  M8_IMDS_BASE_URL
  M8_IMDS_CURL_BIN
  M8_OSSUTIL_BIN
  M8_OSSUTIL_GET_OUTPUT_FLAG
  M8_ADAPTER_SCRIPT_OVERRIDE
  M8_PYTHON_BIN
)

# The 19 Human-frozen R2I-C4/B03 trust-environment names. This is the test-side
# copy used to build `env -u` argument lists; T01 holds the independent
# hard-coded exact-set oracle for the production authority.
readonly -a OSS_TRUST_ENV_VARS=(
  M8_OSSUTIL_CONFIG_FILE
  OSS_ACCESS_KEY_ID
  OSS_ACCESS_KEY_SECRET
  OSS_SESSION_TOKEN
  OSS_ROLE_ARN
  OSS_ROLE_SESSION_NAME
  OSS_REGION
  OSS_ENDPOINT
  OSSUTIL_CONFIG_FILE
  OSSUTIL_PROFILE
  ALIBABA_CLOUD_ECS_METADATA
  HTTP_PROXY
  HTTPS_PROXY
  ALL_PROXY
  NO_PROXY
  http_proxy
  https_proxy
  all_proxy
  no_proxy
)

# ===========================================================================
# Synthetic formal fixture.
# ===========================================================================

# Offline IMDS client used by the B03 role-name observation tests and by the
# synthetic trust-target establishment. It answers ONLY the IMDSv2 token
# endpoint and the role-name LIST endpoint; it never serves credential payloads,
# so a production regression to meta-data/ram/security-credentials/<role> is
# detectable.
#   M8_FAKE_IMDS_ROLE_MODE = one (default) | zero | multiple | control
write_fake_imds_client() {
  local path="$TMPROOT/fake-imds-curl.sh"
  cat >"$path" <<'FAKEIMDS'
#!/usr/bin/env bash
set -Eeuo pipefail
url=''
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
if [[ -n "${M8_FAKE_IMDS_LOG:-}" ]]; then printf '%s\n' "$url" >>"$M8_FAKE_IMDS_LOG"; fi
mode="${M8_FAKE_IMDS_ROLE_MODE:-one}"
role="${M8_FAKE_IMDS_ROLE_NAME:-LinguaGraphM8ProofExecutor}"
case "$url" in
  */api/token)
    printf 'SYNTHETIC-IMDS-TOKEN-NOT-A-SECRET\n'
    exit 0
    ;;
  */meta-data/ram/security-credentials/)
    case "$mode" in
      one)      printf '%s\n' "$role" ;;
      zero)     exit 0 ;;
      multiple) printf '%s\n%s\n' "$role" 'M8SyntheticSecondRole' ;;
      control)  printf '%s\r\n' "$role" ;;
      # R2I-C6: a REAL NUL byte between two role fragments. This must be an
      # actual 0x00 on stdout, not the two printable characters backslash-zero.
      nul)      printf '%s\0%s\n' "$role" 'M8SyntheticNulSuffix' ;;
      *)        exit 1 ;;
    esac
    exit 0
    ;;
  */meta-data/ram/security-credentials/*)
    printf 'Error: synthetic IMDS refuses the credential-payload endpoint\n' >&2
    exit 22
    ;;
  *)
    printf 'Error: synthetic IMDS has no route for %s\n' "$url" >&2
    exit 22
    ;;
esac
FAKEIMDS
  chmod +x "$path"
  printf '%s' "$path"
}

# R2I-C11: arm the durable IMDSv2 provider authority and the offline IMDS stub so
# the live role cross-binding can be exercised deterministically. Every
# network-capable OSS path now requires this before building a CLI argument
# vector.
c11_arm_provider_seams() {
  # shellcheck source=/dev/null
  source "$IDENTITY_LIB"
  export M8_IMDS_CURL_BIN="$(write_fake_imds_client)"
  export M8_IMDS_BASE_URL='http://imds.invalid/latest'
  export M8_FAKE_IMDS_ROLE_MODE='one'
  export M8_FAKE_IMDS_ROLE_NAME="$C11_ROLE"
  export M8_OSS_ECS_ROLE_NAME="$C11_ROLE"
}

# Establish the B03 OSS trust target through the real production guards.
establish_oss_trust_target() {
  m8_oss_canonical_config_guard - || return 1
  m8_ossutil_identity_guard - || return 1
  m8_oss_observe_ecs_role_name || return 1
  m8_prepare_oss_trust_profile || return 1
}

# Write + stage the synthetic SEMANTIC issued.json. Must be called AFTER the OSS
# trust target is established, because the authorization binds its digest.
# $1 (optional) overrides the profile digest to exercise mismatch paths.
stage_semantic_issued_json() {
  local profile_sha=${1:-$OSS_TRUST_PROFILE_SHA256}
  "$PYTHON" - "$ISSUED_LOCAL" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" "$AUTH" "$profile_sha" <<'PY'
import json
import sys

out, proof_sha, proof_tree, authorization_sha256, profile_sha = sys.argv[1:6]
document = {
    "schema": "linguagraph-m8-run-authorization/v1",
    "authorization_kind": "SEMANTIC",
    "authorization_id": "M8-EXI-01-RUN-SYNTHETIC",
    "authorization_sha256": authorization_sha256,
    "oss_trust_profile_sha256": profile_sha,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "candidate_sha": "2441f9cf60b7cc9402c5b257be010b559b39b717",
    "candidate_tree": "5d1b7c7cc104cd365b0ea629d9ead7677d17f2be",
    "candidate_parent": "e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d",
    "frozen_main": "cf26ea557bd746a518ff32b8b7e7a7542be7f7ae",
    "provider_identity": {
        "instance_id": "i-j6c9854oyawy89fcdxy2",
        "region_id": "cn-hongkong",
        "zone_id": "cn-hongkong-d",
        "instance_type": "ecs.g9i.xlarge",
        "image_id": "ubuntu_24_04_x64_20G_alibase_20260916.vhd",
        "identity_document_sha256": "60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d",
        "identity_pkcs7_sha256": "89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211",
    },
    "authorized_executor_id": "alibaba-ecs:i-j6c9854oyawy89fcdxy2",
    "single_use": True,
    "issued_utc": "2026-01-01T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
  stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
}

bootstrap_formal_fixture() {
  # shellcheck source=lib/m8-provider-identity.sh
  source "$IDENTITY_LIB"
  # shellcheck source=lib/m8-manifest.sh
  source "$MANIFEST_LIB"

  SB="$(mktemp -d "$TMPROOT/sb.XXXXXX")"
  PROOF="$SB/proof"
  HOST="$SB/host"
  EVIDENCE="$PROOF/proof-artifacts"
  FAKE_ROOT="$SB/oss"
  mkdir -p "$PROOF" "$HOST" "$FAKE_ROOT/objects"

  cp -a "$REPO_ROOT/scripts" "$PROOF/scripts"
  git -C "$PROOF" init -q
  git -C "$PROOF" add -A >/dev/null
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$PROOF" commit -qm 'synthetic proof fixture' >/dev/null

  APPROVED_PROOF_SHA="$(git -C "$PROOF" rev-parse HEAD)"
  APPROVED_PROOF_TREE="$(git -C "$PROOF" rev-parse HEAD^{tree})"
  export APPROVED_PROOF_SHA APPROVED_PROOF_TREE
  export M8_PROOF_ROOT="$PROOF"
  export M8_PROOF_HOST_STATE="$HOST"
  export M8_PROOF_EVIDENCE_DIR="$EVIDENCE"
  export M8_SYNTHETIC_TEST_MODE=1
  export M8_OSS_BUCKET='test-bucket'
  export M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$FAKE_ROOT"
  export M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_FAKE_OSS_LOCATION='cn-hongkong'
  export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"
  # Offline IMDS used only for the read-only role-name observation.
  export M8_IMDS_CURL_BIN="$(write_fake_imds_client)"
  export M8_IMDS_BASE_URL='http://imds.invalid/latest'
  export M8_FAKE_IMDS_ROLE_MODE='one'
  export M8_FAKE_IMDS_ROLE_NAME='LinguaGraphM8ProofExecutor'

  ISSUED_LOCAL="$SB/issued.json"
  # B1 authorization identity: the Human-issued input is the exact TOKEN string.
  # authorization_sha256 is SHA256(TOKEN) and is what issued.json must bind; it is
  # never derived from the issued-document bytes.
  SEMANTIC_TOKEN='M8-EXI-01-RUN-SYNTHETIC-TOKEN'
  AUTH="$(printf '%s' "$SEMANTIC_TOKEN" | sha256sum | cut -d' ' -f1)"
  export M8_PROOF_RUN_AUTHORIZATION="$SEMANTIC_TOKEN"

  M8_PRECLAIM_DIR="$HOST/preclaim/$AUTH"
  SEAL_DIR="$HOST/sealed/$AUTH"
  # SEAL_DIR is deliberately NOT created here: the wrapper must create the
  # host-local seal directory itself before PHASE A writes its validation output.
  write_identity_capture "$M8_PRECLAIM_DIR/provider-identity/primary"
  export M8_PRECLAIM_DIR SEAL_DIR AUTH SB PROOF HOST EVIDENCE FAKE_ROOT ISSUED_LOCAL
  export SEMANTIC_TOKEN
}

# Write a synthetic but correctly valued read-only provider identity capture.
write_identity_capture() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s\n' "$EXPECTED_INSTANCE_ID" >"$dir/instance-id.txt"
  printf '%s\n' "$EXPECTED_REGION_ID" >"$dir/region-id.txt"
  printf '%s\n' "$EXPECTED_ZONE_ID" >"$dir/zone-id.txt"
  printf '%s\n' "$EXPECTED_INSTANCE_TYPE" >"$dir/instance-type.txt"
  printf '%s\n' "$EXPECTED_IMAGE_ID" >"$dir/image-id.txt"
  printf 'synthetic-identity-document\n' >"$dir/instance-identity-document.json"
  printf 'synthetic-identity-pkcs7\n' >"$dir/instance-identity-pkcs7.txt"
  printf '%s\n' "$EXPECTED_IDENTITY_DOCUMENT_SHA256" >"$dir/instance-identity-document.sha256"
  printf '%s\n' "$EXPECTED_IDENTITY_PKCS7_SHA256" >"$dir/instance-identity-pkcs7.sha256"
  printf 'provider_identity_capture=SYNTHETIC\n' >"$dir/provider-identity-result.txt"
}

stage_object() {
  local key=$1 source=$2
  local destination="$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$key"
  mkdir -p "$(dirname "$destination")"
  cp -f "$source" "$destination"
}

object_bytes() {
  cat "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$1"
}

# Materialize the canonical required artifact set under <root>, never clobbering
# a file that already exists (the fixture's correctly valued identity captures
# must survive).
populate_required_root() {
  local root=$1 rel
  mkdir -p "$root"
  while IFS= read -r rel; do
    case "$rel" in '' | '#'*) continue ;; esac
    if [[ -e "$root/$rel" ]]; then
      continue
    fi
    mkdir -p "$(dirname "$root/$rel")"
    printf 'synthetic\n' >"$root/$rel"
  done <"$REQUIRED_LIST"
}

populate_required_artifacts() {
  populate_required_root "$EVIDENCE"
  printf 'PLAYWRIGHT_EFFECTIVE_RETRIES=0\n' >"$EVIDENCE/playwright-effective-retries.txt"
  printf 'PASS\n' >"$EVIDENCE/outcome.txt"
  printf '0\n' >"$EVIDENCE/core-exit-code.txt"
  printf '0\n' >"$EVIDENCE/adapter-exit-code.txt"
  printf '0\n' >"$EVIDENCE/formal-execution-rc.txt"
  : >"$EVIDENCE/docker-owned-marker"
  # The formal adapter's post-claim defence-in-depth capture is represented with
  # correct observed values, since the wrapper now independently re-checks it.
  write_identity_capture "$EVIDENCE/provider-identity/reexec"
}

# Runs the real wrapper phase functions for a synthetic SEMANTIC closure.
run_formal_success() {
  bootstrap_formal_fixture
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/run-m8-proof.sh"
  m8_wrapper_init
  m8_guard_local_syntax || return 1
  # R2I-C4/B03: establish the OSS trust target, then bind it in the synthetic
  # authorization exactly as the production pre-claim order does.
  establish_oss_trust_target || return 1
  stage_semantic_issued_json || return 1
  m8_oss_capability_guard "$M8_PRECLAIM_DIR" || return 1
  m8_oss_bucket_location_guard "$M8_PRECLAIM_DIR" || return 1
  m8_oss_versioning_guard "$M8_PRECLAIM_DIR" || return 1
  m8_load_authorization || return 1
  m8_claim_create || return 1
  m8_evidence_initialize || return 1
  populate_required_artifacts
  FORMAL_EXECUTION_RC=0
  m8_phase_a_validate || return 1
  m8_phase_b_seal || return 1
  m8_phase_c_durability || return 1
  m8_phase_d_commit || return 1
  printf 'FORMAL_FIXTURE_RECEIPT_SHA=%s\n' "$RECEIPT_VERIFIED_SHA256"
}

# ===========================================================================
# V01..V05 — frozen RC contract (static).
# ===========================================================================
v01() {
  local bad
  bad="$(grep -n 'core-exit-code\.txt' "$CORE" | grep -Ev '^[0-9]+:[[:space:]]*#' |
    grep -Ev '\[\[ ! -e|die ' || true)"
  [[ -z "$bad" ]] || { printf 'core writes core-exit-code.txt:\n%s\n' "$bad"; return 1; }
  assert_grep 'guard_core_rc_ownership' "$CORE"
  assert_contains "$ADAPTER" 'printf '"'"'%s\n'"'"' "$CORE_RC" > "$EVIDENCE/core-exit-code.txt"'
  assert_no_grep '>[[:space:]]*"\$M8_EVIDENCE/core-exit-code\.txt"' "$WRAPPER"
}

v02() {
  grep -A1 -F 'bash "$CORE" || CORE_RC=$?' "$ADAPTER" | grep -Fq 'core-exit-code.txt' ||
    { printf 'adapter does not capture the core RC immediately after the child returns\n'; return 1; }
}

v03() {
  local body="$TMPROOT/v03-finalize" trap_line core_line
  assert_grep 'trap adapter_finalize EXIT' "$ADAPTER"
  sed -n '/^adapter_finalize()/,/^}/p' "$ADAPTER" >"$body"
  assert_grep '> "\$EVIDENCE/adapter-exit-code\.txt"' "$body"
  trap_line="$(grep -n 'trap adapter_finalize EXIT' "$ADAPTER" | cut -d: -f1)"
  core_line="$(grep -n 'bash "\$CORE" || CORE_RC=\$?' "$ADAPTER" | cut -d: -f1)"
  (( trap_line < core_line )) ||
    { printf 'the EXIT trap is installed after the core invocation\n'; return 1; }
}

v04() {
  grep -A1 -F 'bash "$M8_ADAPTER_SCRIPT"' "$WRAPPER" | grep -Fq 'formal-execution-rc.txt' ||
    { printf 'wrapper does not capture the adapter RC immediately after the child returns\n'; return 1; }
}

v05() {
  assert_grep 'adapter_rc.*==.*execution_rc' "$WRAPPER"
  assert_grep 'adapter-exit-code\.txt is not numeric' "$WRAPPER"
  assert_grep 'FAIL CLOSED' "$WRAPPER"
}

# ===========================================================================
# V06..V16 — synthetic lifecycle behaviour.
# ===========================================================================
v06() {
  local d
  d="$(mktemp -d "$TMPROOT/v06.XXXXXX")"
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    printf '0\n' >"$d/formal-execution-rc.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'absent adapter RC did not fail\n'; return 1; fi
    : >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'empty adapter RC did not fail\n'; return 1; fi
    printf '7\n' >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'mismatched RC did not fail\n'; return 1; fi
    printf 'x\n' >"$d/adapter-exit-code.txt"
    if m8_rc_crosscheck 2>/dev/null; then printf 'non-numeric adapter RC did not fail\n'; return 1; fi
    printf '7\n' >"$d/formal-execution-rc.txt"
    printf '7\n' >"$d/adapter-exit-code.txt"
    m8_rc_crosscheck
  )
}

v07() {
  # A signal-terminated adapter is a distinct numeric RC, never conflated with
  # 0/1, and a mismatch against the adapter's own declaration fails closed.
  local d stub rc=0
  d="$(mktemp -d "$TMPROOT/v07.XXXXXX")"
  stub="$TMPROOT/term-adapter.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
# A correct adapter declares the signal-derived RC (128 + 15).
finalize() { printf '143\n' >"$EVIDENCE/adapter-exit-code.txt"; }
trap finalize EXIT
printf 'PASS\n' >"$EVIDENCE/outcome.txt"
kill -TERM $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$stub"
    export M8_STUB_EVIDENCE="$d"
    m8_phase_a_invoke_adapter || return 1
    assert_eq "$(cat "$d/formal-execution-rc.txt")" '143' 'TERM formal RC'
    assert_eq "$(cat "$d/adapter-exit-code.txt")" '143' 'TERM adapter RC'
  ) || rc=$?
  (( rc == 0 )) || return 1
  # A wrong self-declaration (0 for a TERM) must be rejected by the cross-check.
  local wrong="$TMPROOT/term-adapter-wrong.sh"
  cat >"$wrong" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
finalize() { printf '0\n' >"$EVIDENCE/adapter-exit-code.txt"; }
trap finalize EXIT
printf 'PASS\n' >"$EVIDENCE/outcome.txt"
kill -TERM $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$wrong"
    export M8_STUB_EVIDENCE="$d"
    if m8_phase_a_invoke_adapter; then printf 'TERM RC mismatch was accepted\n'; return 1; fi
  )
}

v08() {
  # SIGKILL cannot run an in-process trap: the adapter RC is absent and the
  # wrapper must fail closed instead of fabricating it.
  local d stub
  d="$(mktemp -d "$TMPROOT/v08.XXXXXX")"
  stub="$TMPROOT/kill-adapter.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
EVIDENCE="${M8_STUB_EVIDENCE:?}"
trap 'printf "%s\n" "$?" >"$EVIDENCE/adapter-exit-code.txt"' EXIT
kill -KILL $$
sleep 30
EOF
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    M8_EVIDENCE="$d"
    M8_ADAPTER_SCRIPT="$stub"
    export M8_STUB_EVIDENCE="$d"
    if m8_phase_a_invoke_adapter; then printf 'SIGKILLed adapter was accepted\n'; return 1; fi
    assert_eq "$(cat "$d/formal-execution-rc.txt")" '137' 'SIGKILL formal RC'
    assert_no_file "$d/adapter-exit-code.txt"
  )
}

v09() {
  # The closure receipt is the LAST mutating commit object.
  local log last
  log="$TMPROOT/v09-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    run_formal_success || return 1
    last="$(grep '^WRITE put-object ' "$log" | tail -n1)"
    case "$last" in
      *closure-receipt.json) ;;
      *) printf 'last mutating object was not the closure receipt: %s\n' "$last"; return 1 ;;
    esac
    assert_eq "$(grep -c '^WRITE put-object .*closure-receipt\.json' "$log")" '1' 'receipt write count'
  )
}

v10() {
  # Once the archive digest is fixed, mutating the archive must fail durability.
  local log
  log="$TMPROOT/v10-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    printf 'tamper\n' >>"$M8_ARCHIVE_LOCAL"
    if m8_phase_c_durability; then printf 'mutated archive passed durability\n'; return 1; fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v11() {
  # A durability failure must never materialize a closure receipt.
  local log
  log="$TMPROOT/v11-mutation.log"
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    export M8_FAKE_OSS_FAIL_PUT_KEY="$M8_OSS_BUCKET-placeholder"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    export M8_FAKE_OSS_FAIL_PUT_KEY="$PACKAGE_INDEX_OBJECT"
    if m8_phase_c_durability; then printf 'injected durability failure passed\n'; return 1; fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v12() {
  # Tampered receipt read-back => FAIL CLOSED, never "follow the tampered RC".
  local log tampered
  log="$TMPROOT/v12-mutation.log"
  tampered="$TMPROOT/tampered-receipt.json"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    populate_required_artifacts
    FORMAL_EXECUTION_RC=0
    m8_phase_a_validate || return 1
    m8_phase_b_seal || return 1
    m8_phase_c_durability || return 1
    printf '{"formal_command_rc": 0}\n' >"$tampered"
    export M8_FAKE_OSS_TAMPER_RECEIPT="$tampered"
    if m8_phase_d_commit; then printf 'tampered receipt read-back passed\n'; return 1; fi
    if m8_terminal_success; then printf 'formal RC emitted after tampered read-back\n'; return 1; fi
  )
}

v13() {
  # Success: fetched receipt RC == terminal marker == wrapper success.
  local out rc=0
  out="$TMPROOT/v13.out"
  (
    run_formal_success || return 1
    assert_eq "$(m8_json_get "$M8_SEAL_DIR/closure-receipt.readback.json" formal_command_rc)" '0' 'receipt formal_command_rc'
    assert_eq "$(m8_json_get "$M8_SEAL_DIR/closure-receipt.readback.json" closure_outcome)" 'PASS' 'receipt closure_outcome'
    local marker
    marker="$(m8_emit_formal_rc_marker "$RECEIPT_VERIFIED_SHA256" 0)" || return 1
    assert_eq "$marker" 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' 'terminal marker'
    if m8_emit_formal_rc_marker 'deadbeef' 0 >/dev/null; then
      printf 'marker emitted for a mismatched receipt digest\n'; return 1
    fi
    if m8_emit_formal_rc_marker "$RECEIPT_VERIFIED_SHA256" 1 >/dev/null; then
      printf 'marker emitted for a non-zero formal RC\n'; return 1
    fi
    # A tampered post-claim identity capture must fail the wrapper's own check.
    printf 'i-tampered\n' >"$EVIDENCE/provider-identity/reexec/instance-id.txt"
    if m8_phase_a_validate 2>/dev/null; then
      printf 'tampered post-claim identity capture was accepted\n'; return 1
    fi
    m8_terminal_success
  ) >"$out" 2>&1 || rc=$?
  (( rc == 0 )) || { printf 'success fixture failed (rc=%s):\n%s\n' "$rc" "$(tail -n6 "$out")"; return 1; }
  grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' "$out" ||
    { printf 'wrapper success did not emit the formal RC marker\n'; return 1; }
}

v14() {
  # A committed authorization hard-refuses and never re-emits the formal RC.
  local out rc=0
  out="$TMPROOT/v14.out"
  (
    run_formal_success || return 1
    if m8_already_committed_check; then printf 'committed authorization was accepted\n'; return 1; fi
    return 0
  ) >"$out" 2>&1 || rc=$?
  (( rc == 0 )) || { printf 'committed re-invocation probe failed:\n%s\n' "$(tail -n3 "$out")"; return 1; }
  grep -Fq 'ALREADY_COMMITTED' "$out" ||
    { printf 'no ALREADY_COMMITTED diagnostic was produced\n'; return 1; }
  # The refusal must happen before any execution or formal RC can be produced.
  local check_line execute_line
  check_line="$(grep -n '^  m8_already_committed_check || return 1' "$WRAPPER" | cut -d: -f1)"
  execute_line="$(grep -n '^  m8_phase_b_seal || return 1' "$WRAPPER" | cut -d: -f1)"
  (( check_line < execute_line )) ||
    { printf 'ALREADY_COMMITTED gate does not precede execution/seal\n'; return 1; }
  ! grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC=0' "$out" ||
    { printf 'formal RC marker emitted on an ALREADY_COMMITTED path\n'; return 1; }
}

v15() {
  # The adapter is not an independent formal runner.
  local root="$TMPROOT/v15-proof" out="$TMPROOT/v15.out" rc=0
  mkdir -p "$root/scripts/lib"
  cp -a "$REPO_ROOT/scripts/lib/." "$root/scripts/lib/"
  cp "$ADAPTER" "$root/scripts/run-m8-proof-alibaba-ecs.sh"
  cat >"$root/scripts/run-m8-proof-core.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'core-invoked\n' >>"${M8_CORE_SENTINEL:?}"
EOF
  export M8_CORE_SENTINEL="$TMPROOT/v15-core-invoked"
  M8_PROOF_ROOT="$root" bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1 || rc=$?
  (( rc != 0 )) || { printf 'adapter succeeded without wrapper context\n'; return 1; }
  assert_contains "$out" 'M8_ADAPTER_MODE=NONFORMAL'
  assert_contains "$out" 'M8_FORMAL_STATUS=NOT_APPLICABLE'
  assert_no_file "$M8_CORE_SENTINEL"
  assert_no_file "$root/proof-artifacts"
  assert_no_file "$root/candidate"
}

v16() {
  # An existing claim cannot be re-consumed, taken over or renewed.
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    local claimed_sha
    claimed_sha="$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" | cut -d' ' -f1)"
    if m8_claim_create; then printf 'existing claim was re-consumed\n'; return 1; fi
    assert_eq "$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" | cut -d' ' -f1)" \
      "$claimed_sha" 'claim object unchanged'
    assert_no_grep 'lease_token|takeover|fencing|expires_at|renewal_token' "$WRAPPER"
  )
}

# ===========================================================================
# V17..V26 — identity, claim, versioning, no-overwrite.
# ===========================================================================
v17() {
  local dup
  dup="$(grep -rn 'i-j6c9854oyawy89fcdxy2' "$REPO_ROOT/scripts" | grep -v 'lib/m8-provider-identity.sh' || true)"
  [[ -z "$dup" ]] || { printf 'provider identity duplicated outside the shared library:\n%s\n' "$dup"; return 1; }
  local const
  for const in EXPECTED_INSTANCE_ID EXPECTED_REGION_ID EXPECTED_ZONE_ID \
    EXPECTED_INSTANCE_TYPE EXPECTED_IMAGE_ID EXPECTED_IDENTITY_DOCUMENT_SHA256 \
    EXPECTED_IDENTITY_PKCS7_SHA256; do
    local count
    count="$(grep -rl "^readonly ${const}=" "$REPO_ROOT/scripts" | wc -l)"
    assert_eq "$count" '1' "$const definition count"
  done
  # The reviewed-tuple guard must fail closed even inside a condition context,
  # where bash suppresses errexit for the whole dynamic extent of the call.
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    if m8_provider_identity_assert 'i-tampered' "$EXPECTED_REGION_ID" "$EXPECTED_ZONE_ID" \
      "$EXPECTED_INSTANCE_TYPE" "$EXPECTED_IMAGE_ID" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" \
      "$EXPECTED_IDENTITY_PKCS7_SHA256" 2>/dev/null; then
      printf 'provider identity guard accepted a tampered instance id\n'
      return 1
    fi
    m8_provider_identity_assert "$EXPECTED_INSTANCE_ID" "$EXPECTED_REGION_ID" "$EXPECTED_ZONE_ID" \
      "$EXPECTED_INSTANCE_TYPE" "$EXPECTED_IMAGE_ID" "$EXPECTED_IDENTITY_DOCUMENT_SHA256" \
      "$EXPECTED_IDENTITY_PKCS7_SHA256"
  )
}

v18() {
  local body anchor missing=0 previous=0 current=0
  body="$TMPROOT/v18.wrapper-run"
  sed -n '/^m8_wrapper_run()/,/^}/p' "$WRAPPER" >"$body"
  # R2I-C4/B03 pre-claim contract order. Every trust-target check that can affect
  # where or how writes occur must precede the first mutating call (the claim).
  local -a ordered=(
    'm8_reject_synthetic_overrides || return 1'
    'm8_reject_oss_trust_environment || return 1'
    'm8_wrapper_init || return 1'
    'm8_guard_static_binding || return 1'
    'm8_guard_proof_checkout || return 1'
    'm8_guard_clean_start || return 1'
    'm8_oss_canonical_config_guard "$M8_PRECLAIM_DIR"'
    'm8_ossutil_identity_guard "$M8_PRECLAIM_DIR"'
    'm8_provider_identity_preclaim || return 1'
    'm8_oss_observe_ecs_role_name || return 1'
    'm8_prepare_oss_trust_profile || return 1'
    'm8_oss_capability_guard "$M8_PRECLAIM_DIR"'
    'm8_oss_bucket_location_guard "$M8_PRECLAIM_DIR"'
    'm8_oss_versioning_guard "$M8_PRECLAIM_DIR"'
    'm8_load_authorization || return 1'
    'm8_already_committed_check || return 1'
    'm8_claim_create || return 1'
    'm8_evidence_initialize || return 1'
  )
  for anchor in "${ordered[@]}"; do
    current="$(grep -n -F "$anchor" "$body" | head -n1 | cut -d: -f1)"
    [[ -n "$current" ]] || { printf 'wrapper ordering anchor not found: %s\n' "$anchor"; missing=1; continue; }
    (( current > previous )) ||
      { printf 'wrapper order violated at %s (line %s <= %s)\n' "$anchor" "$current" "$previous"; return 1; }
    previous="$current"
  done
  (( missing == 0 )) || return 1

  # Guards must fail closed even when called in a condition context.
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    if M8_OSS_BUCKET='NOT_A_VALID_BUCKET' m8_oss_require_config 2>/dev/null; then
      printf 'oss config guard accepted an invalid bucket\n'
      return 1
    fi
    if M8_OSSUTIL_BIN='/nonexistent/ossutil' M8_OSS_BUCKET='test-bucket' m8_oss_require_config 2>/dev/null; then
      printf 'oss config guard accepted a non-executable binary\n'
      return 1
    fi
  ) || return 1
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    local bad_core="$TMPROOT/v18-bad-core.sh"
    cat >"$bad_core" <<'EOF'
#!/usr/bin/env bash
printf 'candidate_sha=0000000000000000000000000000000000000000\n'
EOF
    M8_CORE_SCRIPT="$bad_core"
    if m8_guard_static_binding 2>/dev/null; then
      printf 'static binding guard accepted a tampered core binding\n'
      return 1
    fi
    M8_CORE_SCRIPT="$CORE"
    m8_guard_static_binding
  )
}

v19() {
  local body claim_line identity_line core_line
  body="$TMPROOT/v19.adapter"
  cp "$ADAPTER" "$body"
  claim_line="$(grep -n '^claim_verify$' "$body" | cut -d: -f1)"
  identity_line="$(grep -n '^provider_identity_reverify "\$CLAIM_FILE"$' "$body" | cut -d: -f1)"
  core_line="$(grep -n 'bash "\$CORE" || CORE_RC=\$?' "$body" | cut -d: -f1)"
  [[ -n "$claim_line" && -n "$identity_line" && -n "$core_line" ]] ||
    { printf 'adapter ordering anchors not found\n'; return 1; }
  (( claim_line < identity_line && identity_line < core_line )) ||
    { printf 'adapter must verify the claim, re-verify identity, then invoke the core\n'; return 1; }
  # The adapter holds no commit authority: it must create no canonical object.
  assert_no_grep 'm8_oss_put_object' "$ADAPTER"
  assert_no_grep 'closure-receipt|package-index|m8_archive_build|m8_manifest_generate' "$ADAPTER"
}

v20() {
  assert_grep 'forbid-overwrite true' "$OSS_LIB"
  assert_no_grep 'forbid-overwrite false' "$OSS_LIB"
  assert_no_grep 'head-object' "$WRAPPER"
  assert_grep 'm8_oss_put_object_no_overwrite' "$WRAPPER"
  # The capability guard must accept a fully capable client and fail closed on
  # one that cannot demonstrate --forbid-overwrite.
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/v20-oss"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    M8_FAKE_OSS_CAPABILITY=full m8_oss_capability_guard - || return 1
    if M8_FAKE_OSS_CAPABILITY=no-forbid-overwrite m8_oss_capability_guard - 2>/dev/null; then
      printf 'capability guard accepted a client without --forbid-overwrite\n'
      return 1
    fi
  )
}

v21() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/v21-oss" M8_FAKE_OSS_VERSIONING='enabled'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    if m8_oss_versioning_guard -; then printf 'versioning Enabled was accepted\n'; return 1; fi
  )
}

v22() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/v22-oss" M8_FAKE_OSS_VERSIONING='suspended'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    if m8_oss_versioning_guard -; then printf 'versioning Suspended was accepted\n'; return 1; fi
  )
}

v23() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    mkdir -p "$TMPROOT/v23-oss"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v23-oss"
    M8_FAKE_OSS_VERSIONING='unversioned' m8_oss_versioning_guard - || return 1
    M8_FAKE_OSS_VERSIONING='null' m8_oss_versioning_guard - || return 1
  )
}

v24() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    mkdir -p "$TMPROOT/v24-oss"
    export M8_FAKE_OSS_ROOT="$TMPROOT/v24-oss"
    if M8_FAKE_OSS_VERSIONING='garbage' m8_oss_versioning_guard -; then
      printf 'unparseable versioning response was accepted\n'; return 1
    fi
    if M8_FAKE_OSS_VERSIONING='denied' m8_oss_versioning_guard -; then
      printf 'access-denied versioning response was accepted\n'; return 1
    fi
  )
}

v25() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/v25-oss"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    local first="$TMPROOT/v25-a.txt" second="$TMPROOT/v25-b.txt" rc=0
    printf 'first\n' >"$first"
    printf 'second\n' >"$second"
    if m8_oss_put_object_no_overwrite 'runs/x/a.txt' "$first" -; then :; else rc=$?; fi
    assert_eq "$rc" '0' 'first put rc'
    rc=0
    if m8_oss_put_object_no_overwrite 'runs/x/a.txt' "$second" -; then :; else rc=$?; fi
    assert_eq "$rc" "$M8_OSS_EXISTS" 'second put rc'
    assert_eq "$(object_bytes 'runs/x/a.txt')" 'first' 'stored bytes'
  )
}

v26() {
  # The read-only versioning guard must precede the first PutObject.
  local log
  log="$TMPROOT/v26-mutation.log"
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/v26-oss" M8_FAKE_OSS_MUTATION_LOG="$log"
    export M8_FAKE_OSS_VERSIONING='unversioned'
    mkdir -p "$M8_FAKE_OSS_ROOT"
    local body="$TMPROOT/v26-body.txt"
    printf 'payload\n' >"$body"
    m8_oss_versioning_guard - || return 1
    m8_oss_put_object_no_overwrite 'authorizations/x/claim.json' "$body" - || return 1
    log="$log"
    local first_write first_read
    first_read="$(grep -n '^READ get-bucket-versioning' "$log" | head -n1 | cut -d: -f1)"
    first_write="$(grep -n '^WRITE put-object' "$log" | head -n1 | cut -d: -f1)"
    [[ -n "$first_read" && -n "$first_write" ]] || { printf 'mutation log anchors missing\n'; return 1; }
    (( first_read < first_write )) ||
      { printf 'a PutObject preceded the versioning guard\n'; return 1; }
  )
}

# ===========================================================================
# V27..V40 — Playwright runtime evidence, receipt commit, retry, policy.
# ===========================================================================
# ---------------------------------------------------------------------------
# Playwright JSON report mutations.
#
# The checked-in positive fixture is minimal and realistic: seven suites with
# Playwright testDir-relative `suite.file` values (`<name>.spec.ts`) and 34 spec
# objects. Every negative report is derived PROGRAMMATICALLY from it, so no
# near-duplicate fixture tree is maintained and no impossible-path fixture can
# drift from the contract.
# ---------------------------------------------------------------------------
mutate_playwright_report() {
  local mode=$1 out=$2
  "$PYTHON" - "$FIXTURES/playwright-json-good.json" "$out" "$mode" <<'PY'
import copy
import json
import sys

source, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]

if mode == "unparseable":
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("{ this is not a Playwright JSON report\n")
    raise SystemExit(0)

with open(source, encoding="utf-8") as handle:
    report = json.load(handle)

if mode == "bad-retries":
    report["config"]["projects"][0]["retries"] = 2
elif mode == "bad-project":
    report["config"]["projects"][0]["name"] = "firefox"
elif mode == "bad-stats":
    report["stats"]["expected"] = 33
    report["stats"]["unexpected"] = 1
    report["stats"]["flaky"] = 1
    report["stats"]["skipped"] = 1
elif mode == "drop-spec":
    report["suites"] = report["suites"][:-1]
elif mode == "duplicate-basename":
    extra = copy.deepcopy(report["suites"][0])
    extra["title"] = "vendor/golden-path.spec.ts"
    extra["file"] = "vendor/golden-path.spec.ts"
    for spec in extra["specs"]:
        spec["file"] = "vendor/golden-path.spec.ts"
    report["suites"].append(extra)
else:
    raise SystemExit("unknown Playwright mutation mode: %s" % mode)

with open(out, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

v27() {
  local out="$TMPROOT/v27-out.txt"
  local -a spec_args=()
  local spec
  for spec in "${PLAYWRIGHT_REPORT_SPECS[@]}"; do
    spec_args+=(--spec "$spec")
  done
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${spec_args[@]}" >/dev/null || return 1
  assert_eq "$(cat "$out")" 'PLAYWRIGHT_EFFECTIVE_RETRIES=0' 'effective retries content'
  assert_eq "$(wc -c <"$out")" "$(printf 'PLAYWRIGHT_EFFECTIVE_RETRIES=0\n' | wc -c)" 'effective retries byte length'
  # The positive fixture must reproduce the live Playwright testDir-relative
  # suite.file namespace, not the CLI/path namespace.
  assert_contains "$FIXTURES/playwright-json-good.json" '"file": "golden-path.spec.ts"'
  assert_no_contains "$FIXTURES/playwright-json-good.json" '"file": "e2e/'
  assert_no_contains "$FIXTURES/playwright-json-good.json" 'apps/web/e2e'
}

v28() {
  local out="$TMPROOT/v28-out.txt" report="$TMPROOT/v28-report.json"
  mutate_playwright_report bad-retries "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'retries != 0 was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v29() {
  local out="$TMPROOT/v29-out.txt" report="$TMPROOT/v29-report.json"
  mutate_playwright_report bad-project "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'non-chromium project was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v30() {
  local out="$TMPROOT/v30-out.txt" report="$TMPROOT/v30-report.json"
  mutate_playwright_report bad-stats "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'flaky/expected mismatch was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v31() {
  local out="$TMPROOT/v31-out.txt" report="$TMPROOT/v31-unparseable.json"
  mutate_playwright_report unparseable "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" >/dev/null 2>&1; then
    printf 'unparseable report was accepted\n'
    return 1
  fi
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$TMPROOT/absent-report.json" --out "$out" >/dev/null 2>&1; then
    printf 'missing report was accepted\n'
    return 1
  fi
  assert_no_file "$out"
}

v32() {
  local body="$TMPROOT/v32-browser"
  sed -n '/^browser_e2e()/,/^}/p' "$CORE" >"$body"
  assert_eq "$(grep -c -- '--reporter' "$body")" '1' 'single reporter option in the browser stage'
  assert_grep '--reporter=list,json' "$body"
  assert_grep 'export CI=1' "$body"
  assert_grep 'PLAYWRIGHT_JSON_OUTPUT_FILE=' "$body"
  assert_grep 'verify-m8-playwright-json\.py' "$body"
}

v33() {
  assert_grep '--retries=0' "$CORE"
  assert_grep '--fail-on-flaky-tests' "$CORE"
  assert_eq "$(grep -oE 'e2e/[a-z-]+\.spec\.ts' "$CORE" | sort -u | wc -l)" '7' 'seven frozen specs'
  local spec
  for spec in golden-path unicode segmentation token-segmentation lemma-annotation \
    pos-annotation workbench-information-architecture; do
    assert_contains "$CORE" "e2e/$spec.spec.ts"
  done
}

v34() {
  local missing_root="$TMPROOT/v34-missing" full_root="$TMPROOT/v34-full"
  mkdir -p "$missing_root/sub"
  printf 'x\n' >"$missing_root/a.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$missing_root" --required "$REQUIRED_LIST" >/dev/null 2>&1; then
    printf 'incomplete evidence root was accepted\n'
    return 1
  fi
  populate_required_root "$full_root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$full_root" --required "$REQUIRED_LIST" >/dev/null || return 1
  # A required list that is entirely comments is refused.
  printf '# nothing\n\n' >"$TMPROOT/v34-empty-list.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$full_root" --required "$TMPROOT/v34-empty-list.txt" >/dev/null 2>&1; then
    printf 'empty required list was accepted\n'
    return 1
  fi
}

v35() {
  local receipt="$TMPROOT/v35-receipt.json"
  (
    run_formal_success || return 1
    cp "$M8_SEAL_DIR/closure-receipt.readback.json" "$receipt"
    assert_no_grep 'terminal_line' "$receipt"
    "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" --receipt "$receipt" >/dev/null || return 1
    "$PYTHON" - "$receipt" "$TMPROOT/v35-tampered.json" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["terminal_line"] = "HSDR_F02_FORMAL_RUN_COMMAND_RC=0"
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
    if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$TMPROOT/v35-tampered.json" >/dev/null 2>&1; then
      printf 'receipt with terminal_line was accepted\n'
      return 1
    fi
  )
}

v36() {
  (
    run_formal_success || return 1
    local receipt="$M8_SEAL_DIR/closure-receipt.readback.json"
    "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$receipt" \
      --expect-sha256 "$RECEIPT_VERIFIED_SHA256" \
      --expect-proof-sha "$APPROVED_PROOF_SHA" \
      --expect-candidate-sha '2441f9cf60b7cc9402c5b257be010b559b39b717' \
      --expect-authorization-sha "$AUTH" \
      --expect-archive-sha256 "$SEALED_ARCHIVE_SHA256" >/dev/null || return 1
    # Cross-binding and provider digest fields must be present and consistent.
    assert_eq "$(m8_json_get "$receipt" cross_binding.sealed_archive_sha256)" \
      "$(m8_json_get "$receipt" archive_sha256)" 'sealed archive cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.package_index_archive_sha256)" \
      "$(m8_json_get "$receipt" archive_sha256)" 'package index cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.manifest_sha256)" \
      "$(m8_json_get "$receipt" artifact_manifest_sha256)" 'manifest cross-binding'
    assert_eq "$(m8_json_get "$receipt" cross_binding.claim_object_sha256)" \
      "$(m8_json_get "$receipt" claim_sha256)" 'claim cross-binding'
    # B1/B5: the issued-DOCUMENT digest is the separate cross-bound field, while
    # authorization_sha256 is the token identity and must not be the document
    # digest.
    assert_eq "$(m8_json_get "$receipt" cross_binding.issued_document_sha256)" \
      "$(m8_json_get "$receipt" issued_document_sha256)" 'issued document cross-binding'
    assert_eq "$(m8_json_get "$receipt" issued_document_sha256)" \
      "$(sha256sum "$M8_PRECLAIM_DIR/issued.json" | cut -d' ' -f1)" 'issued document digest'
    assert_eq "$(m8_json_get "$receipt" authorization_sha256)" "$AUTH" 'token authorization identity'
    [[ "$(m8_json_get "$receipt" authorization_sha256)" != \
      "$(m8_json_get "$receipt" issued_document_sha256)" ]] ||
      { printf 'authorization_sha256 was conflated with the issued-document digest\n'; return 1; }
    assert_eq "$(m8_json_get "$receipt" provider_identity.instance_id)" \
      "$EXPECTED_INSTANCE_ID" 'provider instance binding'
    assert_eq "$(m8_json_get "$receipt" provider_identity.identity_document_sha256)" \
      "$EXPECTED_IDENTITY_DOCUMENT_SHA256" 'provider document digest binding'
    # Every canonical receipt field is materialised by the wrapper builder.
    local field
    while IFS= read -r field; do
      case "$field" in '' | '#'*) continue ;; esac
      m8_json_get "$receipt" "$field" >/dev/null ||
        { printf 'canonical receipt field is absent: %s\n' "$field"; return 1; }
    done <"$REPO_ROOT/scripts/lib/m8-receipt-fields.txt"
  )
}

v37() {
  (
    run_formal_success || return 1
    local receipt="$M8_SEAL_DIR/closure-receipt.readback.json" tampered="$TMPROOT/v37-tampered.json"
    "$PYTHON" - "$receipt" "$tampered" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["formal_command_rc"] = 1
with open(out, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
    if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-closure-receipt.py" \
      --receipt "$tampered" >/dev/null 2>&1; then
      printf 'receipt with formal_command_rc=1 was accepted\n'
      return 1
    fi
  )
}

# Executable lines only: a comment that merely documents a prohibition is not a
# capability. A trailing comment on a real call would still be detected.
code_only() { grep -v '^[[:space:]]*#' "$1"; }

v38() {
  assert_contains "$REPO_ROOT/README.md" 'ISSUER'
  assert_contains "$REPO_ROOT/README.md" 'EXECUTOR'
  local pattern='DeleteObject|delete-object|PutBucketVersioning|put-bucket-versioning'
  assert_no_grep "$pattern" <(code_only "$OSS_LIB")
  assert_no_grep "$pattern" <(code_only "$WRAPPER")
  assert_no_grep "$pattern" <(code_only "$ADAPTER")
  assert_no_grep "$pattern" <(code_only "$CORE")
  # Controls: the filter must not hide a real call, and must drop pure comments.
  local control="$TMPROOT/v38-control.sh"
  printf '# delete-object only in a comment\nossutil api delete-object --bucket b\n' >"$control"
  grep -Eq -e 'delete-object' <(code_only "$control") ||
    { printf 'control: a real delete-object call was not detected\n'; return 1; }
  printf '# PutBucketVersioning only in a comment\n' >"$control"
  if grep -Eq -e 'PutBucketVersioning' <(code_only "$control"); then
    printf 'control: a comment-only mention was not filtered\n'
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Durability-retry fixture.
# ---------------------------------------------------------------------------
bootstrap_retry_fixture() {
  # shellcheck source=lib/m8-provider-identity.sh
  source "$IDENTITY_LIB"
  # shellcheck source=lib/m8-manifest.sh
  source "$MANIFEST_LIB"

  SB="$(mktemp -d "$TMPROOT/rt.XXXXXX")"
  PROOF="$SB/proof"
  HOST="$SB/host"
  EVIDENCE="$PROOF/proof-artifacts"
  FAKE_ROOT="$SB/oss"
  mkdir -p "$PROOF" "$HOST" "$FAKE_ROOT/objects"
  cp -a "$REPO_ROOT/scripts" "$PROOF/scripts"
  git -C "$PROOF" init -q
  git -C "$PROOF" add -A >/dev/null
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$PROOF" commit -qm 'synthetic retry fixture' >/dev/null
  APPROVED_PROOF_SHA="$(git -C "$PROOF" rev-parse HEAD)"
  APPROVED_PROOF_TREE="$(git -C "$PROOF" rev-parse HEAD^{tree})"
  export APPROVED_PROOF_SHA APPROVED_PROOF_TREE
  export M8_PROOF_ROOT="$PROOF" M8_PROOF_HOST_STATE="$HOST" M8_PROOF_EVIDENCE_DIR="$EVIDENCE"
  export M8_SYNTHETIC_TEST_MODE=1 M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$FAKE_ROOT" M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_FAKE_OSS_LOCATION='cn-hongkong'
  export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"
  export M8_IMDS_CURL_BIN="$(write_fake_imds_client)"
  export M8_IMDS_BASE_URL='http://imds.invalid/latest'
  export M8_FAKE_IMDS_ROLE_MODE='one'
  export M8_FAKE_IMDS_ROLE_NAME='LinguaGraphM8ProofExecutor'

  # R2I-C4/B03: derive the exact trust-profile digest the production guards will
  # compute, in an isolated subshell so the fixture cannot drift from the real
  # serialization implementation.
  PROFILE_SHA="$( (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/run-m8-proof.sh"
    m8_wrapper_init >/dev/null 2>&1 || exit 1
    establish_oss_trust_target >/dev/null 2>&1 || exit 1
    printf '%s' "$OSS_TRUST_PROFILE_SHA256"
  ) )" || return 1
  [[ "$PROFILE_SHA" =~ ^[0-9a-f]{64}$ ]] || return 1
  export PROFILE_SHA

  # A pre-existing sealed semantic run: archive + package index.
  SEMANTIC_AUTH="$(printf 'semantic-authorization' | sha256sum | cut -d' ' -f1)"
  SEAL_DIR="$HOST/sealed/$SEMANTIC_AUTH"
  ARCHIVE_NAME="m8-proof-artifacts-$APPROVED_PROOF_SHA-$SEMANTIC_AUTH.tar.gz"
  ARCHIVE_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/$ARCHIVE_NAME"
  PACKAGE_INDEX_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/package-index.json"
  RECEIPT_OBJECT="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH/closure-receipt.json"
  ARCHIVE_LOCAL="$SEAL_DIR/$ARCHIVE_NAME"
  PACKAGE_INDEX_LOCAL="$SEAL_DIR/package-index.json"

  local archive_root="$SB/sealed-root"
  mkdir -p "$archive_root/proof-artifacts"
  printf 'sealed artifact\n' >"$archive_root/proof-artifacts/payload.txt"
  m8_manifest_generate "$archive_root/proof-artifacts"
  mkdir -p "$SEAL_DIR"
  m8_archive_build "$archive_root" 'proof-artifacts' "$ARCHIVE_LOCAL" || return 1
  local archive_sha manifest_sha archive_size
  archive_sha="$(sha256sum "$ARCHIVE_LOCAL" | cut -d' ' -f1)"
  archive_size="$(wc -c <"$ARCHIVE_LOCAL" | tr -d '[:space:]')"
  manifest_sha="$(sha256sum "$archive_root/proof-artifacts/artifact-manifest.sha256" | cut -d' ' -f1)"
  "$PYTHON" - "$PACKAGE_INDEX_LOCAL" "$archive_sha" "$archive_size" "$manifest_sha" \
    "$ARCHIVE_NAME" "$ARCHIVE_OBJECT" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" \
    "$SEMANTIC_AUTH" "${M8_RETRY_FIXTURE_INDEX_PROFILE_SHA:-$PROFILE_SHA}" <<'PY'
import json
import sys

(out, archive_sha, archive_size, manifest_sha, archive_name, archive_object,
 proof_sha, proof_tree, semantic_auth, profile_sha) = sys.argv[1:11]
document = {
    "schema": "linguagraph-m8-package-index/v1",
    "authorization_kind": "SEMANTIC",
    "authorization_sha256": semantic_auth,
    "semantic_auth_sha256": semantic_auth,
    "retry_auth_sha256": None,
    "oss_trust_profile_sha256": profile_sha,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "archive": {
        "name": archive_name,
        "object": archive_object,
        "sha256": archive_sha,
        "size_bytes": int(archive_size),
    },
    "artifact_manifest": {"name": "artifact-manifest.sha256", "sha256": manifest_sha},
    "exit_codes": {"core": 0, "adapter": 0, "formal_execution": 0},
    "playwright_effective_retries": 0,
    "artifacts": [],
    "execution_started_utc": "2026-01-01T00:00:00Z",
    "sealed_utc": "2026-01-01T00:05:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
  local package_index_sha
  package_index_sha="$(sha256sum "$PACKAGE_INDEX_LOCAL" | cut -d' ' -f1)"

  RETRY_ISSUED="$SB/retry-issued.json"
  RETRY_TOKEN='M8-EXI-01-RETRY-SYNTHETIC-TOKEN'
  RETRY_AUTH="$(printf '%s' "$RETRY_TOKEN" | sha256sum | cut -d' ' -f1)"
  "$PYTHON" - "$RETRY_ISSUED" "$APPROVED_PROOF_SHA" "$APPROVED_PROOF_TREE" \
    "$SEMANTIC_AUTH" "$archive_sha" "$package_index_sha" "$ARCHIVE_NAME" "$RETRY_AUTH" \
    "$PROFILE_SHA" <<'PY'
import json
import sys

(out, proof_sha, proof_tree, semantic_auth, archive_sha,
 package_index_sha, archive_name, retry_auth, profile_sha) = sys.argv[1:10]
document = {
    "schema": "linguagraph-m8-durability-retry-authorization/v1",
    "authorization_kind": "DURABILITY_RETRY",
    "authorization_id": "M8-EXI-01-RETRY-SYNTHETIC",
    "authorization_sha256": retry_auth,
    "oss_trust_profile_sha256": profile_sha,
    "semantic_auth_sha256": semantic_auth,
    "proof_sha": proof_sha,
    "proof_tree": proof_tree,
    "candidate_sha": "2441f9cf60b7cc9402c5b257be010b559b39b717",
    "candidate_tree": "5d1b7c7cc104cd365b0ea629d9ead7677d17f2be",
    "candidate_parent": "e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d",
    "frozen_main": "cf26ea557bd746a518ff32b8b7e7a7542be7f7ae",
    "provider_identity": {
        "instance_id": "i-j6c9854oyawy89fcdxy2",
        "region_id": "cn-hongkong",
        "zone_id": "cn-hongkong-d",
        "instance_type": "ecs.g9i.xlarge",
        "image_id": "ubuntu_24_04_x64_20G_alibase_20260916.vhd",
        "identity_document_sha256": "60f62ad9f4c10aab718bdc6dfdf0c57e1e4ced293908417009df8e4b7dbdaa1d",
        "identity_pkcs7_sha256": "89185b286e03b344a5ca7e2f3a242baf4b454419dab0cd83ec3426981860d211",
    },
    "authorized_executor_id": "alibaba-ecs:i-j6c9854oyawy89fcdxy2",
    "single_use": True,
    "run_prefix": "runs/%s/%s" % (proof_sha, semantic_auth),
    "archive_name": archive_name,
    "archive_sha256": archive_sha,
    "package_index_sha256": package_index_sha,
    "issued_utc": "2026-01-02T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

  export M8_PROOF_RETRY_AUTHORIZATION="$RETRY_TOKEN"
  stage_object "authorizations/$RETRY_AUTH/issued.json" "$RETRY_ISSUED"

  M8_PRECLAIM_DIR="$HOST/preclaim/$RETRY_AUTH"
  export M8_PRECLAIM_DIR SEAL_DIR SB PROOF HOST EVIDENCE FAKE_ROOT
  export SEMANTIC_AUTH RETRY_AUTH RETRY_TOKEN ARCHIVE_LOCAL PACKAGE_INDEX_LOCAL
  export ARCHIVE_NAME ARCHIVE_OBJECT PACKAGE_INDEX_OBJECT RECEIPT_OBJECT
}

run_retry_success() {
  bootstrap_retry_fixture
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/run-m8-proof.sh"
  m8_wrapper_init
  m8_guard_local_syntax || return 1
  establish_oss_trust_target || return 1
  [[ "$OSS_TRUST_PROFILE_SHA256" == "$PROFILE_SHA" ]] || return 1
  m8_load_authorization || return 1
  m8_claim_create || return 1
  m8_evidence_initialize || return 1
  m8_phase_b_seal || return 1
  m8_phase_c_durability || return 1
  m8_phase_d_commit || return 1
}

v39() {
  # A retry with a missing local package-index is NOT eligible and must not
  # regenerate it or produce a receipt.
  (
    bootstrap_retry_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    rm -f "$M8_PACKAGE_INDEX_LOCAL"
    if m8_phase_b_seal; then printf 'retry with missing package-index was eligible\n'; return 1; fi
    assert_no_file "$PACKAGE_INDEX_LOCAL"
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  )
}

v40() {
  # A retry never reruns core/adapter and writes only the allowed objects.
  local log rc=0
  log="$TMPROOT/v40-mutation.log"
  (
    export M8_FAKE_OSS_MUTATION_LOG="$log"
    run_retry_success || return 1
    assert_no_file "$EVIDENCE/stages.txt"
    assert_no_file "$EVIDENCE/adapter-raw.log"
    assert_no_file "$EVIDENCE/outcome.txt"
    local line key
    while IFS= read -r line; do
      case "$line" in
        'WRITE put-object '*)
          key="${line#WRITE put-object }"
          case "$key" in
            "$ARCHIVE_OBJECT" | "$PACKAGE_INDEX_OBJECT" | "$RECEIPT_OBJECT" | "$CLAIM_OBJECT") ;;
            *) printf 'retry wrote a non-canonical object: %s\n' "$key"; return 1 ;;
          esac
          ;;
      esac
    done <"$log"
    assert_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
    # Static: the retry branch never invokes the semantic execution phase.
    local body
    body="$TMPROOT/v40.wrapper-run"
    sed -n '/DURABILITY_RETRY) : ;; #/,/^  esac/p' "$WRAPPER" >"$body"
    assert_grep 'DURABILITY_RETRY' "$body"
    assert_no_grep 'm8_phase_a' "$body"
  ) || rc=$?
  (( rc == 0 )) || return 1

  # A retry is allowed on the host that still holds the failed semantic run's
  # evidence tree, and must leave that tree byte-identical.
  (
    bootstrap_retry_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    mkdir -p "$EVIDENCE"
    printf 'failed-semantic-run-evidence\n' >"$EVIDENCE/payload.txt"
    printf 'FAIL exit=1\n' >"$EVIDENCE/outcome.txt"
    local before
    before="$(cd "$EVIDENCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
    m8_guard_clean_start || { printf 'retry was blocked by the failed run evidence tree\n'; return 1; }
    m8_load_authorization || return 1
    m8_claim_create || return 1
    m8_evidence_initialize || return 1
    m8_phase_b_seal || return 1
    m8_phase_c_durability || return 1
    m8_phase_d_commit || return 1
    assert_eq "$(cd "$EVIDENCE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" \
      "$before" 'sealed evidence tree unchanged by retry'
  ) || rc=$?
  (( rc == 0 )) || return 1

  # The semantic path still refuses a pre-existing evidence tree.
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    mkdir -p "$EVIDENCE"
    if m8_guard_clean_start; then
      printf 'a semantic run accepted a pre-existing evidence tree\n'
      return 1
    fi
  )
}

# ===========================================================================
# R2E-B01 correction regressions (C01..C09). These are separate from the legacy
# V01..V40 baseline: a green V01..V40 alone is not sufficient evidence.
# ===========================================================================

assert_required_list_reject() {
  local root=$1 list=$2 pattern=$3 out='' rc=0
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$list" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'required list was accepted: %s\n' "$list"; return 1; }
  grep -Fq -- "$pattern" <<<"$out" ||
    { printf 'missing diagnostic %s for %s:\n%s\n' "$pattern" "$list" "$out"; return 1; }
  return 0
}

assert_manifest_reject() {
  local root=$1 manifest=$2 pattern=$3 out='' rc=0
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" --manifest "$manifest" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'manifest was accepted: %s\n' "$manifest"; return 1; }
  grep -Fq -- "$pattern" <<<"$out" ||
    { printf 'missing diagnostic %s for %s:\n%s\n' "$pattern" "$manifest" "$out"; return 1; }
  return 0
}

# C01 — authorization_sha256 = SHA256(exact Human-issued TOKEN).
c01() {
  # The needle is assembled at runtime so this check cannot match itself.
  local needle='issued_json_content''_sha256' hits
  hits="$(grep -rn "$needle" "$REPO_ROOT/scripts" \
    "$REPO_ROOT/tests/run-static-verification.sh" || true)"
  [[ -z "$hits" ]] ||
    { printf 'self-referential issued.json digest remains:\n%s\n' "$hits"; return 1; }
  # Static: the adapter derives the presented token's digest itself and compares
  # the DIGEST with the context; the raw token is never compared with, or
  # written beside, the context digest.
  assert_contains "$ADAPTER" 'presented_sha='
  assert_no_contains "$ADAPTER" 'expect "$presented" "$authorization_sha"'
  assert_contains "$WRAPPER" 'm8_sha256_token'
  (
    bootstrap_formal_fixture || return 1
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1

    # Two distinct tokens with IDENTICAL issued-document byte content derive
    # different authorization_sha256 object paths, and neither path is the
    # document digest.
    local doc="$TMPROOT/c01-identical-doc.json" sha_a sha_b doc_sha
    printf '{"schema": "linguagraph-m8-run-authorization/v1"}\n' >"$doc"
    sha_a="$(m8_sha256_token 'm8-token-alpha')"
    sha_b="$(m8_sha256_token 'm8-token-beta')"
    assert_eq "$(wc -c <"$doc")" "$(wc -c <"$doc")" 'identical document bytes'
    [[ "$sha_a" != "$sha_b" ]] ||
      { printf 'distinct tokens produced the same authorization identity\n'; return 1; }
    [[ "authorizations/$sha_a/issued.json" != "authorizations/$sha_b/issued.json" ]] ||
      { printf 'the token identity does not determine the object path\n'; return 1; }
    doc_sha="$(sha256sum "$doc" | cut -d' ' -f1)"
    [[ "$doc_sha" != "$sha_a" && "$doc_sha" != "$sha_b" ]] ||
      { printf 'authorization identity is still derived from document bytes\n'; return 1; }

    # A document that does not BIND the presented token digest FAILS CLOSED.
    stage_object "authorizations/$sha_a/issued.json" "$doc"
    export M8_PROOF_RUN_AUTHORIZATION='m8-token-alpha'
    if m8_guard_local_syntax && m8_load_authorization 2>/dev/null; then
      printf 'a document without the token binding was accepted\n'
      return 1
    fi

    # The correctly bound document is accepted, at the token-derived path, even
    # though its own bytes do not hash to the authorization identity.
    stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
    export M8_PROOF_RUN_AUTHORIZATION="$SEMANTIC_TOKEN"
    m8_guard_local_syntax || return 1
    m8_load_authorization || return 1
    assert_eq "$AUTHORIZATION_SHA256" "$AUTH" 'token-derived authorization identity'
    assert_eq "$ISSUED_OBJECT" "authorizations/$AUTH/issued.json" 'token-derived object path'
    assert_eq "$ISSUED_DOCUMENT_SHA256" "$(sha256sum "$ISSUED_LOCAL" | cut -d' ' -f1)" \
      'issued-document byte identity'
    [[ "$AUTHORIZATION_SHA256" != "$ISSUED_DOCUMENT_SHA256" ]] ||
      { printf 'authorization identity was conflated with the document digest\n'; return 1; }
  )
}

# C02 — a mismatched issued.json.authorization_sha256 FAILS CLOSED.
c02() {
  (
    bootstrap_formal_fixture || return 1
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    establish_oss_trust_target || return 1
    stage_semantic_issued_json || return 1

    local mismatched="$TMPROOT/c02-mismatched-issued.json"
    "$PYTHON" - "$ISSUED_LOCAL" "$mismatched" <<'PY'
import json
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["authorization_sha256"] = "0" * 64
with open(out, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    stage_object "authorizations/$AUTH/issued.json" "$mismatched"
    m8_guard_local_syntax || return 1
    if m8_load_authorization 2>/dev/null; then
      printf 'mismatched issued authorization_sha256 was accepted\n'
      return 1
    fi
    # The exact-byte self-reference is gone: the fixture document bytes do NOT
    # hash to $AUTH, yet a correctly bound document loads.
    [[ "$(sha256sum "$ISSUED_LOCAL" | cut -d' ' -f1)" != "$AUTH" ]] ||
      { printf 'fixture document digest accidentally equals the token identity\n'; return 1; }
    stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
    m8_load_authorization || return 1
  )
}

# C03 — every production override seam is rejected by both production entrypoints.
c03() {
  local name out rc=0
  local -a unset_args=()
  for name in "${SYNTHETIC_SEAM_VARS[@]}" "${OSS_TRUST_ENV_VARS[@]}"; do
    unset_args+=(-u "$name")
  done

  # The seam set is single-sourced in the shared library.
  assert_eq "$(grep -rl 'readonly -a M8_SYNTHETIC_SEAM_VARS=' "$REPO_ROOT/scripts" | wc -l)" \
    '1' 'seam declaration count'
  assert_contains "$WRAPPER" 'm8_reject_synthetic_overrides'
  assert_contains "$ADAPTER" 'm8_reject_synthetic_overrides'

  for name in "${SYNTHETIC_SEAM_VARS[@]}"; do
    rc=0
    out="$(env "${unset_args[@]}" "$name=seam-probe" bash "$WRAPPER" 2>&1)" || rc=$?
    (( rc != 0 )) || { printf '%s did not make the formal wrapper fail closed\n' "$name"; return 1; }
    grep -Fq "$name is set" <<<"$out" ||
      { printf '%s: no seam diagnostic was produced\n%s\n' "$name" "$out"; return 1; }
    grep -Fq 'refuses offline synthetic overrides' <<<"$out" ||
      { printf '%s: unexpected refusal path\n%s\n' "$name" "$out"; return 1; }
    ! grep -Fq 'missing single-use authorization' <<<"$out" ||
      { printf '%s: the guard did not precede the authorization check\n' "$name"; return 1; }
    ! grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC' <<<"$out" ||
      { printf '%s: a formal marker was emitted on a rejected invocation\n' "$name"; return 1; }
    ! grep -Fq 'M8_SYNTHETIC_OUTCOME=OK' <<<"$out" ||
      { printf '%s: synthetic success was reported on a rejected invocation\n' "$name"; return 1; }
  done

  # Direct production execution of the adapter must refuse the same seven seams
  # before its formal-context guards.
  for name in "${SYNTHETIC_SEAM_VARS[@]}"; do
    rc=0
    out="$(env "${unset_args[@]}" "$name=seam-probe" bash "$ADAPTER" 2>&1)" || rc=$?
    (( rc != 0 )) || { printf '%s did not make the adapter fail closed\n' "$name"; return 1; }
    grep -Fq "$name is set" <<<"$out" ||
      { printf 'adapter %s: no seam diagnostic\n%s\n' "$name" "$out"; return 1; }
    ! grep -Fq 'M8_ADAPTER_MODE=' <<<"$out" ||
      { printf 'adapter %s: a formal/nonformal mode was declared\n' "$name"; return 1; }
  done

  # The clean formal path is NOT blocked: with every seam unset the wrapper still
  # reaches its authorization guard.
  rc=0
  out="$(env "${unset_args[@]}" bash "$WRAPPER" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'the clean formal path unexpectedly succeeded\n'; return 1; }
  grep -Fq 'missing single-use authorization' <<<"$out" ||
    { printf 'the clean formal path did not reach the authorization guard\n%s\n' "$out"; return 1; }
  return 0
}

# C04 — the JSON-report contract uses the Playwright testDir-relative suite.file
# namespace (direct C15 regression).
c04() {
  local out="$TMPROOT/c04-out.txt" report="$TMPROOT/c04-report.json" body="$TMPROOT/c04-browser"
  local -a report_args=() wrong_args=()
  local spec
  for spec in "${PLAYWRIGHT_REPORT_SPECS[@]}"; do
    report_args+=(--spec "$spec")
  done
  for spec in "${PLAYWRIGHT_INVOCATION_SPECS[@]}"; do
    wrong_args+=(--spec "$spec")
  done
  # A. Patched positive fixture + exact testDir-relative expected specs: PASS.
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${report_args[@]}" >/dev/null || return 1
  # B. The old, wrong `e2e/...` expectation must FAIL and leave no evidence.
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$FIXTURES/playwright-json-good.json" --out "$out" \
    "${wrong_args[@]}" >/dev/null 2>&1; then
    printf 'e2e/... expectations were accepted for a testDir-relative report\n'
    return 1
  fi
  assert_no_file "$out"
  # C. An extra nested duplicate basename must not satisfy the spec set.
  mutate_playwright_report duplicate-basename "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" "${report_args[@]}" >/dev/null 2>&1; then
    printf 'a duplicated spec basename in another directory was accepted\n'
    return 1
  fi
  assert_no_file "$out"
  # D. A dropped frozen spec must FAIL.
  mutate_playwright_report drop-spec "$report"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-playwright-json.py" \
    --report "$report" --out "$out" "${report_args[@]}" >/dev/null 2>&1; then
    printf 'a missing frozen spec was accepted\n'
    return 1
  fi
  assert_no_file "$out"
  # E. Static: execution uses the invocation namespace, verification uses the
  # reporter namespace, and the core never re-prefixes, strips or widens it.
  sed -n '/^browser_e2e()/,/^}/p' "$CORE" >"$body"
  assert_contains "$body" '"${PLAYWRIGHT_INVOCATION_SPECS[@]}"'
  assert_contains "$body" 'for spec in "${PLAYWRIGHT_REPORT_SPECS[@]}"'
  assert_contains "$body" 'spec_args+=(--spec "$spec")'
  assert_no_contains "$body" 'PLAYWRIGHT_SPECS'
  assert_no_contains "$body" 'apps/web/$spec'
  assert_no_contains "$body" 'apps/web/e2e'
}

# C05 — every PutObject uses the official file:// body form.
c05() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    export M8_PROOF_ROOT="$REPO_ROOT"
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/c05-oss" M8_FAKE_OSS_VERSIONING='unversioned'
    export M8_FAKE_OSS_BODY_LOG="$TMPROOT/c05-body.log"
    mkdir -p "$M8_FAKE_OSS_ROOT"
    : >"$M8_FAKE_OSS_BODY_LOG"
    local body="$TMPROOT/c05-body.txt"
    printf 'file-body-payload\n' >"$body"
    m8_oss_put_object_no_overwrite 'runs/c05/body.txt' "$body" - || return 1
    assert_eq "$(cat "$M8_FAKE_OSS_BODY_LOG")" "file://$body" 'exact file:// body argument'
    assert_eq "$(object_bytes 'runs/c05/body.txt')" 'file-body-payload' 'stored body bytes'
    # The stub refuses a bare local path, so a regression cannot pass silently.
    if "$FAKE_OSSUTIL" api put-object --bucket test-bucket --key runs/c05/bare.txt \
      --body "$body" --forbid-overwrite true >/dev/null 2>&1; then
      printf 'the synthetic ossutil accepted a bare --body path\n'
      return 1
    fi
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/test-bucket/runs/c05/bare.txt"
    # Static: the official form is used and the bare form is absent.
    assert_contains "$OSS_LIB" '--body "file://$file"'
    assert_no_contains "$OSS_LIB" '--body "$file"'
    # GetObject response framing (R2I-C13). A bare stdout->file redirect is NOT
    # byte-exact on its own: live ossutil 2.4.0 appends a non-body elapsed footer
    # to ordinary get-object stdout. The production helper must therefore frame
    # the call with get-object --quiet, while the body still travels straight
    # from ossutil stdout into the file -- never through command substitution --
    # and is installed with an atomic rename.
    local get_body="$TMPROOT/c05-get-object"
    sed -n '/^m8_oss_get_object()/,/^}/p' "$OSS_LIB" >"$get_body"
    assert_contains "$get_body" 'get-object --quiet'
    assert_contains "$get_body" '>"$tmp" 2>"${tmp}.stderr"'
    assert_no_contains "$get_body" '=$(m8_oss_api'
    assert_contains "$get_body" 'mv -f "$tmp" "$out"'
  )
}

# C06 — completeness rejects an unexpected/unclassified artifact.
c06() {
  local root="$TMPROOT/c06-root" out='' rc=0
  populate_required_root "$root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null || return 1
  printf 'stray\n' >"$root/unclassified-artifact.txt"
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'an unexpected artifact was accepted\n'; return 1; }
  grep -Fq 'unexpected unclassified artifact' <<<"$out" ||
    { printf 'missing unexpected-artifact diagnostic:\n%s\n' "$out"; return 1; }
  rm -f "$root/unclassified-artifact.txt"
  rm -f "$root/outcome.txt"
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null 2>&1; then
    printf 'a missing required artifact was accepted\n'
    return 1
  fi
  # The required set must carry exactly one evidence log per core stage(), so the
  # explicit inventory cannot silently fall behind the semantic core.
  local stage_logs expected_logs
  expected_logs="$(grep -oE '^stage [a-z_]+' "$CORE" | awk '{print $2".log"}' | sort -u)"
  stage_logs="$(grep -E '^[a-z_]+\.log$' "$REQUIRED_LIST" | sort -u)"
  [[ -n "$expected_logs" ]] || { printf 'no core stage() invocations were found\n'; return 1; }
  assert_eq "$stage_logs" "$expected_logs" 'stage evidence logs'
}

# C07 — required-list validation: duplicates, absolute, traversal, globs.
c07() {
  local root="$TMPROOT/c07-root" bad="$TMPROOT/c07-list.txt"
  populate_required_root "$root"
  { cat "$REQUIRED_LIST"; printf 'outcome.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'duplicates required entry' || return 1
  { cat "$REQUIRED_LIST"; printf '/etc/passwd\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf '../escape.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf '.\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf 'e2e/*.log\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf './outcome.txt\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'canonical explicit relative path' || return 1
  { cat "$REQUIRED_LIST"; printf 'artifact-manifest.sha256\n'; } >"$bad"
  assert_required_list_reject "$root" "$bad" 'reserved seal-phase manifest' || return 1
  # Comments and blank lines remain deterministic and are ignored.
  { printf '# trailing comment\n\n   \n'; cat "$REQUIRED_LIST"; } >"$bad"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$bad" >/dev/null || return 1
}

# C08 — manifest exact-set and hash validation.
c08() {
  local root="$TMPROOT/c08-root" manifest="$TMPROOT/c08-manifest.sha256"
  local first='' digest=''
  populate_required_root "$root"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
  ) || return 1
  cp -f "$root/artifact-manifest.sha256" "$manifest"
  first="$(head -n1 "$manifest")"
  digest="$(printf 'manifest-probe' | sha256sum | cut -d' ' -f1)"
  # The generated manifest is exact-set clean and never hashes itself.
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" --manifest "$manifest" >/dev/null || return 1
  assert_no_contains "$manifest" 'artifact-manifest.sha256'
  assert_eq "$(grep -c '  \./' "$manifest")" \
    "$(grep -Ev '^[[:space:]]*(#|$)' "$REQUIRED_LIST" | wc -l)" 'manifest entry count'

  { cat "$manifest"; printf '%s\n' "$first"; } >"$TMPROOT/c08-dup"
  assert_manifest_reject "$root" "$TMPROOT/c08-dup" 'duplicates manifest entry' || return 1
  { cat "$manifest"; printf '%s  ./unexpected.txt\n' "$digest"; } >"$TMPROOT/c08-extra"
  assert_manifest_reject "$root" "$TMPROOT/c08-extra" 'outside the required set' || return 1
  tail -n +2 "$manifest" >"$TMPROOT/c08-missing"
  assert_manifest_reject "$root" "$TMPROOT/c08-missing" 'missing required entry' || return 1
  sed '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "$manifest" >"$TMPROOT/c08-hash"
  assert_manifest_reject "$root" "$TMPROOT/c08-hash" 'manifest digest mismatch' || return 1
  { cat "$manifest"; printf '%s  ./artifact-manifest.sha256\n' "$digest"; } >"$TMPROOT/c08-self"
  assert_manifest_reject "$root" "$TMPROOT/c08-self" 'must not hash itself' || return 1
  { cat "$manifest"; printf '%s  ../escape.txt\n' "$digest"; } >"$TMPROOT/c08-traverse"
  assert_manifest_reject "$root" "$TMPROOT/c08-traverse" 'normalized relative path' || return 1
  { cat "$manifest"; printf '%s  /etc/passwd\n' "$digest"; } >"$TMPROOT/c08-absolute"
  assert_manifest_reject "$root" "$TMPROOT/c08-absolute" 'normalized relative path' || return 1
}

# C09 — reserved formal manifest is EXACTLY ONE root-relative path.
#
# Load-bearing and behavioral: it drives the real pre-seal checker, the real
# production manifest generator and the real sealed verifier over a tree that
# contains a nested same-basename artifact, plus the real archive helpers. It is
# deliberately not satisfied by source grep.
#
# R2E-B01 defect: exclusion keyed on the BASENAME let
# `rogue/artifact-manifest.sha256` exist in the evidence tree, vanish from
# actual-set accounting, vanish from the generated manifest, enter the archive,
# and still let completeness and manifest verification report PASS.

# C09-A — pre-seal: a nested same-basename artifact is an unexpected artifact.
c09_a() {
  local root="$TMPROOT/c09a-root" out='' rc=0
  populate_required_root "$root"
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" >/dev/null || return 1
  mkdir -p "$root/rogue"
  printf 'nested reserved-basename artifact\n' >"$root/rogue/artifact-manifest.sha256"
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" 2>&1)" || rc=$?
  (( rc != 0 )) ||
    { printf 'C09-A: pre-seal completeness accepted a nested reserved-basename artifact\n'; return 1; }
  grep -Fq 'unexpected unclassified artifact in the evidence root: rogue/artifact-manifest.sha256' \
    <<<"$out" ||
    { printf 'C09-A: wrong or missing diagnostic:\n%s\n' "$out"; return 1; }
  # The checker is read-only: it must not have removed the offending artifact.
  assert_file "$root/rogue/artifact-manifest.sha256"
  printf 'C09_A_PRESEAL=PASS\n'
}

# C09-B — post-seal: production manifest generation must not suppress it.
c09_b() {
  local root="$TMPROOT/c09b-root" out='' rc=0
  populate_required_root "$root"
  mkdir -p "$root/rogue"
  printf 'nested reserved-basename artifact\n' >"$root/rogue/artifact-manifest.sha256"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
  ) || return 1
  # Production manifest code must have classified the nested object.
  grep -Fq '  ./rogue/artifact-manifest.sha256' "$root/artifact-manifest.sha256" ||
    { printf 'C09-B: production manifest suppressed rogue/artifact-manifest.sha256\n'; return 1; }
  # ...while still never hashing the reserved root manifest itself.
  if grep -Fq '  ./artifact-manifest.sha256' "$root/artifact-manifest.sha256"; then
    printf 'C09-B: root manifest hashed itself\n'
    return 1
  fi
  assert_eq "$(grep -c '  \./' "$root/artifact-manifest.sha256")" '88' 'nested manifest entry count'
  # Sealed verification must FAIL: the nested object cannot be unclassified.
  out="$("$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" \
    --manifest "$root/artifact-manifest.sha256" 2>&1)" || rc=$?
  (( rc != 0 )) ||
    { printf 'C09-B: sealed verification accepted a nested reserved-basename artifact\n'; return 1; }
  grep -Fq 'rogue/artifact-manifest.sha256' <<<"$out" ||
    { printf 'C09-B: sealed diagnostic does not name the nested artifact:\n%s\n' "$out"; return 1; }
  printf 'C09_B_POSTSEAL=PASS\n'
}

# C09-C — the legitimate root manifest stays the one reserved path.
c09_c() {
  local root="$TMPROOT/c09c-root" required_count
  populate_required_root "$root"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$root" || return 1
    m8_manifest_verify "$root" || return 1
  ) || return 1
  required_count="$(grep -Ev '^[[:space:]]*(#|$)' "$REQUIRED_LIST" | wc -l)"
  assert_eq "$required_count" '87' 'canonical required count'
  assert_eq "$(grep -c '  \./' "$root/artifact-manifest.sha256")" "$required_count" \
    'root manifest entry count'
  if grep -Fq '  ./artifact-manifest.sha256' "$root/artifact-manifest.sha256"; then
    printf 'C09-C: root manifest hashed itself\n'
    return 1
  fi
  "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$root" --required "$REQUIRED_LIST" \
    --manifest "$root/artifact-manifest.sha256" >/dev/null || return 1
  # The reserved name is constrained to a plain basename, so neither a path nor a
  # glob can re-widen the exclusion back to basename-wide (or match-all) form.
  local bad_name
  for bad_name in 'rogue/artifact-manifest.sha256' '*' './artifact-manifest.sha256'; do
    if (
      # shellcheck source=/dev/null
      source "$MANIFEST_LIB"
      m8_manifest_generate "$root" "$bad_name"
    ) >/dev/null 2>&1; then
      printf 'C09-C: production manifest accepted a non-plain reserved name: %s\n' "$bad_name"
      return 1
    fi
  done
  printf 'C09_C_ROOT_MANIFEST=PASS\n'
}

# C09-D — classification invariant: a nested same-basename object can never be
# present in the archive candidate tree while absent from manifest accounting
# and accepted by completeness validation.
c09_d() {
  local work="$TMPROOT/c09d-root" evidence="$TMPROOT/c09d-root/proof-artifacts"
  local archive="$TMPROOT/c09d-archive.tar.gz" embedded="$TMPROOT/c09d-embedded"
  mkdir -p "$work"
  populate_required_root "$evidence"
  mkdir -p "$evidence/rogue"
  printf 'nested reserved-basename artifact\n' >"$evidence/rogue/artifact-manifest.sha256"
  (
    # shellcheck source=/dev/null
    source "$MANIFEST_LIB"
    m8_manifest_generate "$evidence" || return 1
    m8_archive_build "$work" 'proof-artifacts' "$archive" || return 1
    m8_archive_embedded_manifest "$archive" 'proof-artifacts' >"$embedded" || return 1
  ) || return 1
  # 1. physically present in the archive candidate tree
  tar -tzf "$archive" | grep -Fq 'proof-artifacts/rogue/artifact-manifest.sha256' ||
    { printf 'C09-D: nested object is absent from the archive\n'; return 1; }
  # 2. present in manifest classification (not suppressed)
  grep -Fq '  ./rogue/artifact-manifest.sha256' "$embedded" ||
    { printf 'C09-D: nested object was suppressed from the embedded manifest classification\n'; return 1; }
  # 3. production completeness verification refuses the tree
  if "$PYTHON" "$REPO_ROOT/scripts/verify-m8-artifact-completeness.py" \
    --root "$evidence" --required "$REQUIRED_LIST" \
    --manifest "$evidence/artifact-manifest.sha256" >/dev/null 2>&1; then
    printf 'C09-D: a rogue nested reserved-basename artifact was accepted\n'
    return 1
  fi
  printf 'C09_D_CLASSIFICATION=PASS\n'
}

# C09 — aggregate: all four sub-phases must hold.
c09() {
  c09_a || return 1
  c09_b || return 1
  c09_c || return 1
  c09_d || return 1
}

# ===========================================================================
# R2I-C1 regressions (I01..I02) — production executable-override rejection.
#
# These are independent of the historical V01-V40 / C01-C09 sets and own their
# own counters. They invoke the two REAL production entrypoints in an isolated
# offline environment (all other production seams unset) and rely on the
# documented first-action seam guard, which guarantees no external I/O,
# authorization consumption or host-state mutation can occur.
# ===========================================================================

# The actual seam names exposed at runtime by the shared production authority,
# read in a fresh shell so no test-process state can influence the result.
production_seam_names() {
  bash -c 'source "$1"; printf "%s\n" "${M8_SYNTHETIC_SEAM_VARS[@]}"' _ "$SEAMS_LIB" | sort
}

# Independent expected set, hard-coded on purpose. This is an oracle, not a
# restatement of the implementation array: production source = implementation,
# this list = independent expectation.
expected_seam_names() {
  printf '%s\n' \
    M8_SYNTHETIC_TEST_MODE \
    M8_IMDS_BASE_URL \
    M8_IMDS_CURL_BIN \
    M8_OSSUTIL_BIN \
    M8_OSSUTIL_GET_OUTPUT_FLAG \
    M8_ADAPTER_SCRIPT_OVERRIDE \
    M8_PYTHON_BIN | sort
}

# Shared shape for I01/I02: with exactly one seam set (and every other production
# seam explicitly unset) both production entrypoints must fail closed through the
# shared seam guard, before authorization/context processing, and must emit no
# formal success marker.
assert_seam_rejected_by_both_entrypoints() {
  local name=$1 value=$2
  local -a unset_args=()
  local n out rc=0
  for n in "${SYNTHETIC_SEAM_VARS[@]}" "${OSS_TRUST_ENV_VARS[@]}"; do unset_args+=(-u "$n"); done

  # --- formal wrapper ---
  rc=0
  out="$(env "${unset_args[@]}" "$name=$value" bash "$WRAPPER" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf '%s: the formal wrapper accepted the override\n' "$name"; return 1; }
  grep -Fq "$name is set" <<<"$out" ||
    { printf '%s: wrapper diagnostic does not name the variable\n%s\n' "$name" "$out"; return 1; }
  grep -Fq 'refuses offline synthetic overrides' <<<"$out" ||
    { printf '%s: wrapper did not use the shared seam-refusal path\n%s\n' "$name" "$out"; return 1; }
  ! grep -Fq 'missing single-use authorization' <<<"$out" ||
    { printf '%s: wrapper reached the authorization guard before the seam guard\n' "$name"; return 1; }
  ! grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC' <<<"$out" ||
    { printf '%s: a formal RC marker was emitted\n' "$name"; return 1; }

  # --- formal adapter, executed directly ---
  rc=0
  out="$(env "${unset_args[@]}" "$name=$value" bash "$ADAPTER" 2>&1)" || rc=$?
  (( rc != 0 )) || { printf '%s: the formal adapter accepted the override\n' "$name"; return 1; }
  grep -Fq "$name is set" <<<"$out" ||
    { printf '%s: adapter diagnostic does not name the variable\n%s\n' "$name" "$out"; return 1; }
  grep -Fq 'refuses offline synthetic overrides' <<<"$out" ||
    { printf '%s: adapter did not use the shared seam-refusal path\n%s\n' "$name" "$out"; return 1; }
  ! grep -Fq 'M8_ADAPTER_MODE=' <<<"$out" ||
    { printf '%s: the adapter reached its ordinary NONFORMAL/context refusal first\n' "$name"; return 1; }
  return 0
}

# Capture pre-existing runtime paths so the negative tests only assert that the
# rejected invocations CREATED nothing (they run against the real repo root).
r2i_capture_pre_state() {
  R2I_PRE_ARTIFACTS=0
  R2I_PRE_CANDIDATE=0
  R2I_PRE_HOSTSTATE=0
  if [[ -e "$REPO_ROOT/proof-artifacts" ]]; then R2I_PRE_ARTIFACTS=1; fi
  if [[ -e "$REPO_ROOT/candidate" ]]; then R2I_PRE_CANDIDATE=1; fi
  if [[ -e "$HOME/.local/state/linguagraph-m8-proof" ]]; then R2I_PRE_HOSTSTATE=1; fi
}

r2i_assert_no_new_runtime_state() {
  if (( R2I_PRE_ARTIFACTS == 0 )); then assert_no_file "$REPO_ROOT/proof-artifacts"; fi
  if (( R2I_PRE_CANDIDATE == 0 )); then assert_no_file "$REPO_ROOT/candidate"; fi
  if (( R2I_PRE_HOSTSTATE == 0 )); then assert_no_file "$HOME/.local/state/linguagraph-m8-proof"; fi
  return 0
}

# I01 — M8_ADAPTER_SCRIPT_OVERRIDE must be rejected fail-closed in production.
i01() {
  # Named oracle, written out literally so it is never derived from the array.
  local oracle_name='M8_ADAPTER_SCRIPT_OVERRIDE'
  local probe="$TMPROOT/i01-adapter-probe.sh"
  local sentinel="$TMPROOT/i01-adapter-sentinel"

  assert_eq "$(production_seam_names)" "$(expected_seam_names)" \
    'production seam authority exposes exactly the seven expected names'
  grep -Fxq "$oracle_name" <(expected_seam_names) ||
    { printf 'I01 oracle does not name %s\n' "$oracle_name"; return 1; }

  # A harmless substituted adapter that would leave a sentinel if executed.
  cat >"$probe" <<EOF
#!/usr/bin/env bash
: >"$sentinel"
exit 0
EOF
  chmod +x "$probe"

  r2i_capture_pre_state
  assert_seam_rejected_by_both_entrypoints "$oracle_name" "$probe" || return 1

  # The substituted adapter must never have been executed, and the rejected
  # invocations must not have created the filesystem paths a real run creates.
  assert_no_file "$sentinel"
  r2i_assert_no_new_runtime_state
  printf 'I01_ADAPTER_OVERRIDE_REJECTED=PASS\n'
  return 0
}

# I02 — M8_PYTHON_BIN must be rejected fail-closed in production.
i02() {
  # Named oracle, written out literally so it is never derived from the array.
  local oracle_name='M8_PYTHON_BIN'
  local probe="$TMPROOT/i02-python-probe"
  local sentinel="$TMPROOT/i02-python-sentinel"

  grep -Fxq "$oracle_name" <(expected_seam_names) ||
    { printf 'I02 oracle does not name %s\n' "$oracle_name"; return 1; }
  grep -Fxq "$oracle_name" <(production_seam_names) ||
    { printf 'I02: %s is absent from the shared production seam authority\n' "$oracle_name"; return 1; }

  # A harmless substituted interpreter that would leave a sentinel if executed.
  cat >"$probe" <<EOF
#!/usr/bin/env bash
: >"$sentinel"
exit 0
EOF
  chmod +x "$probe"

  r2i_capture_pre_state
  assert_seam_rejected_by_both_entrypoints "$oracle_name" "$probe" || return 1

  # The substituted interpreter must never have been executed, and the rejected
  # invocations must not have created evidence/claim/candidate/host-state paths.
  assert_no_file "$sentinel"
  r2i_assert_no_new_runtime_state
  printf 'I02_PYTHON_BIN_REJECTED=PASS\n'
  return 0
}

# ===========================================================================
# R2I-C4/B03 — closed OSS trust-target regressions (T01..T12).
#
# These are deliberately separate from V01..V40, C01..C09 and I01..I02: a green
# legacy baseline is not evidence that the B03 trust-target boundary holds.
# ===========================================================================

# Read the live 19-name closed environment authority out of the shared seam
# library in a fresh shell, so a test can never inherit a mutated in-process copy.
b03_trust_env_names() {
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${M8_OSS_TRUST_ENV_REJECT_VARS[@]}"' _ "$SEAMS_LIB"
}

b03_seam_names() {
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${M8_SYNTHETIC_SEAM_VARS[@]}"' _ "$SEAMS_LIB"
}

# Write a synthetic ossutil that reports exactly one version string.
b03_version_stub() {
  local version=$1 path=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'ossutil version ${version}\\n'
EOF
  chmod +x "$path"
}

t01() {
  # Independent oracle for the closed trust-environment set. The production list
  # is never used to validate itself.
  local -a oracle=(
    M8_OSSUTIL_CONFIG_FILE OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_SESSION_TOKEN
    OSS_ROLE_ARN OSS_ROLE_SESSION_NAME OSS_REGION OSS_ENDPOINT OSSUTIL_CONFIG_FILE
    OSSUTIL_PROFILE ALIBABA_CLOUD_ECS_METADATA HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
    http_proxy https_proxy all_proxy no_proxy
  )
  assert_eq "${#oracle[@]}" '19' 'independent oracle cardinality'
  assert_eq "$(b03_trust_env_names | sort | tr '\n' ' ')" \
    "$(printf '%s\n' "${oracle[@]}" | sort | tr '\n' ' ')" 'closed trust-environment name set'
  assert_eq "$(b03_trust_env_names | wc -l | tr -d ' ')" '19' 'closed set cardinality'

  # The C1 seven-seam authority and the B03 nineteen-name authority are two
  # distinct arrays in one shared file and must never be merged or duplicated.
  assert_eq "$(b03_seam_names | wc -l | tr -d ' ')" '7' 'C1 seam cardinality'
  assert_eq "$(grep -c '^readonly -a M8_SYNTHETIC_SEAM_VARS=(' "$SEAMS_LIB")" '1' 'single seam declaration'
  assert_eq "$(grep -c '^readonly -a M8_OSS_TRUST_ENV_REJECT_VARS=(' "$SEAMS_LIB")" '1' 'single trust-env declaration'
  local name
  while IFS= read -r name; do
    grep -qxF "  $name" <(sed -n '/M8_OSS_TRUST_ENV_REJECT_VARS=(/,/^)/p' "$SEAMS_LIB") &&
      assert_fail "B03 list must not be merged into the C1 seam array: $name"
  done < <(b03_seam_names)

  # Every one of the nineteen names is rejected fail-closed by the real wrapper
  # entrypoint, before authorization processing, with the value never echoed and
  # with no formal/synthetic success marker.
  local -a unsets=()
  while IFS= read -r name; do unsets+=(-u "$name"); done < <(b03_trust_env_names)
  while IFS= read -r name; do unsets+=(-u "$name"); done < <(b03_seam_names)

  local out rc
  for name in "${oracle[@]}"; do
    rc=0
    out="$(env "${unsets[@]}" "$name=M8C4PROBEVALUE" bash "$WRAPPER" 2>&1)" || rc=$?
    (( rc != 0 )) || { printf 'T01: %s was accepted by the wrapper\n' "$name"; return 1; }
    grep -Fq "$name is set" <<<"$out" ||
      { printf 'T01: %s is not named in the rejection diagnostic:\n%s\n' "$name" "$out"; return 1; }
    grep -Fq 'M8C4PROBEVALUE' <<<"$out" &&
      { printf 'T01: %s value was echoed into the diagnostic\n' "$name"; return 1; }
    grep -Fq 'missing single-use authorization' <<<"$out" &&
      { printf 'T01: authorization was processed before the environment guard for %s\n' "$name"; return 1; }
    grep -Fq 'HSDR_F02_FORMAL_RUN_COMMAND_RC' <<<"$out" &&
      { printf 'T01: a formal RC marker was emitted for %s\n' "$name"; return 1; }
    grep -Fq 'M8_SYNTHETIC_OUTCOME=OK' <<<"$out" &&
      { printf 'T01: a synthetic success marker was emitted for %s\n' "$name"; return 1; }
  done
  return 0
}

t02() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_PROOF_ROOT="$REPO_ROOT" M8_OSS_BUCKET='test-bucket'
    export M8_OSSUTIL_BIN="$FAKE_OSSUTIL" M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/t02-oss" M8_FAKE_OSS_LOCATION='cn-hongkong'
    export M8_FAKE_OSS_VERSIONING='unversioned'
    export M8_FAKE_OSS_ARG_LOG="$TMPROOT/t02-args.log"
    mkdir -p "$M8_FAKE_OSS_ROOT/objects"
    : >"$M8_FAKE_OSS_ARG_LOG"

    local body="$TMPROOT/t02-body.txt" config
    config="$REPO_ROOT/scripts/config/m8-ossutil-formal.ini"
    printf 'T02 payload\n' >"$body"

    m8_oss_api put-object --bucket test-bucket --key runs/t02/a.txt --body "file://$body" --forbid-overwrite true >/dev/null
    m8_oss_api head-object --bucket test-bucket --key runs/t02/a.txt >/dev/null
    m8_oss_api get-object --bucket test-bucket --key runs/t02/a.txt >/dev/null
    m8_oss_api get-bucket-versioning --bucket test-bucket >/dev/null
    m8_oss_api get-bucket-location --bucket test-bucket >/dev/null

    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d ' ')" '5' 'pinned invocation count'
    local operation
    for operation in put-object head-object get-object get-bucket-versioning get-bucket-location; do
      assert_eq "$(grep -c "operation=$operation " "$M8_FAKE_OSS_ARG_LOG")" '1' "$operation issued through the pinned CLI"
    done
    # R2I-C11: every call carries exactly the FIVE CLI-pinned global flags, and
    # the auth binding comes from the canonical config file -- never from a CLI
    # --mode or --ecs-role-name (ossutil 2.4.0 supports neither).
    assert_eq "$(grep -c "config_file=$config region=cn-hongkong endpoint=https://oss-cn-hongkong-internal.aliyuncs.com config_mode=Ali-EcsRamRole config_role=LinguaGraphM8ProofExecutor cli_mode=none cli_role=none addressing_style=virtual ignore_env_var=yes forbidden=none" "$M8_FAKE_OSS_ARG_LOG")" \
      '5' 'every call carries the five frozen CLI pins and the config role binding'
    assert_no_grep 'cli_mode=Ali-EcsRamRole|cli_mode=EcsRamRole|cli_role=LinguaGraphM8ProofExecutor' "$M8_FAKE_OSS_ARG_LOG"
    assert_no_grep 'skip-verify-cert|access-key-id|access-key-secret|sts-token|ram-role-arn|role-session-name' "$M8_FAKE_OSS_ARG_LOG"

    # The frozen argument vector is five flags = nine argv tokens, with no role
    # flag of any kind.
    m8_oss_global_args >/dev/null || { printf 'T02: global args failed\n'; return 1; }
    assert_eq "${#M8_OSS_GLOBAL_ARGS[@]}" '9' 'five pinned flags expand to nine argv tokens'
    local joined=" ${M8_OSS_GLOBAL_ARGS[*]} "
    assert_eq "$([[ "$joined" == *' --mode '* ]] && echo present || echo absent)" 'absent' 'no CLI --mode'
    assert_eq "$([[ "$joined" == *' --ecs-role-name '* ]] && echo present || echo absent)" 'absent' 'no CLI --ecs-role-name'

    # The live cross-binding fails closed before any CLI vector is produced.
    local role_rc=0
    ( M8_OSS_ECS_ROLE_NAME='' m8_oss_global_args ) >/dev/null 2>&1 || role_rc=$?
    assert_eq "$role_rc" '1' 'global args refuse an unobserved role'
    role_rc=0
    ( M8_OSS_ECS_ROLE_NAME='M8OtherObservedRole' m8_oss_global_args ) >/dev/null 2>&1 || role_rc=$?
    assert_eq "$role_rc" '1' 'global args refuse a stored role that disagrees with the config'
    role_rc=0
    ( M8_FAKE_IMDS_ROLE_MODE='zero' m8_oss_global_args ) >/dev/null 2>&1 || role_rc=$?
    assert_eq "$role_rc" '1' 'global args fail closed when the live role observation yields no role'
    assert_no_grep 'LinguaGraphM8ProofExecutor' "$OSS_LIB"

    assert_eq "$M8_OSS_REGION" 'cn-hongkong' 'frozen region'
    assert_eq "$M8_OSS_ENDPOINT" 'https://oss-cn-hongkong-internal.aliyuncs.com' 'frozen HTTPS internal endpoint'
    assert_eq "$M8_OSS_ENDPOINT_CLASS" 'INTERNAL' 'frozen endpoint class'
    assert_eq "$M8_OSS_NETWORK_POLICY" 'SAME_REGION_INTERNAL_ONLY' 'frozen network policy'
    assert_eq "$M8_OSS_AUTH_MODE" 'Ali-EcsRamRole' 'frozen auth mode'
    assert_eq "$M8_OSS_ADDRESSING_STYLE" 'virtual' 'frozen addressing style'
    assert_eq "$M8_OSS_TLS_VERIFICATION" 'required' 'frozen TLS verification policy'
    assert_eq "$M8_OSS_IGNORE_ENV_VARS" 'true' 'ambient OSS_ env vars are ignored'
  )
}

t03() {
  local config="$REPO_ROOT/scripts/config/m8-ossutil-formal.ini"
  assert_file "$config"
  assert_eq "$(wc -c <"$config" | tr -d '[:space:]')" '81' 'canonical config byte count'
  assert_eq "$(sha256sum "$config" | cut -d' ' -f1)" \
    '43b384710e4d0944fa3fea3f4daf4dcaba280739cc40d9c31bdbd6c54772c47a' 'canonical config digest'
  assert_eq "$(printf '[default]\nlanguage=EN\nmode=Ali-EcsRamRole\necsRoleName=LinguaGraphM8ProofExecutor\n' | sha256sum | cut -d' ' -f1)" \
    "$(sha256sum "$config" | cut -d' ' -f1)" 'canonical config exact bytes'
  assert_eq "$(tr -cd '\r' <"$config" | wc -c | tr -d '[:space:]')" '0' 'canonical config has no CR'
  assert_eq "$(head -c 3 "$config")" '[de' 'canonical config has no BOM'

  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_OSS_BUCKET='test-bucket' M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
    local scratch="$TMPROOT/t03-tree"
    mkdir -p "$scratch"
    cp -a "$REPO_ROOT/scripts" "$scratch/"
    export M8_PROOF_ROOT="$scratch"

    m8_oss_canonical_config_guard - || { printf 'T03: the pristine canonical config was rejected\n'; return 1; }
    assert_eq "$(m8_oss_canonical_config_path)" "$scratch/scripts/config/m8-ossutil-formal.ini" 'canonical path resolution'

    local target="$scratch/scripts/config/m8-ossutil-formal.ini"
    printf 'x' >>"$target"
    if m8_oss_canonical_config_guard - 2>/dev/null; then
      printf 'T03: a one-byte config mutation was accepted\n'; return 1
    fi

    rm -f "$target"
    if m8_oss_canonical_config_guard - 2>/dev/null; then
      printf 'T03: an absent canonical config was accepted\n'; return 1
    fi

    printf '[default]\nlanguage=EN\nmode=Ali-EcsRamRole\necsRoleName=LinguaGraphM8ProofExecutor\nendpoint=evil.example\n' >"$target"
    if m8_oss_canonical_config_guard - 2>/dev/null; then
      printf 'T03: a config carrying a forbidden endpoint key was accepted\n'; return 1
    fi
    printf '[default]\nlanguage=EN\nmode=Ali-EcsRamRole\necsRoleName=WrongRole\n' >"$target"
    if m8_oss_canonical_config_guard - 2>/dev/null; then
      printf 'T03: a config naming a different role was accepted\n'; return 1
    fi

    rm -f "$target"
    ln -s "$config" "$target"
    if m8_oss_canonical_config_guard - 2>/dev/null; then
      printf 'T03: a symlinked canonical config was accepted\n'; return 1
    fi
    rm -f "$target"

    # An out-of-worktree config path can never be selected.
    export M8_PROOF_ROOT="$REPO_ROOT"
    assert_eq "$(m8_oss_canonical_config_path)" \
      "$REPO_ROOT/scripts/config/m8-ossutil-formal.ini" 'canonical config path is proof-tree relative'
  ) || return 1

  # The library/wrapper never consume an ambient config or profile selector; the
  # names appear only in comments, where they document the closure.
  local library_code wrapper_code
  library_code="$(grep -vE '^[[:space:]]*#' "$OSS_LIB" | grep -c 'M8_OSSUTIL_CONFIG_FILE\|OSSUTIL_PROFILE\|\.ossutilconfig' || true)"
  assert_eq "$library_code" '0' 'no ambient config/profile selection in executable library code'
  wrapper_code="$(grep -vE '^[[:space:]]*#' "$WRAPPER" | grep -c 'M8_OSSUTIL_CONFIG_FILE\|OSSUTIL_PROFILE\|OSSUTIL_CONFIG_FILE' || true)"
  assert_eq "$wrapper_code" '0' 'no ambient config/profile selection in executable wrapper code'
  # ...and the closed environment guard rejects them instead.
  grep -qxF '  M8_OSSUTIL_CONFIG_FILE' <(sed -n '/M8_OSS_TRUST_ENV_REJECT_VARS=(/,/^)/p' "$SEAMS_LIB") ||
    assert_fail 'M8_OSSUTIL_CONFIG_FILE is absent from the closed trust-environment set'
  grep -qxF '  OSSUTIL_PROFILE' <(sed -n '/M8_OSS_TRUST_ENV_REJECT_VARS=(/,/^)/p' "$SEAMS_LIB") ||
    assert_fail 'OSSUTIL_PROFILE is absent from the closed trust-environment set'
  return 0
}

t04() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_PROOF_ROOT="$REPO_ROOT" M8_OSS_BUCKET='test-bucket'
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    local dir="$TMPROOT/t04" stub
    mkdir -p "$dir"

    # A supported release is accepted and its live identity is recorded.
    stub="$dir/ossutil-220"
    b03_version_stub '2.2.0' "$stub"
    M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - || { printf 'T04: ossutil 2.2.0 was rejected\n'; return 1; }
    assert_eq "$M8_OSSUTIL_VERSION" '2.2.0' 'parsed version'
    assert_eq "$M8_OSSUTIL_ABSOLUTE_PATH" "$stub" 'resolved absolute path'
    assert_eq "$M8_OSSUTIL_BINARY_SHA256" "$(sha256sum "$stub" | cut -d' ' -f1)" 'recorded binary digest'

    stub="$dir/ossutil-231"
    b03_version_stub '2.3.1' "$stub"
    M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - || { printf 'T04: ossutil 2.3.1 was rejected\n'; return 1; }
    assert_eq "$M8_OSSUTIL_VERSION" '2.3.1' 'later supported version parsed'

    # Below the minimum is refused: --ignore-env-var requires 2.2.0.
    stub="$dir/ossutil-210"
    b03_version_stub '2.1.0' "$stub"
    if M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - 2>/dev/null; then
      printf 'T04: ossutil 2.1.0 was accepted below the 2.2.0 minimum\n'; return 1
    fi

    # Unparseable version output is refused.
    stub="$dir/ossutil-garbage"
    printf '#!/usr/bin/env bash\nprintf "this is not a version\\n"\n' >"$stub"
    chmod +x "$stub"
    if M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - 2>/dev/null; then
      printf 'T04: unparseable version output was accepted\n'; return 1
    fi

    # A non-executable or absent binary is refused.
    stub="$dir/ossutil-noexec"
    b03_version_stub '2.2.0' "$stub"
    chmod -x "$stub"
    if M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - 2>/dev/null; then
      printf 'T04: a non-executable ossutil was accepted\n'; return 1
    fi
    if M8_OSSUTIL_BIN="$dir/absent-ossutil" m8_ossutil_identity_guard - 2>/dev/null; then
      printf 'T04: an absent ossutil was accepted\n'; return 1
    fi

    # The recorded digest is over the resolved bytes, so a mutation changes the
    # trust-profile digest and invalidates any prior binding.
    stub="$dir/ossutil-mutable"
    b03_version_stub '2.2.0' "$stub"
    M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - || return 1
    local before after
    before="$(m8_oss_trust_profile_sha256)"
    printf '# mutated after identity capture\n' >>"$stub"
    M8_OSSUTIL_BIN="$stub" m8_ossutil_identity_guard - || return 1
    after="$(m8_oss_trust_profile_sha256)"
    [[ "$before" != "$after" ]] ||
      { printf 'T04: an ossutil binary mutation did not change the trust profile\n'; return 1; }

    assert_eq "$M8_OSS_MIN_VERSION" '2.2.0' 'frozen minimum ossutil version'
  )
}

t05() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_PROOF_ROOT="$REPO_ROOT" M8_OSS_BUCKET='test-bucket'
    export M8_OSSUTIL_BIN="$FAKE_OSSUTIL" M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_FAKE_OSS_ROOT="$TMPROOT/t05-oss" M8_FAKE_OSS_VERSIONING='unversioned'
    export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/t05-mut.log"
    export M8_FAKE_OSS_ARG_LOG="$TMPROOT/t05-args.log"
    mkdir -p "$M8_FAKE_OSS_ROOT/objects"
    : >"$M8_FAKE_OSS_MUTATION_LOG"
    : >"$M8_FAKE_OSS_ARG_LOG"

    M8_FAKE_OSS_LOCATION='cn-hongkong' m8_oss_bucket_location_guard - ||
      { printf 'T05: the correct in-region bucket location was rejected\n'; return 1; }
    assert_eq "$M8_OSS_BUCKET_LOCATION_OBSERVED" 'oss-cn-hongkong' 'observed bucket location recorded'
    assert_eq "$(grep -c '^READ get-bucket-location test-bucket' "$M8_FAKE_OSS_MUTATION_LOG")" '1' 'location read issued'
    assert_no_grep '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG"

    local state
    for state in wrong-region empty garbage denied; do
      : >"$M8_FAKE_OSS_MUTATION_LOG"
      if M8_FAKE_OSS_LOCATION="$state" m8_oss_bucket_location_guard - 2>/dev/null; then
        printf 'T05: bucket location state %s was accepted\n' "$state"; return 1
      fi
      assert_eq "$(grep -c '^READ get-bucket-location' "$M8_FAKE_OSS_MUTATION_LOG")" '1' "$state performed exactly one read"
      assert_no_grep '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG"
    done

    # A rejected location is recorded in the existing pre-claim evidence file, so
    # B03 rides in PHASE-A artifacts that already exist.
    local evidence="$TMPROOT/t05-preclaim"
    mkdir -p "$evidence"
    M8_FAKE_OSS_LOCATION='wrong-region' m8_oss_bucket_location_guard "$evidence" 2>/dev/null || true
    assert_contains "$evidence/oss-versioning-guard.txt" 'bucket_location=REJECTED:oss-cn-hangzhou'
    assert_eq "$(grep -c 'get_bucket_location_rc=' "$evidence/oss-versioning-guard.txt")" '1' 'location rc recorded once'
    assert_eq "$M8_OSS_BUCKET_LOCATION" 'oss-cn-hongkong' 'required canonical bucket location'
  )
}

t06() {
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    export M8_IMDS_CURL_BIN="$(write_fake_imds_client)"
    export M8_IMDS_BASE_URL='http://imds.invalid/latest'
    export M8_FAKE_IMDS_LOG="$TMPROOT/t06-imds.log"
    : >"$M8_FAKE_IMDS_LOG"

    # PASS: exactly one valid role.
    local name
    name="$(M8_FAKE_IMDS_ROLE_MODE='one' M8_FAKE_IMDS_ROLE_NAME='LinguaGraphM8ProofExecutor' \
      m8_provider_identity_observe_ecs_role_name)" ||
      { printf 'T06: a single-role observation failed\n'; return 1; }
    assert_eq "$name" 'LinguaGraphM8ProofExecutor' 'observed role name'

    # FAIL: zero, multiple, CR/control ambiguity.
    local mode
    for mode in zero multiple control; do
      if M8_FAKE_IMDS_ROLE_MODE="$mode" m8_provider_identity_observe_ecs_role_name >/dev/null 2>&1; then
        printf 'T06: IMDS role mode %s was accepted\n' "$mode"; return 1
      fi
    done

    # FAIL: a REAL NUL byte in the LIST response (R2I-C5_B01 / R2I-C6).
    # The real production helper is invoked; this is not a source-text check.
    local nul_out="$TMPROOT/t06-nul.out" nul_err="$TMPROOT/t06-nul.err" nul_rc=0
    : >"$nul_out"
    : >"$nul_err"
    M8_FAKE_IMDS_ROLE_MODE='nul' m8_provider_identity_observe_ecs_role_name \
      >"$nul_out" 2>"$nul_err" || nul_rc=$?
    (( nul_rc != 0 )) ||
      { printf 'T06: a real-NUL role-name response was ACCEPTED (rc=%s)\n' "$nul_rc"; return 1; }
    assert_contains "$nul_err" 'ECS role-name response contains a NUL byte'
    assert_contains "$nul_err" 'NUL'
    assert_eq "$(wc -c <"$nul_out" | tr -d '[:space:]')" '0' 'no validated role emitted for a NUL response'
    assert_no_grep 'LinguaGraphM8ProofExecutor|M8SyntheticNulSuffix' "$nul_out"
    # The corrected data flow never puts the raw NUL body through command
    # substitution, so Bash must not emit its lossy warning on either stream.
    assert_no_grep 'ignored null byte in input' "$nul_err"
    assert_no_grep 'ignored null byte in input' "$nul_out"

    # The `nul` fixture must genuinely carry byte 00: materialize it and inspect
    # the bytes, so a regression to printable backslash-zero is caught too.
    local nul_fixture="$TMPROOT/t06-nul-fixture.bin"
    M8_FAKE_IMDS_LOG='' M8_FAKE_IMDS_ROLE_MODE='nul' \
      "$M8_IMDS_CURL_BIN" "$M8_IMDS_BASE_URL/meta-data/ram/security-credentials/" >"$nul_fixture"
    "$PYTHON" - "$nul_fixture" <<'PY' || return 1
import sys

with open(sys.argv[1], "rb") as handle:
    data = handle.read()
if b"\\0" in data:
    sys.stderr.write("T06: the nul fixture encodes printable backslash-zero: %r\n" % data)
    raise SystemExit(1)
if data.count(b"\x00") != 1:
    sys.stderr.write(
        "T06: expected exactly one real NUL byte, got %d in %r\n" % (data.count(b"\x00"), data)
    )
    raise SystemExit(1)
sys.stdout.write("T06_NUL_FIXTURE_HEX=%s\n" % data.hex())
PY

    # Only the token endpoint and the role-name LIST endpoint are ever requested:
    # one accepted case plus four rejected cases.
    assert_eq "$(grep -c '/api/token$' "$M8_FAKE_IMDS_LOG")" '5' 'token requests'
    assert_eq "$(grep -c 'meta-data/ram/security-credentials/$' "$M8_FAKE_IMDS_LOG")" '5' 'role-name list requests'
    assert_no_grep 'meta-data/ram/security-credentials/.+' "$M8_FAKE_IMDS_LOG"
    assert_no_grep 'AccessKeyId|AccessKeySecret|SecurityToken|CredentialExpiration|TokenExpiration' "$M8_FAKE_IMDS_LOG"

    # Static: the LIST body is streamed to the scratch file and never
    # materialised in a shell variable; the helper creates no host state.
    local helper_file="$TMPROOT/t06-helper-body.txt"
    sed -n '/^m8_provider_identity_observe_ecs_role_name()/,/^}/p' "$IDENTITY_LIB" >"$helper_file"
    assert_contains "$helper_file" '>"$raw_file"'
    assert_no_contains "$helper_file" '$(m8_imds_get'
    assert_no_contains "$helper_file" 'printf'
    assert_no_grep 'mkdir' "$helper_file"

    # Static: the observation helper never interpolates a role name into the
    # credential-payload path, and the credential endpoint is never requested.
    assert_no_grep 'security-credentials/\$' "$IDENTITY_LIB"
    assert_no_grep 'security-credentials/"' "$IDENTITY_LIB"
    assert_contains "$IDENTITY_LIB" "M8_IMDS_ECS_ROLE_LIST_REL='meta-data/ram/security-credentials/'"
  )
}

t07() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    c11_arm_provider_seams
    export M8_PROOF_ROOT="$REPO_ROOT" M8_OSS_BUCKET='test-bucket'
    export M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor'
    export M8_OSSUTIL_VERSION='2.2.0'
    export M8_OSSUTIL_BINARY_SHA256="$(sha256sum "$FAKE_OSSUTIL" | cut -d' ' -f1)"

    # Independent order oracle for the frozen 18-record serialization.
    local -a order=(
      schema oss_bucket oss_region effective_oss_endpoint endpoint_class network_policy
      addressing_style oss_auth_mode ecs_role_name ossutil_version ossutil_binary_sha256
      config_relpath config_sha256 config_profile config_policy_id ignore_oss_env_vars
      env_policy_id tls_verification
    )
    assert_eq "${#order[@]}" '18' 'frozen trust-profile field count'
    assert_eq "$(m8_oss_trust_profile_values | cut -d= -f1 | tr '\n' ' ')" \
      "$(printf '%s ' "${order[@]}")" 'frozen trust-profile field order'
    assert_eq "$(m8_oss_trust_profile_values | grep -c '^[a-z0-9_]*=')" '18' 'record count'
    m8_oss_trust_profile_assert_canonical || { printf 'T07: the canonical profile was rejected\n'; return 1; }

    # Serialization identity: key=value LF records, exactly one trailing LF, one
    # LF per record, and no CR/NUL anywhere.
    assert_eq "$(m8_oss_trust_profile_values | tr -cd '\n' | wc -c | tr -d '[:space:]')" '18' 'one LF per record'
    assert_eq "$(m8_oss_trust_profile_values | tail -c 1 | od -An -tx1 | tr -d ' \n')" '0a' 'exactly one final LF'
    assert_eq "$(m8_oss_trust_profile_values | tr -cd '\r\000' | wc -c | tr -d '[:space:]')" '0' 'no CR or NUL'
    assert_eq "$(m8_oss_trust_profile_values | LC_ALL=C grep -c '^[ -~]*$')" '18' 'records are plain ASCII'

    local digest
    digest="$(m8_oss_trust_profile_sha256)"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { printf 'T07: profile digest is not a SHA-256\n'; return 1; }
    assert_eq "$digest" "$(m8_oss_trust_profile_values | sha256sum | cut -d' ' -f1)" \
      'digest is SHA256 of the exact serialized bytes'
    assert_eq "$digest" "$(m8_oss_trust_profile_values | sha256sum | cut -d' ' -f1)" \
      'digest is stable across invocations'

    # Every live binding must move the digest, and the order must be contractual.
    local zero_sha='0000000000000000000000000000000000000000000000000000000000000000'
    [[ "$(M8_OSS_BUCKET='test-bucket-two' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'T07: a bucket change did not change the profile digest\n'; return 1; }
    [[ "$(M8_OSS_ECS_ROLE_NAME='M8OtherObservedRole' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'T07: a role change did not change the profile digest\n'; return 1; }
    [[ "$(M8_OSSUTIL_VERSION='2.2.1' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'T07: an ossutil version change did not change the profile digest\n'; return 1; }
    [[ "$(M8_OSSUTIL_BINARY_SHA256="$zero_sha" m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'T07: an ossutil binary change did not change the profile digest\n'; return 1; }
    [[ "$(m8_oss_trust_profile_values | tac | sha256sum | cut -d' ' -f1)" != "$digest" ]] ||
      { printf 'T07: a reordered profile hashed identically\n'; return 1; }

    # Missing live values fail closed rather than emitting a partial profile.
    local emitted=0
    if M8_OSS_ECS_ROLE_NAME='' m8_oss_trust_profile_values >/dev/null 2>&1; then emitted=1; fi
    assert_eq "$emitted" '0' 'profile refuses an unestablished role'
    emitted=0
    if M8_OSSUTIL_VERSION='' m8_oss_trust_profile_values >/dev/null 2>&1; then emitted=1; fi
    assert_eq "$emitted" '0' 'profile refuses an unestablished ossutil version'
    emitted=0
    if M8_OSSUTIL_BINARY_SHA256='' m8_oss_trust_profile_values >/dev/null 2>&1; then emitted=1; fi
    assert_eq "$emitted" '0' 'profile refuses an unestablished binary digest'
  )
}

t08() {
  (
    bootstrap_formal_fixture
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1

    export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/t08-mut.log"
    : >"$M8_FAKE_OSS_MUTATION_LOG"

    local profile="$OSS_TRUST_PROFILE_SHA256"
    [[ "$profile" =~ ^[0-9a-f]{64}$ ]] || { printf 'T08: no local trust profile was established\n'; return 1; }

    # The exactly bound authorization is accepted.
    stage_semantic_issued_json "$profile" || return 1
    m8_load_authorization || { printf 'T08: a correctly bound authorization was rejected\n'; return 1; }
    assert_eq "$ISSUED_PROFILE_SHA256" "$profile" 'issued trust-profile binding adopted'
    assert_no_grep '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG"

    # Missing carrier, malformed carrier and a different valid digest all fail
    # closed before any claim (or any other mutating call) is attempted.
    local case_dir="$TMPROOT/t08" stage
    mkdir -p "$case_dir"
    for stage in missing malformed different; do
      : >"$M8_FAKE_OSS_MUTATION_LOG"
      case "$stage" in
        missing)   json_edit "$ISSUED_LOCAL" "$case_dir/$stage.json" drop oss_trust_profile_sha256 ;;
        malformed) json_edit "$ISSUED_LOCAL" "$case_dir/$stage.json" set oss_trust_profile_sha256 'not-a-sha256' ;;
        different) json_edit "$ISSUED_LOCAL" "$case_dir/$stage.json" set oss_trust_profile_sha256 \
                     '1111111111111111111111111111111111111111111111111111111111111111' ;;
      esac
      stage_object "authorizations/$AUTH/issued.json" "$case_dir/$stage.json"
      if m8_load_authorization 2>/dev/null; then
        printf 'T08: a %s trust-profile binding was accepted\n' "$stage"; return 1
      fi
      assert_no_grep '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG"
      assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT"
    done

    # Recovery proves the failures above were caused by the profile binding and
    # not by a consumed single-use lock: the correct document loads again.
    stage_object "authorizations/$AUTH/issued.json" "$ISSUED_LOCAL"
    m8_load_authorization || { printf 'T08: the corrected authorization could not be re-loaded\n'; return 1; }
    assert_eq "$ISSUED_PROFILE_SHA256" "$profile" 'recovered trust-profile binding'
  )
}

t09() {
  run_formal_success || { printf 'T09: the semantic fixture failed\n'; return 1; }

  local profile
  profile="$(m8_json_get "$M8_SEAL_DIR/package-index.json" oss_trust_profile_sha256)"
  [[ "$profile" =~ ^[0-9a-f]{64}$ ]] ||
    { printf 'T09: the local package index carries no trust-profile digest\n'; return 1; }

  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$PACKAGE_INDEX_OBJECT" oss_trust_profile_sha256)" \
    "$profile" 'sealed package-index binding'
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" oss_trust_profile_sha256)" \
    "$profile" 'claim binding'
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT" oss_trust_profile_sha256)" \
    "$profile" 'receipt top-level binding'
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT" cross_binding.oss_trust_profile_sha256)" \
    "$profile" 'receipt cross-binding'

  # The digest is the SHA-256 of the recorded 18-record host-local profile.
  local recorded="$M8_PRECLAIM_DIR/oss-trust-profile.txt"
  assert_file "$recorded"
  assert_eq "$(sha256sum "$recorded" | cut -d' ' -f1)" "$profile" 'recorded profile digest identity'
  assert_eq "$(grep -c '^[a-z0-9_]*=' "$recorded")" '18' 'recorded profile field count'

  # The three writers agree with each other and with the approved proof identity.
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$PACKAGE_INDEX_OBJECT" proof_sha)" \
    "$APPROVED_PROOF_SHA" 'package-index proof identity'
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT" package_index_sha256)" \
    "$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$PACKAGE_INDEX_OBJECT" | cut -d' ' -f1)" \
    'receipt binds the sealed package index'
  assert_eq "$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT" claim_sha256)" \
    "$(sha256sum "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$CLAIM_OBJECT" | cut -d' ' -f1)" \
    'receipt binds the claim'
  return 0
}

t10() {
  run_formal_success || { printf 'T10: the semantic fixture failed\n'; return 1; }

  local receipt="$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  local verifier="$REPO_ROOT/scripts/verify-m8-closure-receipt.py"
  local profile
  profile="$(m8_json_get "$receipt" oss_trust_profile_sha256)"
  [[ "$profile" =~ ^[0-9a-f]{64}$ ]] || { printf 'T10: the receipt carries no trust-profile digest\n'; return 1; }

  "$PYTHON" "$verifier" --receipt "$receipt" --expect-oss-trust-profile-sha256 "$profile" >/dev/null ||
    { printf 'T10: the verifier rejected a correctly bound receipt\n'; return 1; }
  "$PYTHON" "$verifier" --receipt "$receipt" >/dev/null ||
    { printf 'T10: the verifier rejected a self-consistent receipt\n'; return 1; }

  local case_dir="$TMPROOT/t10"
  mkdir -p "$case_dir"
  # Each expected carrier is load-bearing: removing either must fail closed.
  json_edit "$receipt" "$case_dir/no-top.json" drop oss_trust_profile_sha256
  if "$PYTHON" "$verifier" --receipt "$case_dir/no-top.json" >/dev/null 2>&1; then
    printf 'T10: a receipt without the top-level trust-profile binding was accepted\n'; return 1
  fi
  json_edit "$receipt" "$case_dir/no-cross.json" drop cross_binding.oss_trust_profile_sha256
  if "$PYTHON" "$verifier" --receipt "$case_dir/no-cross.json" >/dev/null 2>&1; then
    printf 'T10: a receipt without the trust-profile cross-binding was accepted\n'; return 1
  fi
  json_edit "$receipt" "$case_dir/malformed.json" set oss_trust_profile_sha256 'not-a-sha256'
  if "$PYTHON" "$verifier" --receipt "$case_dir/malformed.json" >/dev/null 2>&1; then
    printf 'T10: a receipt with a malformed trust-profile digest was accepted\n'; return 1
  fi
  json_edit "$receipt" "$case_dir/inconsistent.json" set cross_binding.oss_trust_profile_sha256 \
    '3333333333333333333333333333333333333333333333333333333333333333'
  if "$PYTHON" "$verifier" --receipt "$case_dir/inconsistent.json" >/dev/null 2>&1; then
    printf 'T10: a divergent trust-profile cross-binding was accepted\n'; return 1
  fi
  # A conflicting Human expectation must fail closed.
  if "$PYTHON" "$verifier" --receipt "$receipt" \
      --expect-oss-trust-profile-sha256 '4444444444444444444444444444444444444444444444444444444444444444' >/dev/null 2>&1; then
    printf 'T10: the verifier accepted a conflicting expected trust profile\n'; return 1
  fi

  # The expectation flag is genuinely wired into the verifier, not accepted and
  # ignored.
  assert_contains "$verifier" 'expect_oss_trust_profile_sha256'
  return 0
}

t11() {
  (
    # The pre-existing semantic package index is bound to a different trust
    # profile than the retry host observes: the retry must fail closed.
    export M8_RETRY_FIXTURE_INDEX_PROFILE_SHA='5555555555555555555555555555555555555555555555555555555555555555'
    bootstrap_retry_fixture || { printf 'T11: the retry fixture failed\n'; return 1; }
    # shellcheck source=/dev/null
    source "$WRAPPER"
    m8_wrapper_init
    m8_guard_local_syntax || return 1
    establish_oss_trust_target || return 1
    assert_eq "$OSS_TRUST_PROFILE_SHA256" "$PROFILE_SHA" 'retry trust-profile identity'

    export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/t11-mut.log"
    : >"$M8_FAKE_OSS_MUTATION_LOG"
    m8_load_authorization || return 1
    m8_claim_create || return 1
    if m8_phase_b_seal 2>/dev/null; then
      printf 'T11: a retry sealed an index bound to a different trust profile\n'; return 1
    fi

    # The mismatch is detected before any further mutating call: the atomic claim
    # is the only object written, and no receipt is produced.
    assert_eq "$(grep -c '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG")" '1' 'only the atomic claim was written'
    assert_grep "^WRITE put-object $CLAIM_OBJECT\$" "$M8_FAKE_OSS_MUTATION_LOG"
    assert_no_file "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT"
  ) || return 1

  # The matching trust profile still retries successfully and never reruns the
  # core or the adapter.
  (
    run_retry_success || { printf 'T11: the matching retry succeeded path failed\n'; return 1; }
    assert_no_file "$EVIDENCE/stages.txt"
    assert_no_file "$EVIDENCE/adapter-raw.log"
  )
}

t12() {
  (
    export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/t12-mut.log"
    : >"$M8_FAKE_OSS_MUTATION_LOG"
    run_formal_success >/dev/null || { printf 'T12: the semantic fixture failed\n'; return 1; }
    local log="$TMPROOT/t12-mut.log"
    assert_file "$log"

    # The first permitted mutating call of the whole formal run is the atomic
    # claim; nothing is written before it.
    assert_eq "$(grep -n '^WRITE' "$log" | head -n1 | sed 's/:.*//')" \
      "$(grep -n "^WRITE put-object $CLAIM_OBJECT\$" "$log" | cut -d: -f1)" \
      'the first write is the atomic claim'
    assert_eq "$(grep -c '^WRITE' "$log" | tr -d ' ')" '4' 'exactly four canonical writes'
    assert_eq "$(grep -c "^WRITE put-object $ARCHIVE_OBJECT\$" "$log")" '1' 'archive written once'
    assert_eq "$(grep -c "^WRITE put-object $PACKAGE_INDEX_OBJECT\$" "$log")" '1' 'package index written once'
    assert_eq "$(grep -c "^WRITE put-object $RECEIPT_OBJECT\$" "$log")" '1' 'receipt written once'
    assert_eq "$(grep -c "^WRITE put-object $CLAIM_OBJECT\$" "$log")" '1' 'claim written once'

    # All read-only trust-target establishment strictly precedes the first write.
    local first_write location versioning
    first_write="$(grep -n '^WRITE' "$log" | head -n1 | cut -d: -f1)"
    location="$(grep -n '^READ get-bucket-location' "$log" | head -n1 | cut -d: -f1)"
    versioning="$(grep -n '^READ get-bucket-versioning' "$log" | head -n1 | cut -d: -f1)"
    [[ -n "$location" && -n "$versioning" ]] ||
      { printf 'T12: the read-only trust-target reads were never issued\n'; return 1; }
    (( location < first_write )) ||
      { printf 'T12: bucket location was not read before the first write\n'; return 1; }
    (( versioning < first_write )) ||
      { printf 'T12: bucket versioning was not read before the first write\n'; return 1; }

    # B03 provenance rides in the existing PHASE-A wrapper-provenance.txt
    # artifact; no new artifact is introduced, and every recorded value is live.
    local provenance="$EVIDENCE/wrapper-provenance.txt"
    assert_file "$provenance"
    assert_contains "$provenance" "oss_trust_profile_sha256=$(m8_json_get "$M8_FAKE_OSS_ROOT/objects/$M8_OSS_BUCKET/$RECEIPT_OBJECT" oss_trust_profile_sha256)"
    assert_contains "$provenance" 'bucket_location_observed=oss-cn-hongkong'
    # The offline fixture drives the phase functions directly, so the entrypoint
    # guard never ran; the provenance reports that honestly rather than claiming
    # a pass. The entrypoint assignment itself is asserted statically below.
    assert_contains "$provenance" 'environment_guard=NOT_RUN'
    assert_contains "$provenance" 'oss_trust_profile_field_count=18'
    assert_eq "$(sed -n '/^schema=/,$p' "$provenance" | grep -c '^[a-z0-9_]*=')" '18' 'provenance records the full 18-field profile'
    assert_no_grep '^bucket_location_observed=$' "$provenance"
    assert_no_grep '^oss_trust_profile_sha256=$' "$provenance"
    assert_no_grep '^ossutil_absolute_path=$' "$provenance"

    # The entrypoint marks the closed-environment guard as PASS only after both
    # reject guards and well before the claim.
    local body="$TMPROOT/t12.wrapper-run" guard_line pass_line claim_call first_put
    sed -n '/^m8_wrapper_run()/,/^}/p' "$WRAPPER" >"$body"
    guard_line="$(grep -n 'm8_reject_oss_trust_environment || return 1' "$body" | cut -d: -f1)"
    pass_line="$(grep -n "ENVIRONMENT_GUARD_STATE='PASS'" "$body" | cut -d: -f1)"
    claim_call="$(grep -n 'm8_claim_create || return 1' "$body" | head -n1 | cut -d: -f1)"
    [[ -n "$guard_line" && -n "$pass_line" && -n "$claim_call" ]] ||
      { printf 'T12: the entrypoint guard ordering anchors are missing\n'; return 1; }
    (( guard_line < pass_line && pass_line < claim_call )) ||
      { printf 'T12: environment_guard=PASS is not set between the guard and the claim\n'; return 1; }

    # Static: the wrapper cannot reach a PutObject before the claim call.
    first_put="$(grep -n 'm8_oss_put_object\|m8_oss_api put-object' "$body" | head -n1 | cut -d: -f1)"
    [[ -z "$first_put" || "$claim_call" -le "$first_put" ]] ||
      { printf 'T12: the wrapper can reach a PutObject before the claim\n'; return 1; }
  )
}

# ===========================================================================
# R2I-C7 — immutable provider-identity binary-safety regressions (P01..P04).
#
# These exercise the REAL production provider verifier and the REAL preflight
# through an offline fake IMDS that serves raw payload bytes verbatim (including
# NUL). They are deliberately separate from V/C/I/T: the legacy suite fabricates
# the provider capture outputs and never drives the live verification path.
# ===========================================================================

# Offline IMDS client for the provider probes. Serves M8_FAKE_PROVIDER_DIR/<rel>
# byte-for-byte with `cat`, so a NUL in a payload reaches the production
# classifier unchanged. Also implements the tokenless 403 probe and token mode.
write_fake_imds_provider_client() {
  local path="$TMPROOT/fake-imds-provider-curl.sh"
  cat >"$path" <<'FAKEPROVIDER'
#!/usr/bin/env bash
set -Eeuo pipefail
url=''; token_header='no'; put='no'; output=''
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    http://*|https://*) url="${args[$i]}" ;;
    -H)
      i=$((i + 1))
      case "${args[$i]:-}" in X-aliyun-ecs-metadata-token:*) token_header='yes' ;; esac
      ;;
    -X)
      i=$((i + 1))
      [[ "${args[$i]:-}" == 'PUT' ]] && put='yes'
      ;;
    --output) i=$((i + 1)); output="${args[$i]:-}" ;;
  esac
  i=$((i + 1))
done
if [[ -n "${M8_FAKE_PROVIDER_LOG:-}" ]]; then printf '%s\n' "$url" >>"$M8_FAKE_PROVIDER_LOG"; fi
if [[ "$token_header" == 'no' ]]; then
  # Tokenless probe: the reviewed contract is an HTTP 403.
  printf '403'
  exit 0
fi
if [[ "$put" == 'yes' && "$url" == */api/token ]]; then
  printf 'SYNTHETIC-PROVIDER-TOKEN-NOT-A-SECRET\n'
  exit 0
fi
base="${M8_FAKE_PROVIDER_BASE:?M8_FAKE_PROVIDER_BASE is required}"
rel="${url#"$base"/}"
payload="${M8_FAKE_PROVIDER_DIR:?M8_FAKE_PROVIDER_DIR is required}/$rel"
if [[ ! -f "$payload" ]]; then
  printf 'Error: no synthetic provider payload for %s\n' "$rel" >&2
  exit 22
fi
if [[ -n "$output" && "$output" != '/dev/null' ]]; then
  cp -f "$payload" "$output"
else
  cat "$payload"
fi
exit 0
FAKEPROVIDER
  chmod +x "$path"
  printf '%s' "$path"
}

# Raw payload writers. Bytes are written straight to the file: the NUL is never
# routed through a shell variable or command substitution.
provider_payload_write() { # dir rel value
  local dir=$1 rel=$2 value=$3
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\n' "$value" >"$dir/$rel"
}

provider_payload_write_nul() { # dir rel prefix suffix  -> prefix NUL suffix (no LF)
  local dir=$1 rel=$2 prefix=$3 suffix=$4
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\0%s' "$prefix" "$suffix" >"$dir/$rel"
}

# The suite's existing clean synthetic immutable payloads.
provider_payload_dir_clean() {
  local dir=$1
  rm -rf "$dir"
  mkdir -p "$dir"
  provider_payload_write "$dir" meta-data/instance-id "$EXPECTED_INSTANCE_ID"
  provider_payload_write "$dir" meta-data/region-id "$EXPECTED_REGION_ID"
  provider_payload_write "$dir" meta-data/zone-id "$EXPECTED_ZONE_ID"
  provider_payload_write "$dir" meta-data/instance/instance-type "$EXPECTED_INSTANCE_TYPE"
  provider_payload_write "$dir" meta-data/image-id "$EXPECTED_IMAGE_ID"
  provider_payload_write "$dir" dynamic/instance-identity/document 'synthetic-identity-document'
  provider_payload_write "$dir" dynamic/instance-identity/pkcs7 'synthetic-identity-pkcs7'
}

# Independent proof that a fixture really carries one real 0x00 byte.
provider_assert_single_nul() { # file label
  "$PYTHON" - "$1" "$2" <<'PY' || return 1
import sys

path, label = sys.argv[1], sys.argv[2]
with open(path, "rb") as handle:
    data = handle.read()
if data.count(b"\x00") != 1:
    sys.stderr.write(
        "fixture %s must contain exactly one real NUL byte, got %d in %r\n"
        % (label, data.count(b"\x00"), data)
    )
    raise SystemExit(1)
sys.stdout.write("NUL_FIXTURE_OK %s bytes=%d hex=%s\n" % (label, len(data), data.hex()))
PY
}

# Drive the REAL m8_provider_identity_verify against the offline fake IMDS. The
# pure tuple comparison is recorded rather than performed, so a probe can prove
# whether a malformed value ever reached it.
provider_verify_probe() { # payload_dir result_file [capture_dir]
  local dir=$1 result=$2 capture=${3:-'-'}
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    export M8_IMDS_CURL_BIN="$(write_fake_imds_provider_client)"
    export M8_IMDS_BASE_URL='http://imds.invalid/latest'
    export M8_FAKE_PROVIDER_BASE="$M8_IMDS_BASE_URL"
    export M8_FAKE_PROVIDER_DIR="$dir"
    local tuple_file="$TMPROOT/provider-assert-tuple.txt"
    local out="$TMPROOT/provider-probe-out.txt" err="$TMPROOT/provider-probe-err.txt"
    : >"$tuple_file"
    : >"$out"
    : >"$err"
    m8_provider_identity_assert() { printf '%s\n' "$*" >>"$tuple_file"; return 0; }
    local rc=0
    m8_provider_identity_verify "$capture" >"$out" 2>"$err" || rc=$?
    {
      printf 'verify_rc=%s\n' "$rc"
      printf 'assert_calls=%s\n' "$(wc -l <"$tuple_file" | tr -d '[:space:]')"
      printf 'assert_tuple=%s\n' "$(head -n1 "$tuple_file")"
      printf 'probe_stdout=%s\n' "$(cat "$out")"
      printf 'probe_stderr=%s\n' "$(cat "$err")"
    } >"$result"
  )
}

p01() {
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    p01_body
  )
}

p01_body() {
  # Five scalar immutable inputs, each carrying one REAL NUL such that deleting
  # the NUL would restore the frozen expected value. All five must fail closed
  # before the tuple comparison.
  local dir="$TMPROOT/p01" result="$TMPROOT/p01-result.txt"
  local -a cases=(
    'meta-data/instance-id|i-j6|c9854oyawy89fcdxy2|EXPECTED_INSTANCE_ID'
    'meta-data/region-id|cn-|hongkong|EXPECTED_REGION_ID'
    'meta-data/zone-id|cn-h|ongkong-d|EXPECTED_ZONE_ID'
    'meta-data/instance/instance-type|ecs.|g9i.xlarge|EXPECTED_INSTANCE_TYPE'
    'meta-data/image-id|ubuntu_|24_04_x64_20G_alibase_20260916.vhd|EXPECTED_IMAGE_ID'
  )
  local case rel prefix suffix var value
  for case in "${cases[@]}"; do
    IFS='|' read -r rel prefix suffix var <<<"$case"
    value="${!var}"
    # The NUL must split the frozen value exactly: deleting it restores `value`.
    assert_eq "${prefix}${suffix}" "$value" "P01 $var NUL split reconstructs the expected value"
    provider_payload_dir_clean "$dir"
    provider_payload_write_nul "$dir" "$rel" "$prefix" "$suffix"
    provider_assert_single_nul "$dir/$rel" "$var" || return 1
    provider_verify_probe "$dir" "$result"
    assert_eq "$(sed -n 's/^assert_calls=//p' "$result")" '0' \
      "P01 $var: a NUL value must never reach the tuple comparison"
    assert_eq "$(sed -n 's/^verify_rc=//p' "$result")" '1' "P01 $var: a NUL value must fail closed"
    assert_contains "$result" 'NUL'
    assert_no_grep 'ignored null byte in input' "$result"
  done
  # The region case is the exact 12-byte probe from the C7 contract.
  local region_probe="$TMPROOT/p01-region-probe.bin"
  provider_payload_dir_clean "$dir"
  provider_payload_write_nul "$dir" meta-data/region-id 'cn-' 'hongkong'
  cp -f "$dir/meta-data/region-id" "$region_probe"
  assert_eq "$(wc -c <"$region_probe" | tr -d '[:space:]')" '12' 'region NUL probe byte length'
  assert_eq "$(sha256sum "$region_probe" | cut -d' ' -f1)" \
    'e417c238ce2121c0144c412e2d1552d1da24320a87140141974bc4fab3112fd9' 'region NUL probe digest'
  return 0
}

p02() {
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    p02_body
  )
}

p02_body() {
  # The identity document and PKCS7 carry one REAL NUL each. Both must fail
  # before any canonical digest is accepted, and the clean payloads must still
  # produce the pre-C7 canonical digests.
  local dir="$TMPROOT/p02" result="$TMPROOT/p02-result.txt"
  local -a cases=(
    'dynamic/instance-identity/document|synthetic-identity-|document|document'
    'dynamic/instance-identity/pkcs7|synthetic-identity-|pkcs7|pkcs7'
  )
  local case rel prefix suffix label
  for case in "${cases[@]}"; do
    IFS='|' read -r rel prefix suffix label <<<"$case"
    provider_payload_dir_clean "$dir"
    provider_payload_write_nul "$dir" "$rel" "$prefix" "$suffix"
    provider_assert_single_nul "$dir/$rel" "$label" || return 1
    provider_verify_probe "$dir" "$result"
    assert_eq "$(sed -n 's/^assert_calls=//p' "$result")" '0' \
      "P02 $label: a NUL body must never reach digest acceptance"
    assert_eq "$(sed -n 's/^verify_rc=//p' "$result")" '1' "P02 $label: a NUL body must fail closed"
    assert_contains "$result" 'NUL'
    assert_no_grep 'ignored null byte in input' "$result"
  done
  return 0
}

p03() {
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    p03_body
  )
}

p03_body() {
  # The REAL preflight immutable-identity path, driven offline, with a NUL in the
  # region response. Preflight must fail in the identity section and must never
  # emit a normalised region or a PASS verdict.
  local dir="$TMPROOT/p03" stub="$TMPROOT/p03-bin"
  local out="$TMPROOT/p03-out.txt" err="$TMPROOT/p03-err.txt"
  provider_payload_dir_clean "$dir"
  provider_payload_write_nul "$dir" meta-data/region-id 'cn-' 'hongkong'
  provider_assert_single_nul "$dir/meta-data/region-id" 'preflight-region' || return 1

  # This host reports less than the preflight's ~16 GiB minimum; only the
  # MemTotal read is synthesised. Every other awk call passes through.
  local real_awk
  real_awk="$(command -v awk)"
  rm -rf "$stub"
  mkdir -p "$stub"
  cat >"$stub/awk" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == '/MemTotal:/ {print \$2}' && "\${2:-}" == '/proc/meminfo' ]]; then
  printf '32000000\n'
  exit 0
fi
exec $real_awk "\$@"
STUB
  chmod +x "$stub/awk"

  local rc=0
  (
    cd "$TMPROOT"
    PATH="$stub:$PATH" \
      M8_IMDS_BASE_URL='http://imds.invalid/latest' \
      M8_IMDS_CURL_BIN="$(write_fake_imds_provider_client)" \
      M8_FAKE_PROVIDER_BASE='http://imds.invalid/latest' \
      M8_FAKE_PROVIDER_DIR="$dir" \
      bash "$PREFLIGHT"
  ) >"$out" 2>"$err" || rc=$?

  (( rc != 0 )) || { printf 'P03: the preflight accepted a NUL region response\n'; return 1; }
  assert_no_contains "$out" 'provider_identity_match=PASS'
  # The reviewed-constant echo at the top of the report legitimately prints the
  # FROZEN region. The live observation section must never emit a normalised one,
  # so scope the assertion to that section.
  local live="$TMPROOT/p03-live.txt"
  sed -n '/^--- live read-only IMDS observation ---$/,$p' "$out" >"$live"
  assert_file "$live"
  assert_no_grep '^region_id=' "$live"
  assert_no_grep '^region_id=cn-hongkong$' "$live"
  # The failure must be attributed to the byte-safe region read, not to an
  # unrelated later check.
  assert_contains "$err" 'PREFLIGHT_FAIL: region-id read failed (byte-safe)'
  # It must have failed inside the identity section, never reaching the network
  # section (this test is fully offline).
  assert_no_contains "$out" 'frozen static binding'
  assert_grep 'NUL' "$err"
  assert_no_grep 'ignored null byte in input' "$err"
  assert_no_grep 'ignored null byte in input' "$out"

  # Static: preflight must not command-substitute any immutable endpoint read.
  local offenders="$TMPROOT/p03-offenders.txt"
  grep -nE 'instance-id|region-id|zone-id|instance-type|image-id|instance-identity' "$PREFLIGHT" \
    | grep -E '\$\(m8_imds_get' >"$offenders" || true
  assert_eq "$(wc -l <"$offenders" | tr -d '[:space:]')" '0' \
    'preflight must not command-substitute an immutable endpoint read'
  assert_contains "$PREFLIGHT" 'm8_provider_identity_scalar_read'
  assert_contains "$PREFLIGHT" 'm8_provider_identity_digest_read'
  return 0
}

p04() {
  (
    # shellcheck source=/dev/null
    source "$IDENTITY_LIB"
    p04_body
  )
}

p04_body() {
  # Clean semantic compatibility: for clean synthetic payloads the byte-safe path
  # must produce exactly the pre-C7 values and canonical digests, and the capture
  # files must stay byte-compatible. This proves C7 is a binary-safety correction
  # and not an implicit provider rebind.
  local dir="$TMPROOT/p04" result="$TMPROOT/p04-result.txt"
  local capture="$TMPROOT/p04-capture"
  provider_payload_dir_clean "$dir"
  provider_verify_probe "$dir" "$result"
  assert_eq "$(sed -n 's/^assert_calls=//p' "$result")" '1' \
    'clean payloads must reach the tuple comparison exactly once'
  assert_eq "$(sed -n 's/^verify_rc=//p' "$result")" '0' 'clean payloads must verify'
  assert_no_grep 'ignored null byte in input' "$result"

  local tuple
  tuple="$(sed -n 's/^assert_tuple=//p' "$result")"
  [[ -n "$tuple" ]] || { printf 'P04: the tuple comparison recorded nothing\n'; return 1; }

  # Independently recompute the pre-C7 semantics: command substitution stripped
  # trailing LFs; the capture/digest form was printf '%s\n' of the result.
  "$PYTHON" - "$dir" "$tuple" <<'PY' || return 1
import hashlib
import sys

payload_dir, tuple_line = sys.argv[1], sys.argv[2]
observed = tuple_line.split()
scalars = [
    ("meta-data/instance-id", 0),
    ("meta-data/region-id", 1),
    ("meta-data/zone-id", 2),
    ("meta-data/instance/instance-type", 3),
    ("meta-data/image-id", 4),
]
if len(observed) != 7:
    sys.stderr.write("P04: expected 7 tuple fields, got %d: %r\n" % (len(observed), observed))
    raise SystemExit(1)

for rel, index in scalars:
    with open("%s/%s" % (payload_dir, rel), "rb") as handle:
        raw = handle.read()
    # former Bash: value=$(...)  ->  trailing LF bytes removed
    expected = raw.rstrip(b"\n").decode("utf-8")
    if observed[index] != expected:
        sys.stderr.write("P04: %s observed %r, pre-C7 oracle %r\n" % (rel, observed[index], expected))
        raise SystemExit(1)

for rel, index, label in (
    ("dynamic/instance-identity/document", 5, "document"),
    ("dynamic/instance-identity/pkcs7", 6, "pkcs7"),
):
    with open("%s/%s" % (payload_dir, rel), "rb") as handle:
        raw = handle.read()
    # former Bash: printf '%s\n' "$(get)" | sha256sum
    canonical = raw.rstrip(b"\n") + b"\n"
    expected = hashlib.sha256(canonical).hexdigest()
    if observed[index] != expected:
        sys.stderr.write("P04: %s digest observed %s, pre-C7 oracle %s\n" % (label, observed[index], expected))
        raise SystemExit(1)
print("P04_PRE_C7_ORACLE_MATCH=YES")
PY

  # Capture-mode byte compatibility.
  rm -rf "$capture"
  mkdir -p "$capture"
  provider_verify_probe "$dir" "$TMPROOT/p04-capture-result.txt" "$capture" || return 1
  assert_eq "$(sed -n 's/^verify_rc=//p' "$TMPROOT/p04-capture-result.txt")" '0' 'clean capture probe must verify'
  assert_contains "$capture/primary/instance-id.txt" "$EXPECTED_INSTANCE_ID"
  assert_contains "$capture/primary/instance-identity-document.json" 'synthetic-identity-document'
  assert_eq "$(wc -c <"$capture/primary/instance-identity-document.json" | tr -d '[:space:]')" \
    "$(printf 'synthetic-identity-document\n' | wc -c | tr -d '[:space:]')" 'document capture byte length'
  assert_eq "$(sha256sum "$capture/primary/instance-identity-document.json" | cut -d' ' -f1)" \
    "$(sha256sum "$dir/dynamic/instance-identity/document" | cut -d' ' -f1)" 'document capture bytes are the canonical payload'
  assert_eq "$(tr -d '\n' <"$capture/primary/instance-identity-document.sha256")" \
    "$(sed -n 's/^assert_tuple=//p' "$result" | awk '{print $6}')" 'document digest file matches the observed digest'
  assert_eq "$(tr -d '\n' <"$capture/primary/instance-identity-pkcs7.sha256")" \
    "$(sed -n 's/^assert_tuple=//p' "$result" | awk '{print $7}')" 'pkcs7 digest file matches the observed digest'

  # No scratch file may survive any of the provider reads.
  assert_eq "$(find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name 'm8-provider-scalar.*' -o -name 'm8-provider-document.*' \) 2>/dev/null | wc -l | tr -d '[:space:]')" \
    '0' 'provider scratch files must not leak'
  return 0
}

# ===========================================================================
# R2I-C11 — auth-path correction regressions (S01..S18).
#
# The live runtime proved that ossutil 2.4.0 supports NEITHER a CLI
# --ecs-role-name ("unknown flag") NOR Ali-EcsRamRole through CLI --mode
# ("invalid value for flag(s) mode"). The role binding therefore moved into the
# proof-tree canonical config and is cross-bound against a fresh IMDSv2 role-name
# observation. These regressions prove the corrected auth path end to end.
# ===========================================================================

c11_config_path() { printf '%s' "$REPO_ROOT/scripts/config/m8-ossutil-formal.ini"; }

# Arm a complete synthetic network-capable OSS environment.
c11_arm_oss_env() {
  # shellcheck source=/dev/null
  source "$OSS_LIB"
  c11_arm_provider_seams
  export M8_PROOF_ROOT="$REPO_ROOT"
  export M8_OSS_BUCKET='test-bucket'
  export M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$TMPROOT/c11-oss"
  export M8_FAKE_OSS_LOCATION='cn-hongkong'
  export M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/c11-mut.log"
  export M8_FAKE_OSS_ARG_LOG="$TMPROOT/c11-args.log"
  mkdir -p "$M8_FAKE_OSS_ROOT/objects"
  : >"$M8_FAKE_OSS_MUTATION_LOG"
  : >"$M8_FAKE_OSS_ARG_LOG"
}

s01() {
  assert_eq "$(wc -c <"$(c11_config_path)" | tr -d '[:space:]')" '81' 'C11 canonical config byte count'
}

s02() {
  assert_eq "$(sha256sum "$(c11_config_path)" | cut -d' ' -f1)" \
    '43b384710e4d0944fa3fea3f4daf4dcaba280739cc40d9c31bdbd6c54772c47a' 'C11 canonical config digest'
}

s03() {
  assert_eq "$(cat "$(c11_config_path)")" \
    "$(printf '[default]\nlanguage=EN\nmode=Ali-EcsRamRole\necsRoleName=LinguaGraphM8ProofExecutor')" \
    'C11 canonical config exact semantic content'
  assert_eq "$(tr -cd '\r' <"$(c11_config_path)" | wc -c | tr -d '[:space:]')" '0' 'C11 config has no CR'
  assert_eq "$(tail -c 1 "$(c11_config_path)" | od -An -tx1 | tr -d ' \n')" '0a' 'C11 config has exactly one final LF'
}

s04() {
  (
    c11_arm_oss_env
    m8_oss_global_args >/dev/null || { printf 'S04: global args failed\n'; return 1; }
    local -a want=(--config-file "$REPO_ROOT/scripts/config/m8-ossutil-formal.ini" --region cn-hongkong \
      --endpoint https://oss-cn-hongkong-internal.aliyuncs.com --addressing-style virtual --ignore-env-var)
    assert_eq "${M8_OSS_GLOBAL_ARGS[*]}" "${want[*]}" 'C11 production CLI vector is exactly the five frozen pins'
  )
}

s05() {
  (
    c11_arm_oss_env
    m8_oss_global_args >/dev/null || { printf 'S05: global args failed\n'; return 1; }
    local joined=" ${M8_OSS_GLOBAL_ARGS[*]} "
    assert_eq "$([[ "$joined" == *' --mode '* ]] && echo present || echo absent)" 'absent' 'C11 vector has no --mode'
    assert_eq "$([[ "$joined" == *' --ecs-role-name '* ]] && echo present || echo absent)" 'absent' 'C11 vector has no --ecs-role-name'
  )
}

s06() {
  local cap out
  for cap in full no-forbid-overwrite no-global-flags no-location; do
    out="$(M8_FAKE_OSS_ROOT="$TMPROOT" M8_FAKE_OSS_CAPABILITY="$cap" "$FAKE_OSSUTIL" help 2>&1)"
    grep -q 'ecs-role-name' <<<"$out" &&
      { printf 'S06: synthetic help advertises --ecs-role-name for capability %s\n' "$cap"; return 1; }
  done
  return 0
}

s07() {
  # Exact ossutil 2.4.0 CLI surface, both facts taken from the captured live
  # runtime: `--ecs-role-name` is not a flag at all, and the help declares the
  # exact CLI --mode valid set
  #     valid value(s): "AK","StsToken","EcsRamRole","Anonymous"
  # so `Ali-EcsRamRole` and `RamRoleArn` are NOT CLI-valid modes. Everything here
  # is a parser-surface assertion against the synthetic stub (a local directory
  # that never handles credentials); the production path passes no CLI --mode.
  local out rc=0

  # (1) --ecs-role-name is not a flag.
  out="$(M8_FAKE_OSS_ROOT="$TMPROOT" "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
    --ecs-role-name Foo api get-bucket-location --bucket b 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'S07: the synthetic ossutil accepted a CLI --ecs-role-name\n'; return 1; }
  assert_contains <(printf '%s\n' "$out") 'unknown flag: --ecs-role-name'

  # (2) Ali-EcsRamRole is not a valid CLI --mode value (live-proven).
  rc=0
  out="$(M8_FAKE_OSS_ROOT="$TMPROOT" "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
    --mode Ali-EcsRamRole api get-bucket-location --bucket b 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'S07: the synthetic ossutil accepted CLI --mode Ali-EcsRamRole\n'; return 1; }
  assert_contains <(printf '%s\n' "$out") 'invalid value for flag(s) "mode"'

  # (3) RamRoleArn is absent from the captured valid set: the synthetic surface
  #     must not invent a CLI mode the real binary rejects.
  rc=0
  out="$(M8_FAKE_OSS_ROOT="$TMPROOT" "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
    --mode RamRoleArn api get-bucket-location --bucket b 2>&1)" || rc=$?
  (( rc != 0 )) || { printf 'S07: the synthetic ossutil accepted CLI --mode RamRoleArn\n'; return 1; }
  assert_contains <(printf '%s\n' "$out") 'invalid value for flag(s) "mode"'

  # (4) exactly the four captured valid CLI --mode values are accepted at the
  #     parser. `version` is a local credential-free banner command, so this is a
  #     parser-only assertion that exercises no credential boundary.
  local mode
  for mode in AK StsToken EcsRamRole Anonymous; do
    rc=0
    out="$(M8_FAKE_OSS_ROOT="$TMPROOT" "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
      --mode "$mode" version 2>&1)" || rc=$?
    assert_eq "$rc" '0' "S07: the synthetic parser must accept CLI --mode $mode"
    assert_contains <(printf '%s\n' "$out") 'ossutil version'
  done

  # (5) an accepted mode is genuinely parsed and recorded, not merely tolerated.
  #     The Anonymous probe is a read-only synthetic call against a local
  #     directory; no credential is read, printed or persisted.
  local alog="$TMPROOT/s07-args.log"
  : >"$alog"
  M8_FAKE_OSS_ROOT="$TMPROOT" M8_FAKE_OSS_ARG_LOG="$alog" M8_FAKE_OSS_LOCATION='cn-hongkong' \
    "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" --mode Anonymous \
    api get-bucket-location --bucket b >/dev/null 2>&1 ||
    { printf 'S07: the synthetic parser rejected CLI --mode Anonymous on an api call\n'; return 1; }
  assert_contains "$alog" 'cli_mode=Anonymous cli_role=none'

  # (6) the production path is config-only: the five-pin vector carries neither
  #     --mode nor --ecs-role-name.
  (
    c11_arm_oss_env
    m8_oss_global_args >/dev/null || { printf 'S07: global args failed\n'; return 1; }
    local joined=" ${M8_OSS_GLOBAL_ARGS[*]} "
    assert_eq "$([[ "$joined" == *' --mode '* ]] && echo present || echo absent)" 'absent' \
      'S07: the production CLI vector must not carry a --mode'
    assert_eq "$([[ "$joined" == *' --ecs-role-name '* ]] && echo present || echo absent)" 'absent' \
      'S07: the production CLI vector must not carry an --ecs-role-name'
  )
}

s08() {
  (
    c11_arm_oss_env
    local rc=0
    ( M8_OSS_ECS_ROLE_NAME='' m8_oss_global_args ) >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S08: a missing stored observed role fails closed'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d '[:space:]')" '0' 'S08: no OSS invocation was issued'
  )
}

s09() {
  (
    c11_arm_oss_env
    local rc=0
    ( M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor-OTHER' m8_oss_global_args ) >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S09: a stored role disagreeing with the config role fails closed'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d '[:space:]')" '0' 'S09: no OSS invocation was issued'
    # The purely local eligibility gate must reject it too, so the stored/config
    # binding is enforced even on the non-network trust-profile path.
    export M8_OSSUTIL_VERSION='2.4.0' M8_OSSUTIL_BINARY_SHA256='00'
    rc=0
    ( M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor-OTHER' m8_oss_trust_profile_assert_canonical )       >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S09: the eligibility gate rejects a stored role that disagrees with the config'
  )
}

s10() {
  (
    c11_arm_oss_env
    local rc=0
    ( M8_FAKE_IMDS_ROLE_NAME='LinguaGraphM8ProofExecutor-FRESH-OTHER' m8_oss_global_args ) >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S10: a fresh live role disagreeing with stored/config fails closed'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d '[:space:]')" '0' 'S10: no OSS invocation was issued'
  )
}

s11() {
  (
    c11_arm_oss_env
    local rc=0
    ( unset -f m8_provider_identity_observe_ecs_role_name; m8_oss_global_args ) >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S11: a missing durable provider helper fails closed (no stored-value fallback)'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d '[:space:]')" '0' 'S11: no OSS invocation was issued'
  )
}

s12() {
  (
    c11_arm_oss_env
    m8_oss_global_args >/dev/null || { printf 'S12: the fully bound vector was rejected\n'; return 1; }
    m8_oss_api get-bucket-location --bucket test-bucket >/dev/null ||
      { printf 'S12: the synthetic OSS invocation failed\n'; return 1; }
    assert_eq "$(grep -c '^READ get-bucket-location test-bucket$' "$M8_FAKE_OSS_MUTATION_LOG")" '1' 'S12: the call reached the synthetic store'
    assert_eq "$(grep -c 'config_role=LinguaGraphM8ProofExecutor cli_mode=none cli_role=none' "$M8_FAKE_OSS_ARG_LOG")" '1' \
      'S12: the call carried the config role and no CLI role'
    export M8_OSSUTIL_VERSION='2.4.0' M8_OSSUTIL_BINARY_SHA256='00'
    m8_oss_trust_profile_assert_canonical ||
      { printf 'S12: the eligibility gate rejected a fully bound profile\n'; return 1; }
  )
}

s13() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    assert_eq "$M8_OSS_AUTH_MODE" 'Ali-EcsRamRole' 'S13: frozen auth mode constant'
  )
}

s14() {
  (
    # shellcheck source=/dev/null
    source "$OSS_LIB"
    assert_eq "$M8_OSS_CONFIG_POLICY_ID" 'm8-proof-tree-imdsv2-role-config/v1' 'S14: config policy id'
    assert_eq "$M8_OSS_CONFIG_BYTES" '81' 'S14: config byte constant'
    assert_eq "$M8_OSS_CONFIG_SHA256" \
      '43b384710e4d0944fa3fea3f4daf4dcaba280739cc40d9c31bdbd6c54772c47a' 'S14: config sha constant'
  )
}

s15() {
  (
    c11_arm_oss_env
    export M8_OSSUTIL_VERSION='2.4.0'
    export M8_OSSUTIL_BINARY_SHA256="$(sha256sum "$FAKE_OSSUTIL" | cut -d' ' -f1)"
    local -a order=(
      schema oss_bucket oss_region effective_oss_endpoint endpoint_class network_policy
      addressing_style oss_auth_mode ecs_role_name ossutil_version ossutil_binary_sha256
      config_relpath config_sha256 config_profile config_policy_id ignore_oss_env_vars
      env_policy_id tls_verification
    )
    assert_eq "$(m8_oss_trust_profile_values | grep -c '^[a-z0-9_]*=')" '18' 'S15: exactly 18 records'
    assert_eq "$(m8_oss_trust_profile_values | cut -d= -f1 | tr '\n' ' ')" \
      "$(printf '%s ' "${order[@]}")" 'S15: frozen field order'
    assert_eq "$(m8_oss_trust_profile_values | tr -cd '\n' | wc -c | tr -d '[:space:]')" '18' 'S15: one LF per record'
    assert_eq "$(m8_oss_trust_profile_values | tail -c 1 | od -An -tx1 | tr -d ' \n')" '0a' 'S15: exactly one final LF'
    assert_eq "$(m8_oss_trust_profile_values | tr -cd '\r\000' | wc -c | tr -d '[:space:]')" '0' 'S15: no CR or NUL'
    assert_eq "$(head -c 3 <(m8_oss_trust_profile_values))" 'sch' 'S15: no BOM'
  )
}

s16() {
  (
    c11_arm_oss_env
    export M8_OSSUTIL_VERSION='2.4.0' M8_OSSUTIL_BINARY_SHA256='00'
    local profile
    profile="$(m8_oss_trust_profile_values)"
    grep -qxF 'oss_auth_mode=Ali-EcsRamRole' <<<"$profile" ||
      { printf 'S16: profile does not record the new auth mode\n'; return 1; }
    grep -qxF 'config_sha256=43b384710e4d0944fa3fea3f4daf4dcaba280739cc40d9c31bdbd6c54772c47a' <<<"$profile" ||
      { printf 'S16: profile does not record the new config sha\n'; return 1; }
    grep -qxF 'config_policy_id=m8-proof-tree-imdsv2-role-config/v1' <<<"$profile" ||
      { printf 'S16: profile does not record the new config policy id\n'; return 1; }
    grep -qxF 'ecs_role_name=LinguaGraphM8ProofExecutor' <<<"$profile" ||
      { printf 'S16: profile does not record the observed role\n'; return 1; }
  )
}

s17() {
  (
    c11_arm_oss_env
    export M8_OSSUTIL_VERSION='2.4.0'
    export M8_OSSUTIL_BINARY_SHA256="$(sha256sum "$FAKE_OSSUTIL" | cut -d' ' -f1)"
    local digest zero='0000000000000000000000000000000000000000000000000000000000000000'
    digest="$(m8_oss_trust_profile_sha256)"
    [[ "$(M8_OSS_BUCKET='test-bucket-two' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'S17: bucket change did not move the digest\n'; return 1; }
    [[ "$(M8_OSS_ECS_ROLE_NAME='SomeOtherRole' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'S17: observed role change did not move the digest\n'; return 1; }
    [[ "$(M8_OSSUTIL_VERSION='2.4.1' m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'S17: ossutil version change did not move the digest\n'; return 1; }
    [[ "$(M8_OSSUTIL_BINARY_SHA256="$zero" m8_oss_trust_profile_sha256)" != "$digest" ]] ||
      { printf 'S17: ossutil binary change did not move the digest\n'; return 1; }
  )
}

s18() {
  (
    c11_arm_oss_env
    local rc=0
    ( M8_OSS_ECS_ROLE_NAME='LinguaGraphM8ProofExecutor-OTHER' m8_oss_api get-bucket-location --bucket test-bucket ) \
      >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" '1' 'S18: a mismatched role cannot reach ossutil'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_MUTATION_LOG" | tr -d '[:space:]')" '0' 'S18: no synthetic OSS operation ran'
    assert_eq "$(wc -l <"$M8_FAKE_OSS_ARG_LOG" | tr -d '[:space:]')" '0' 'S18: no CLI vector was ever issued'
  )
}

# ===========================================================================
# R2I-C12 — versioning-response classifier correction regressions (X01..X27).
#
# The exact live ossutil 2.4.0 response on the bound ECS is
#   <VersioningConfiguration xmlns="http://doc.oss-cn-hangzhou.aliyuncs.com"/>
#   0.087913(s) elapsed
# i.e. 94 bytes / SHA-256
# 68b07ea885b0284072d2ed8c29181aaa049a7f6c86034ef508fa0d277a9a5dd4.
# The pre-C12 regex fullmatch classifier rejected that legitimate response as
# "unparseable". These regressions drive the REAL production guard over the new
# structured (xml.etree.ElementTree) classifier.
# ===========================================================================

readonly C12_LIVE_RESPONSE_BYTES='94'
readonly C12_LIVE_RESPONSE_SHA='68b07ea885b0284072d2ed8c29181aaa049a7f6c86034ef508fa0d277a9a5dd4'
readonly C12_OFFICIAL_NS='http://doc.oss-cn-hangzhou.aliyuncs.com'
readonly C12_UNPARSEABLE_LINE='bucket_versioning=REJECTED:unparseable versioning response'

# Arm a complete synthetic OSS environment for the C12 regressions.
c12_arm_env() {
  # shellcheck source=/dev/null
  source "$OSS_LIB"
  c11_arm_provider_seams
  export M8_PROOF_ROOT="$REPO_ROOT"
  export M8_OSS_BUCKET='test-bucket'
  export M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$TMPROOT/c12-oss"
  export M8_FAKE_OSS_LOCATION='cn-hongkong'
  export M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/c12-mut.log"
  mkdir -p "$M8_FAKE_OSS_ROOT"
  : >"$M8_FAKE_OSS_MUTATION_LOG"
}

# Drive the REAL production versioning guard over one synthetic fixture state and
# report its rc, its op accounting and the recorded pre-claim evidence file.
c12_guard() { # state
  local state=$1
  (
    c12_arm_env
    export M8_FAKE_OSS_VERSIONING="$state"
    local evidence="$TMPROOT/c12-evidence"
    rm -rf "$evidence"
    mkdir -p "$evidence"
    local rc=0
    m8_oss_versioning_guard "$evidence" || rc=$?
    printf 'guard_rc=%s\n' "$rc"
    printf 'write_count=%s\n' "$(grep -c '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG" || true)"
    printf 'read_count=%s\n' "$(grep -c '^READ get-bucket-versioning' "$M8_FAKE_OSS_MUTATION_LOG" || true)"
    printf '%s\n' '--- evidence ---'
    cat "$evidence/oss-versioning-guard.txt" 2>/dev/null || true
  )
}

# Drive the REAL production guard with an arbitrary raw payload through a scratch
# CLI stub, for payload shapes the fixture state table does not carry.
c12_guard_raw() { # payload-file
  local payload=$1
  (
    c12_arm_env
    local stub="$TMPROOT/c12-raw-stub"
    cat >"$stub" <<EOF
#!/usr/bin/env bash
cat "$payload"
EOF
    chmod +x "$stub"
    export M8_OSSUTIL_BIN="$stub"
    export M8_FAKE_OSS_MUTATION_LOG="$TMPROOT/c12-raw-mut.log"
    : >"$M8_FAKE_OSS_MUTATION_LOG"
    local evidence="$TMPROOT/c12-raw-evidence"
    rm -rf "$evidence"
    mkdir -p "$evidence"
    local rc=0
    m8_oss_versioning_guard "$evidence" || rc=$?
    printf 'guard_rc=%s\n' "$rc"
    printf 'write_count=%s\n' "$(grep -c '^WRITE' "$M8_FAKE_OSS_MUTATION_LOG" || true)"
    printf '%s\n' '--- evidence ---'
    cat "$evidence/oss-versioning-guard.txt" 2>/dev/null || true
  )
}

c12_field() { sed -n "s/^$2=//p" <<<"$1"; }

# The fixture state must be ELIGIBLE: guard rc 0, one read, no write.
c12_assert_eligible() { # state
  local state=$1 res
  res="$(c12_guard "$state")"
  assert_eq "$(c12_field "$res" guard_rc)" '0' "state $state must be eligible"
  assert_eq "$(c12_field "$res" write_count)" '0' "state $state must not write"
  assert_eq "$(c12_field "$res" read_count)" '1' "state $state must issue exactly one read"
  grep -qxF 'bucket_versioning=UNVERSIONED' <<<"$res" ||
    assert_fail "state $state did not record bucket_versioning=UNVERSIONED"
  return 0
}

# The fixture state must FAIL CLOSED: guard rc non-zero, no write, and optionally
# an exact evidence classification line.
c12_assert_rejected() { # state [expected_evidence_line]
  local state=$1 expected=${2:-} res
  res="$(c12_guard "$state")"
  [[ "$(c12_field "$res" guard_rc)" != '0' ]] ||
    assert_fail "state $state was accepted by the production guard"
  assert_eq "$(c12_field "$res" write_count)" '0' "state $state must not write"
  assert_eq "$(c12_field "$res" read_count)" '1' "state $state must issue exactly one read"
  if [[ -n "$expected" ]]; then
    grep -qxF "$expected" <<<"$res" || assert_fail "state $state evidence lacked: $expected"
  fi
  return 0
}

x01() {
  # The exact captured-live regression: the synthetic raw response must be
  # byte-identical to the live capture, and the REAL guard must accept it.
  (
    c12_arm_env
    local raw stripped
    raw="$(M8_FAKE_OSS_VERSIONING='live_namespace_timing' "$FAKE_OSSUTIL" \
      api get-bucket-versioning --bucket test-bucket)" || return 1
    stripped="$TMPROOT/c12-exact-response.bin"
    printf '%s' "$raw" >"$stripped"
    assert_eq "$(wc -c <"$stripped" | tr -d '[:space:]')" "$C12_LIVE_RESPONSE_BYTES" \
      'exact live response byte count'
    assert_eq "$(sha256sum "$stripped" | cut -d' ' -f1)" "$C12_LIVE_RESPONSE_SHA" \
      'exact live response digest'

    local res
    res="$(c12_guard live_namespace_timing)"
    assert_eq "$(c12_field "$res" guard_rc)" '0' 'the exact live response must be eligible'
    assert_eq "$(c12_field "$res" write_count)" '0' 'the exact live response must not write'
    assert_eq "$(c12_field "$res" read_count)" '1' 'the exact live response must issue one read'
    grep -qxF 'bucket_versioning=UNVERSIONED' <<<"$res" ||
      assert_fail 'the exact live response did not record UNVERSIONED'
    assert_contains <(printf '%s\n' "$res") 'get_bucket_versioning_rc=0'
    assert_contains <(printf '%s\n' "$res") "<VersioningConfiguration xmlns=\"$C12_OFFICIAL_NS\"/>"
    assert_contains <(printf '%s\n' "$res") '0.087913(s) elapsed'
    return 0
  )
}

x02() {
  # Structural positives: no Status at all (both namespace forms), Null status,
  # and the historically empty successful response.
  local state
  for state in namespace_empty no_namespace_empty null unversioned; do
    c12_assert_eligible "$state" || return 1
  done
  return 0
}

x03() {
  c12_assert_rejected enabled 'bucket_versioning=REJECTED:versioning Enabled' || return 1
  return 0
}

x04() {
  c12_assert_rejected suspended 'bucket_versioning=REJECTED:versioning Suspended' || return 1
  return 0
}

x05() {
  # A non-zero query RC is still an outright rejection (never a classification).
  c12_assert_rejected denied || return 1
  return 0
}

x06() {
  c12_assert_rejected unknown_namespace "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x07() {
  c12_assert_rejected unexpected_child "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x08() {
  c12_assert_rejected duplicate_status "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x09() {
  c12_assert_rejected nested_status "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x10() {
  c12_assert_rejected root_attribute "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x11() {
  c12_assert_rejected wrong_root "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x12() {
  c12_assert_rejected malformed_xml "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x13() {
  c12_assert_rejected doctype "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x14() {
  c12_assert_rejected entity "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x15() {
  c12_assert_rejected trailing_garbage "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x16() {
  c12_assert_rejected double_timing_footer "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x17() {
  # Only absent / empty / Null may mean UNVERSIONED. Unknown statuses fail closed
  # with the precise UNKNOWN diagnostic, and the historical "unversioned"/"none"
  # magic aliases and blanket case folding are gone.
  c12_assert_rejected unknown_status \
    'bucket_versioning=REJECTED:unknown versioning status '"'"'Bogus'"'"'' || return 1
  local payload got
  for payload in '{"Status": "unversioned"}' '{"Status": "none"}' \
    '<VersioningConfiguration><Status>unversioned</Status></VersioningConfiguration>' \
    '<VersioningConfiguration><Status>none</Status></VersioningConfiguration>' \
    '<VersioningConfiguration><Status>enabled</Status></VersioningConfiguration>'; do
    printf '%s' "$payload" >"$TMPROOT/c12-x17-payload"
    got="$(c12_guard_raw "$TMPROOT/c12-x17-payload")"
    [[ "$(c12_field "$got" guard_rc)" != '0' ]] ||
      assert_fail "magic/aliased status was accepted: $payload"
    assert_eq "$(c12_field "$got" write_count)" '0' "aliased status must not write: $payload"
  done
  return 0
}

x18() {
  # Payload shapes beyond the fixture state table, driven through the REAL guard
  # via a scratch CLI stub: multiple documents, stray root text, child tail,
  # Status attributes, Status in an inconsistent namespace, an embedded (not
  # terminal) footer, a non-conforming footer, real invalid UTF-8, and the
  # legacy unparseable text state.
  (
    c12_arm_env
    local payload="$TMPROOT/c12-x18-payload" res
    printf '%s' '<VersioningConfiguration/><VersioningConfiguration/>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'multiple XML documents were accepted'
    assert_eq "$(c12_field "$res" write_count)" '0' 'multiple documents must not write'

    printf '%s' '<VersioningConfiguration>x<Status>Null</Status></VersioningConfiguration>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'non-whitespace root text was accepted'

    printf '%s' '<VersioningConfiguration><Status>Null</Status>tail</VersioningConfiguration>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'a non-whitespace child tail was accepted'

    printf '%s' '<VersioningConfiguration><Status foo="1">Null</Status></VersioningConfiguration>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'Status with an attribute was accepted'

    printf '<VersioningConfiguration xmlns="%s"><Status xmlns="">Null</Status></VersioningConfiguration>' \
      "$C12_OFFICIAL_NS" >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] ||
      assert_fail 'Status in a namespace inconsistent with the root was accepted'

    printf '<VersioningConfiguration xmlns="%s"><Status>Null</Status></VersioningConfiguration>' \
      "$C12_OFFICIAL_NS" >"$payload"
    res="$(c12_guard_raw "$payload")"
    assert_eq "$(c12_field "$res" guard_rc)" '0' 'official-namespace Status must be eligible'

    # A footer embedded BEFORE further text is not a terminal footer.
    printf '%s' '0.087913(s) elapsed
<VersioningConfiguration/>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'an embedded timing footer was accepted'

    # The footer grammar is frozen: "(s) elapsed" is literal.
    printf '%s' '<VersioningConfiguration/>
0.087913 elapsed' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'a non-conforming footer was accepted'

    # A real invalid UTF-8 byte must fail closed, never be silently normalised.
    printf '<VersioningConfiguration\xff/>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'invalid UTF-8 was accepted'

    # Legacy unparseable text state remains rejected.
    c12_assert_rejected garbage "$C12_UNPARSEABLE_LINE" || return 1
    return 0
  )
}

x19() {
  # Static: the XML branch is STRUCTURED, not regex, and never normalises bytes.
  local body="$TMPROOT/c12-guard-body"
  sed -n '/^m8_oss_versioning_guard()/,/^}/p' "$OSS_LIB" >"$body"
  assert_file "$body"
  assert_contains "$body" 'import xml.etree.ElementTree as ET'
  assert_contains "$body" 'ET.XMLParser(target=builder)'
  assert_contains "$body" 'OFFICIAL_NS = "http://doc.oss-cn-hangzhou.aliyuncs.com"'
  assert_contains "$body" '"<!doctype" in lowered'
  assert_contains "$body" '"<!entity" in lowered'
  assert_contains "$body" 'TIMING_FOOTER.fullmatch'
  assert_contains "$body" 'data.decode("utf-8")'
  # The pre-C12 broad-regex XML classification is gone...
  assert_no_contains "$body" '(?is)(<\?xml'
  assert_no_contains "$body" '<VersioningConfiguration\s*/>'
  assert_no_contains "$body" '<VersioningConfiguration>\s*</VersioningConfiguration>'
  assert_no_contains "$body" '<Status>\s*([^<]*?)\s*</Status>'
  # ...and the response is never read with lossy decoding.
  assert_no_contains "$body" 'errors="replace"'
  return 0
}

x20() {
  # F05: a malformed XML declaration must not be repaired before parsing.
  c12_assert_rejected xml_decl_garbage "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected xml_decl_attribute "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x21() {
  # A valid ordinary XML declaration is validated by the XML parser itself.
  c12_assert_eligible xml_decl_valid || return 1
  return 0
}

x22() {
  # F06: comments / processing instructions inside the root are not "empty".
  c12_assert_rejected comment_child "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected pi_child "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x23() {
  # Comments / PIs at document level before and after the root are dropped
  # silently by the default TreeBuilder, so they must be rejected explicitly.
  c12_assert_rejected outer_comment_before "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected outer_comment_after "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected outer_pi_before "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected outer_pi_after "$C12_UNPARSEABLE_LINE" || return 1
  return 0
}

x24() {
  # F07: the footer line must match the frozen grammar EXACTLY, while an exact
  # footer (and the exact captured-live response) stay eligible.
  c12_assert_rejected footer_leading_space "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_rejected footer_trailing_space "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_eligible exact_footer || return 1
  c12_assert_eligible live_namespace_timing || return 1
  return 0
}

x25() {
  # A declaration that is not at the very start of the document stays malformed
  # (no trimming may rescue it), while leading whitespace before a plain root
  # element follows ordinary XML parser semantics.
  c12_assert_rejected misplaced_declaration "$C12_UNPARSEABLE_LINE" || return 1
  c12_assert_eligible leading_ws_root || return 1
  return 0
}

x26() {
  # Document-level shapes the fixture state table does not carry, driven through
  # the REAL guard: comment-only, PI-only, a comment inside Status, and a valid
  # declaration carrying an encoding attribute.
  (
    c12_arm_env
    local payload="$TMPROOT/c12-x26-payload" res
    printf '%s' '<!--c-->' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'a comment-only document was accepted'
    assert_eq "$(c12_field "$res" write_count)" '0' 'a comment-only document must not write'

    printf '%s' '<?pi x?>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'a PI-only document was accepted'

    printf '%s' '<VersioningConfiguration><Status><!--c-->Null</Status></VersioningConfiguration>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    [[ "$(c12_field "$res" guard_rc)" != '0' ]] || assert_fail 'a comment inside Status was accepted'

    printf '%s' '<?xml version="1.0" encoding="UTF-8"?><VersioningConfiguration/>' >"$payload"
    res="$(c12_guard_raw "$payload")"
    assert_eq "$(c12_field "$res" guard_rc)" '0' 'a valid encoding declaration must be eligible'
    return 0
  )
}

x27() {
  # Static C12-A1 proof: no prolog pre-processing, observable comments/PIs, no
  # blanket strip of the parsed payload, and an exact footer match.
  local body="$TMPROOT/c12a1-guard-body"
  sed -n '/^m8_oss_versioning_guard()/,/^}/p' "$OSS_LIB" >"$body"
  assert_file "$body"
  assert_no_contains "$body" 'XML_PROLOG'
  assert_no_contains "$body" 'prolog ='
  assert_no_contains "$body" 'xml_text'
  assert_contains "$body" 'insert_comments=True'
  assert_contains "$body" 'insert_pis=True'
  assert_contains "$body" 'ET.XMLParser(target=builder)'
  assert_contains "$body" 'parser.feed(body)'
  assert_contains "$body" 'parser.close()'
  assert_contains "$body" 'builder.non_element_nodes > 0'
  assert_contains "$body" 'body = "\n".join(lines)'
  assert_no_contains "$body" 'body = "\n".join(lines).strip()'
  assert_contains "$body" 'TIMING_FOOTER.fullmatch(lines[-1])'
  assert_no_contains "$body" 'TIMING_FOOTER.fullmatch(lines[-1].strip())'
  return 0
}

# ===========================================================================
# R2I-C13 — GetObject byte-exactness correction regressions (Y01..Y08).
#
# Live ossutil 2.4.0 appends a NON-BODY `<n>.<n>(s) elapsed` footer to ordinary
# `get-object` stdout, so a bare stdout -> file redirection is NOT byte-exact.
# Production therefore requires `get-object --quiet`; the synthetic client models
# exactly that framing. These regressions are deliberately separate from the
# V01..V40 / C01..C09 / I01..I02 / T01..T12 / P01..P04 / S01..S18 / X01..X27
# sets: a green legacy baseline is not evidence of GetObject byte exactness.
# ===========================================================================

# The exact live-captured 21-byte elapsed epilogue, as an independent oracle.
readonly C13_FOOTER=$'\n0.089713(s) elapsed\n'

# Arm a complete synthetic network-capable OSS environment with a GetObject
# framing log.
c13_arm_oss_env() {
  # shellcheck source=/dev/null
  source "$OSS_LIB"
  c11_arm_provider_seams
  export M8_PROOF_ROOT="$REPO_ROOT"
  export M8_OSS_BUCKET='test-bucket'
  export M8_OSSUTIL_BIN="$FAKE_OSSUTIL"
  export M8_FAKE_OSS_ROOT="$TMPROOT/c13-oss"
  export M8_FAKE_OSS_LOCATION='cn-hongkong'
  export M8_FAKE_OSS_VERSIONING='unversioned'
  export M8_FAKE_OSS_GET_LOG="$TMPROOT/c13-get.log"
  mkdir -p "$M8_FAKE_OSS_ROOT/objects/test-bucket"
  : >"$M8_FAKE_OSS_GET_LOG"
}

# Stage a known object body directly in the synthetic store, so the read-back
# source is reproducible without depending on the upload path.
c13_stage_key() {
  local key=$1 source=$2
  local destination="$M8_FAKE_OSS_ROOT/objects/test-bucket/$key"
  mkdir -p "$(dirname "$destination")"
  cp -f "$source" "$destination"
}

# Y01 — the false oracle: plain stdout redirection is NOT byte-exact. Driving the
# synthetic client WITHOUT quiet yields the exact body followed by the
# deterministic footer.
y01() {
  local root="$TMPROOT/y01-oss" src="$TMPROOT/y01-src.txt" out="$TMPROOT/y01-out.txt"
  local prefix="$TMPROOT/y01-prefix" tail="$TMPROOT/y01-tail" want="$TMPROOT/y01-footer"
  mkdir -p "$root/objects/test-bucket/runs/y01"
  printf 'no-quiet contamination payload\n' >"$src"
  cp -f "$src" "$root/objects/test-bucket/runs/y01/a.txt"

  # Exactly the shape the historical C05 oracle treated as byte-exactness proof.
  M8_FAKE_OSS_ROOT="$root" "$FAKE_OSSUTIL" \
    --config-file "$(c11_config_path)" \
    api get-object --bucket test-bucket --key runs/y01/a.txt >"$out"

  local src_bytes out_bytes
  src_bytes=$(wc -c <"$src")
  out_bytes=$(wc -c <"$out")
  (( out_bytes > src_bytes )) ||
    { printf 'Y01: no-quiet get-object stdout was not longer than the source\n'; return 1; }
  assert_eq "$out_bytes" "$(( src_bytes + 21 ))" 'Y01: stdout is the source plus the 21-byte footer'

  head -c "$src_bytes" "$out" >"$prefix"
  cmp -s "$src" "$prefix" ||
    { printf 'Y01: the exact source bytes are not the no-quiet stdout prefix\n'; return 1; }

  printf '%s' "$C13_FOOTER" >"$want"
  tail -c 21 "$out" >"$tail"
  cmp -s "$want" "$tail" ||
    { printf 'Y01: the deterministic elapsed footer is absent or wrong\n'; return 1; }

  if cmp -s "$src" "$out"; then
    printf 'Y01: plain stdout redirection was byte-exact (the oracle is still wrong)\n'
    return 1
  fi
  printf 'Y01_NO_QUIET_CONTAMINATION=PASS\n'
  return 0
}

# Y02 — production binds GetObject to --quiet, statically (function-scoped, never
# a repository-wide grep) and behaviorally (synthetic framing log), while --quiet
# stays OUT of the five-pin global vector.
y02() {
  local body="$TMPROOT/y02-get" gargs="$TMPROOT/y02-gargs"
  sed -n '/^m8_oss_get_object()/,/^}/p' "$OSS_LIB" >"$body"
  assert_file "$body"
  assert_contains "$body" 'm8_oss_api get-object --quiet'
  assert_no_contains "$body" 'm8_oss_api get-object --bucket'

  sed -n '/^m8_oss_global_args()/,/^}/p' "$OSS_LIB" >"$gargs"
  assert_file "$gargs"
  assert_no_contains "$gargs" 'quiet'

  (
    c13_arm_oss_env
    local src="$TMPROOT/y02-src" out="$TMPROOT/y02-out"
    printf 'quiet framing probe\n' >"$src"
    c13_stage_key 'runs/y02/a.txt' "$src"
    m8_oss_get_object 'runs/y02/a.txt' "$out" - || return 1
    assert_eq "$(wc -l <"$M8_FAKE_OSS_GET_LOG" | tr -d ' ')" '1' \
      'Y02: exactly one GetObject invocation'
    assert_eq "$(cat "$M8_FAKE_OSS_GET_LOG")" \
      'operation=get-object seam=stdout quiet=yes' \
      'Y02: production frames GetObject with --quiet'
    m8_oss_global_args >/dev/null || return 1
    assert_eq "${#M8_OSS_GLOBAL_ARGS[@]}" '9' 'Y02: five pins expand to nine argv tokens'
    local joined=" ${M8_OSS_GLOBAL_ARGS[*]} "
    assert_eq "$([[ "$joined" == *' --quiet '* ]] && echo present || echo absent)" \
      'absent' 'Y02: --quiet is not a sixth trust-target pin'
    printf 'Y02_PRODUCTION_USES_QUIET=PASS\n'
  )
}

# Y03 — text payload byte exactness through production m8_oss_get_object.
y03() {
  (
    c13_arm_oss_env
    local src="$TMPROOT/y03-src" out="$TMPROOT/y03-out"
    printf 'text payload\nexactly these bytes\n' >"$src"
    c13_stage_key 'runs/y03/text.txt' "$src"
    m8_oss_get_object 'runs/y03/text.txt' "$out" - || return 1
    assert_eq "$(wc -c <"$out" | tr -d ' ')" "$(wc -c <"$src" | tr -d ' ')" 'Y03: byte count'
    assert_eq "$(sha256sum "$out" | cut -d' ' -f1)" "$(sha256sum "$src" | cut -d' ' -f1)" \
      'Y03: SHA-256'
    cmp -s "$src" "$out" || { printf 'Y03: text payload is not byte-exact\n'; return 1; }
    printf 'Y03_TEXT_BYTE_EXACT=PASS\n'
  )
}

# Y04 — arbitrary binary payload byte exactness. The payload carries NUL, LF, CR,
# DEL, 0x80 and 0xFF and is written straight to a file, never through shell
# command substitution.
y04() {
  (
    c13_arm_oss_env
    local src="$TMPROOT/y04-bin" out="$TMPROOT/y04-out"
    printf 'A\000B\nC\rD\177E\200\377F' >"$src"
    assert_eq "$(wc -c <"$src" | tr -d ' ')" '12' 'Y04: binary source is 12 bytes'
    c13_stage_key 'runs/y04/bin.dat' "$src"
    m8_oss_get_object 'runs/y04/bin.dat' "$out" - || return 1
    cmp -s "$src" "$out" || { printf 'Y04: binary payload is not byte-exact\n'; return 1; }
    assert_eq "$(wc -c <"$out" | tr -d ' ')" "$(wc -c <"$src" | tr -d ' ')" 'Y04: byte count'
    assert_eq "$(sha256sum "$out" | cut -d' ' -f1)" "$(sha256sum "$src" | cut -d' ' -f1)" \
      'Y04: SHA-256'
    printf 'Y04_BINARY_BYTE_EXACT=PASS\n'
  )
}

# Y05 — the `no-get-object-quiet` capability means GetObject EXISTS but quiet
# framing does not. Three distinct facts are proven: the capability guard fails
# closed; the runtime parser rejects BOTH quiet spellings (hiding the flag from
# help is not enough); and an ordinary no-quiet GetObject still works.
y05() {
  (
    c13_arm_oss_env
    local rc=0 out=''

    # A. The capability guard fails closed for the GetObject quiet reason.
    out="$(M8_FAKE_OSS_CAPABILITY=no-get-object-quiet m8_oss_capability_guard - 2>&1)" || rc=$?
    (( rc != 0 )) ||
      { printf 'Y05: the capability guard accepted a client without get-object --quiet\n'; return 1; }
    grep -Fq 'get-object' <<<"$out" ||
      { printf 'Y05: the refusal does not name get-object:\n%s\n' "$out"; return 1; }
    grep -Fq -- '--quiet' <<<"$out" ||
      { printf 'Y05: the refusal does not name --quiet:\n%s\n' "$out"; return 1; }
    printf 'Y05_CAPABILITY_FAIL_CLOSED=PASS\n'

    # B. Runtime parser fidelity: both spellings must be REJECTED, not merely
    #    hidden. stderr is captured; stdout (a body, if any) goes to $body so a
    #    silent success cannot masquerade as a rejection.
    local src="$TMPROOT/y05-src" body="$TMPROOT/y05-body" flag
    printf 'negative-mode body bytes\n' >"$src"
    c13_stage_key 'runs/y05/a.txt' "$src"
    for flag in --quiet -q; do
      : >"$body"
      out=''; rc=0
      out="$(M8_FAKE_OSS_ROOT="$M8_FAKE_OSS_ROOT" M8_FAKE_OSS_CAPABILITY=no-get-object-quiet \
        "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
        api get-object "$flag" --bucket test-bucket --key runs/y05/a.txt 2>&1 >"$body")" || rc=$?
      (( rc != 0 )) ||
        { printf 'Y05: no-get-object-quiet accepted %s at runtime\n' "$flag"; return 1; }
      grep -Fq -- "$flag" <<<"$out" ||
        { printf 'Y05: the %s rejection does not name the flag:\n%s\n' "$flag" "$out"; return 1; }
      grep -Fqi 'unknown flag' <<<"$out" ||
        { printf 'Y05: the %s rejection is not an unsupported-flag diagnostic:\n%s\n' "$flag" "$out"; return 1; }
      [[ ! -s "$body" ]] ||
        { printf 'Y05: %s still produced a response body\n' "$flag"; return 1; }
    done
    printf 'Y05_RUNTIME_QUIET_REJECTED=PASS\n'

    # C. Control: the negative mode does NOT mean GetObject is broken. An ordinary
    #    no-quiet GetObject still succeeds with body+footer framing.
    : >"$body"; rc=0
    M8_FAKE_OSS_ROOT="$M8_FAKE_OSS_ROOT" M8_FAKE_OSS_CAPABILITY=no-get-object-quiet \
      "$FAKE_OSSUTIL" --config-file "$(c11_config_path)" \
      api get-object --bucket test-bucket --key runs/y05/a.txt >"$body" 2>/dev/null || rc=$?
    assert_eq "$rc" '0' 'Y05: ordinary no-quiet GetObject still succeeds in the negative mode'
    local src_bytes
    src_bytes=$(wc -c <"$src")
    assert_eq "$(wc -c <"$body" | tr -d ' ')" "$(( src_bytes + 21 ))" \
      'Y05: the negative-mode control still uses body+footer framing'
    head -c "$src_bytes" "$body" >"$TMPROOT/y05-prefix"
    cmp -s "$src" "$TMPROOT/y05-prefix" ||
      { printf 'Y05: the negative-mode control body is not the exact source prefix\n'; return 1; }
    printf 'Y05_ORDINARY_GET_CONTROL=PASS\n'

    printf 'Y05_MISSING_QUIET_FAIL_CLOSED=PASS\n'
  )
}

# Y06 — the ordinary corrected capability surface still PASSES, so Y05 is
# specific to the missing quiet capability rather than a blanket rejection.
y06() {
  (
    c13_arm_oss_env
    M8_FAKE_OSS_CAPABILITY=full m8_oss_capability_guard - || return 1
    printf 'Y06_CAPABILITY_PASS=PASS\n'
  )
}

# Y07 — the existing synthetic M8_OSSUTIL_GET_OUTPUT_FLAG response-body seam is
# preserved: the body stays byte-exact, is quiet-framed, and no client
# diagnostics are appended to the response body.
y07() {
  (
    c13_arm_oss_env
    export M8_OSSUTIL_GET_OUTPUT_FLAG='--output'
    local src="$TMPROOT/y07-src" out="$TMPROOT/y07-out"
    printf 'seam payload\000with binary\377\n' >"$src"
    c13_stage_key 'runs/y07/seam.bin' "$src"
    m8_oss_get_object 'runs/y07/seam.bin' "$out" - || return 1
    cmp -s "$src" "$out" || { printf 'Y07: the --output seam body is not byte-exact\n'; return 1; }
    assert_eq "$(cat "$M8_FAKE_OSS_GET_LOG")" \
      'operation=get-object seam=output quiet=yes' 'Y07: the seam is framed with --quiet'
    assert_eq "$(sha256sum "$out" | cut -d' ' -f1)" "$(sha256sum "$src" | cut -d' ' -f1)" \
      'Y07: seam SHA-256'
    printf 'Y07_OUTPUT_SEAM_PRESERVED=PASS\n'
  )
}

# Y08 — existing GetObject error semantics are preserved: absence, a non-absence
# failure, temporary-file cleanup, rename install and tampered read-back.
y08() {
  (
    c13_arm_oss_env
    local out="$TMPROOT/y08-out" rc=0

    # Absent object: M8_OSS_ABSENT, nothing installed, no temporary residue.
    rc=0
    m8_oss_get_object 'runs/y08/missing.txt' "$out" - || rc=$?
    assert_eq "$rc" "$M8_OSS_ABSENT" 'Y08: absent object returns M8_OSS_ABSENT'
    assert_no_file "$out"
    assert_no_file "${out}.part"
    assert_no_file "${out}.part.stderr"
    assert_no_file "${out}.part.stdout"

    # Success installs by rename and leaves no temporary residue.
    local src="$TMPROOT/y08-src"
    printf 'install-by-rename\n' >"$src"
    c13_stage_key 'runs/y08/present.txt' "$src"
    m8_oss_get_object 'runs/y08/present.txt' "$out" - || return 1
    assert_file "$out"
    cmp -s "$src" "$out" || { printf 'Y08: the rename install did not preserve bytes\n'; return 1; }
    assert_no_file "${out}.part"
    assert_no_file "${out}.part.stderr"

    # A non-absence GetObject failure returns M8_OSS_ERROR and installs nothing.
    local badbin="$TMPROOT/y08-bad-ossutil"
    cat >"$badbin" <<'EOS'
#!/usr/bin/env bash
printf 'Error: InternalError: synthetic server failure\n' >&2
exit 1
EOS
    chmod +x "$badbin"
    rc=0
    M8_OSSUTIL_BIN="$badbin" m8_oss_get_object 'runs/y08/present.txt' "$TMPROOT/y08-err" - || rc=$?
    assert_eq "$rc" "$M8_OSS_ERROR" 'Y08: a non-absence get-object failure returns M8_OSS_ERROR'
    assert_no_file "$TMPROOT/y08-err"

    # Tampered read-back is detected by the digest check, never accepted.
    local expected="$TMPROOT/y08-expected" tamper_src="$TMPROOT/y08-tamper-src"
    printf 'authoritative-bytes\n' >"$expected"
    c13_stage_key 'runs/y08/verify.txt' "$expected"
    m8_oss_verify_object 'runs/y08/verify.txt' "$expected" - || return 1
    printf 'tampered-bytes!\n' >"$tamper_src"
    c13_stage_key 'runs/y08/verify.txt' "$tamper_src"
    if m8_oss_verify_object 'runs/y08/verify.txt' "$expected" - 2>/dev/null; then
      printf 'Y08: a tampered read-back was accepted\n'
      return 1
    fi
    printf 'Y08_ERROR_SEMANTICS=PASS\n'
  )
}

# ===========================================================================
# R2I-C14 — formal invocation nonce binding / pre-core RC capture (Z01..Z06).
#
# C13 formal-failure forensics (do not reinterpret): the wrapper persisted the RAW
# runtime nonce as `invocation_nonce_sha256`, while the adapter verifies
# SHA256(M8_FORMAL_RUN_NONCE) == invocation_nonce_sha256, so every formal
# invocation died at `Mismatch: context_invocation_nonce`. Separately the adapter
# installed its EXIT trap AFTER context_validate, so that failure left no numeric
# adapter-exit-code.txt for the wrapper to capture.
#
# Z02..Z04 drive the REAL scripts/run-m8-proof-alibaba-ecs.sh through its real
# context_validate logic. They never fabricate adapter-exit-code.txt,
# formal-execution-rc.txt or outcome.txt to "prove" the handshake.
# ===========================================================================

# Build a temporary proof root holding the real adapter, the real libraries and a
# core stub that records invocation. The real adapter refuses to run with any
# synthetic seam set, so callers must launch it via `env -u` of the seven seams.
c14_real_adapter_fixture() {
  local root=$1
  mkdir -p "$root/scripts/lib"
  cp -a "$REPO_ROOT/scripts/lib/." "$root/scripts/lib/"
  cp "$ADAPTER" "$root/scripts/run-m8-proof-alibaba-ecs.sh"
  cat >"$root/scripts/run-m8-proof-core.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'core-invoked\n' >>"${M8_CORE_SENTINEL:?}"
EOF
  mkdir -p "$root/proof-artifacts"
}

# Write a valid formal invocation context. $1=root $2=runtime nonce
# [$3=persisted digest, defaulting to SHA256(runtime nonce)].
c14_write_context() {
  local root=$1 nonce=$2 persisted=${3:-}
  local auth_sha proof_sha proof_tree claim_sha
  auth_sha="$(printf 'z-token' | sha256sum | cut -d' ' -f1)"
  proof_sha='8c28875286cbf4170c1e67eea4948f0218be738f'
  proof_tree='9803f77a64493e47c28a3e47d96ad98dc5b65c3e'
  claim_sha="$(printf 'z-claim' | sha256sum | cut -d' ' -f1)"
  [[ -n "$persisted" ]] || persisted="$(printf '%s' "$nonce" | sha256sum | cut -d' ' -f1)"
  {
    printf 'schema=linguagraph-m8-formal-invocation-context/v1\n'
    printf 'formal_entrypoint=scripts/run-m8-proof.sh\n'
    printf 'authorization_kind=SEMANTIC\n'
    printf 'authorization_sha256=%s\n' "$auth_sha"
    printf 'semantic_auth_sha256=%s\n' "$auth_sha"
    printf 'proof_sha=%s\n' "$proof_sha"
    printf 'proof_tree=%s\n' "$proof_tree"
    printf 'candidate_sha=2441f9cf60b7cc9402c5b257be010b559b39b717\n'
    printf 'candidate_tree=5d1b7c7cc104cd365b0ea629d9ead7677d17f2be\n'
    printf 'candidate_parent=e4b1cc66f540ab74c0ef9bd014b0a0da3a2d9c1d\n'
    printf 'frozen_main=cf26ea557bd746a518ff32b8b7e7a7542be7f7ae\n'
    printf 'authorized_executor_id=alibaba-ecs:i-j6c9854oyawy89fcdxy2\n'
    printf 'executor_id=alibaba-ecs:i-j6c9854oyawy89fcdxy2\n'
    printf 'run_prefix=runs/%s/%s\n' "$proof_sha" "$auth_sha"
    printf 'claim_object=authorizations/%s/claim.json\n' "$auth_sha"
    printf 'claim_sha256=%s\n' "$claim_sha"
    printf 'invocation_nonce_sha256=%s\n' "$persisted"
  } >"$root/proof-artifacts/formal-invocation-context.txt"
}

# Run the real adapter with the seven seams unset and no OSS bucket configured, so
# a successful context_validate is followed by a deterministic PRE-NETWORK failure
# at claim verification. $1=root $2=runtime nonce $3=stdout file; prints the rc.
c14_run_real_adapter() {
  local root=$1 nonce=$2 out=$3 rc=0
  env -u M8_SYNTHETIC_TEST_MODE -u M8_IMDS_BASE_URL -u M8_IMDS_CURL_BIN \
    -u M8_OSSUTIL_BIN -u M8_OSSUTIL_GET_OUTPUT_FLAG \
    -u M8_ADAPTER_SCRIPT_OVERRIDE -u M8_PYTHON_BIN -u M8_OSS_BUCKET \
    M8_PROOF_ROOT="$root" \
    M8_FORMAL_WRAPPER_CONTEXT="$root/proof-artifacts/formal-invocation-context.txt" \
    M8_FORMAL_RUN_NONCE="$nonce" \
    M8_PROOF_RUN_AUTHORIZATION='z-token' \
    APPROVED_PROOF_SHA='8c28875286cbf4170c1e67eea4948f0218be738f' \
    M8_CORE_SENTINEL="$root/core-invoked.sentinel" \
    bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# Assert the real EXIT trap left a numeric adapter-exit-code.txt.
c14_assert_numeric_adapter_rc() {
  local root=$1 label=$2 code
  code="$(cat "$root/proof-artifacts/adapter-exit-code.txt" 2>/dev/null || printf '')"
  [[ "$code" =~ ^[0-9]+$ ]] ||
    { printf '%s: the real EXIT trap produced no numeric adapter-exit-code.txt (got %q)\n' "$label" "$code"; return 1; }
}

# Line number (1-based) of the first adapter line containing a literal pattern.
c14_adapter_line() {
  grep -n -F -- "$1" "$ADAPTER" | head -n1 | cut -d: -f1
}

# Require a located adapter line to be a real line number strictly before the trap.
c14_assert_before() {
  local label=$1 line=$2 trap_line=$3
  [[ "$line" =~ ^[0-9]+$ ]] ||
    { printf 'Z05: could not locate %s in the adapter\n' "$label"; return 1; }
  (( line < trap_line )) ||
    { printf 'Z05: %s is not before the EXIT trap (line=%s trap=%s)\n' "$label" "$line" "$trap_line"; return 1; }
}

# Z01 — the wrapper persists only SHA256(runtime nonce); the raw nonce stays
# process-local and never reaches the context file.
z01() {
  local sb target persisted runtime expect
  sb="$(mktemp -d "$TMPROOT/z01.XXXXXX")"
  target="$sb/evidence"
  mkdir -p "$target" "$sb/scripts"
  cp -a "$REPO_ROOT/scripts/lib" "$sb/scripts/lib"
  git -C "$sb" init -q
  git -C "$sb" add -A >/dev/null 2>&1 || true
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$sb" commit -qm 'z01 fixture' >/dev/null 2>&1 || true
  (
    # shellcheck source=/dev/null
    source "$WRAPPER"
    export M8_PROOF_ROOT="$sb"
    export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"
    AUTHORIZATION_KIND='SEMANTIC'
    AUTHORIZATION_SHA256="$(printf 'z01-token' | sha256sum | cut -d' ' -f1)"
    SEMANTIC_AUTH_SHA256="$AUTHORIZATION_SHA256"
    APPROVED_PROOF_SHA="$(git -C "$sb" rev-parse HEAD)"
    export APPROVED_PROOF_SHA
    RUN_PREFIX="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH_SHA256"
    CLAIM_OBJECT="authorizations/$AUTHORIZATION_SHA256/claim.json"
    CLAIM_SHA256="$(printf 'z01-claim' | sha256sum | cut -d' ' -f1)"
    m8_write_invocation_context "$target" || return 1

    persisted="$(sed -n 's/^invocation_nonce_sha256=//p' "$target/formal-invocation-context.txt")"
    runtime="${M8_FORMAL_RUN_NONCE:-}"
    [[ -n "$runtime" ]] || { printf 'Z01: the runtime nonce is absent\n'; return 1; }
    [[ "$runtime" =~ ^[0-9a-f]{64}$ ]] || { printf 'Z01: the runtime nonce is not SHA-256 shaped\n'; return 1; }
    expect="$(printf '%s' "$runtime" | sha256sum | cut -d' ' -f1)"
    assert_eq "$persisted" "$expect" 'Z01: persisted invocation_nonce_sha256 is SHA256(runtime nonce)'
    [[ "$persisted" != "$runtime" ]] ||
      { printf 'Z01: the raw runtime nonce was persisted as the _sha256 value\n'; return 1; }
    if grep -Fq "$runtime" "$target/formal-invocation-context.txt"; then
      printf 'Z01: the raw runtime nonce leaked into the persisted context\n'
      return 1
    fi
    printf 'Z01_NONCE_BINDING=PASS\n'
  )
}

# Z02 — GENUINE production integration: the REAL wrapper writer
# (m8_write_invocation_context) produces the context, and the REAL adapter then
# validates that exact context against the exact live runtime nonce, in one
# process environment. The success path must NOT come from the hand-written
# c14_write_context helper (that helper is used only by the Z03/Z04 tamper tests).
z02() {
  local root="$TMPROOT/z02-proof" out="$TMPROOT/z02.out" inner="$TMPROOT/z02-inner.sh" head_sha rc
  c14_real_adapter_fixture "$root"
  # A real git proof root is required: the real writer resolves HEAD^{tree}.
  git -C "$root" init -q
  git -C "$root" add -A >/dev/null 2>&1 || true
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$root" commit -qm 'z02 fixture' >/dev/null 2>&1 || true
  head_sha="$(git -C "$root" rev-parse HEAD)"

  # The inner shell sources the REAL wrapper, invokes the REAL writer, and in the
  # SAME process environment runs the REAL adapter. The raw nonce never leaves the
  # process environment (the writer exports M8_FORMAL_RUN_NONCE); it is never
  # written to a helper file.
  cat >"$inner" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$1; out=$2; wrapper=$3
export M8_PROOF_ROOT="$root"
export M8_CORE_SENTINEL="$root/core-invoked.sentinel"
# shellcheck source=/dev/null
source "$wrapper"
export APPROVED_PROOF_SHA="$(git -C "$root" rev-parse HEAD)"
export M8_EXECUTOR_ID="$M8_PROVIDER_EXECUTOR_ID"
token_sha="$(printf 'z02-token' | sha256sum | cut -d' ' -f1)"
AUTHORIZATION_KIND='SEMANTIC'
AUTHORIZATION_SHA256="$token_sha"
SEMANTIC_AUTH_SHA256="$token_sha"
RUN_PREFIX="runs/$APPROVED_PROOF_SHA/$SEMANTIC_AUTH_SHA256"
CLAIM_OBJECT="authorizations/$AUTHORIZATION_SHA256/claim.json"
CLAIM_SHA256="$(printf 'z02-claim' | sha256sum | cut -d' ' -f1)"
mkdir -p "$root/proof-artifacts"
# REAL writer: creates the context and exports the raw runtime nonce in-process.
m8_write_invocation_context "$root/proof-artifacts"
rc=0
bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1 || rc=$?
printf '%s' "$rc"
EOS

  rc="$(env -u M8_SYNTHETIC_TEST_MODE -u M8_IMDS_BASE_URL -u M8_IMDS_CURL_BIN \
    -u M8_OSSUTIL_BIN -u M8_OSSUTIL_GET_OUTPUT_FLAG \
    -u M8_ADAPTER_SCRIPT_OVERRIDE -u M8_PYTHON_BIN -u M8_OSS_BUCKET \
    M8_PROOF_RUN_AUTHORIZATION='z02-token' \
    bash "$inner" "$root" "$out" "$WRAPPER")"

  (( rc != 0 )) || { printf 'Z02: the real adapter unexpectedly succeeded\n'; return 1; }
  # The context must have been produced by the REAL writer, not the helper.
  grep -Fq "proof_sha=$head_sha" "$root/proof-artifacts/formal-invocation-context.txt" ||
    { printf 'Z02: the context was not produced by the real wrapper writer\n'; return 1; }
  if grep -Fq 'context_invocation_nonce' "$out"; then
    printf 'Z02: the real writer->adapter handshake still failed context_invocation_nonce\n'
    return 1
  fi
  grep -Fq 'OSS bucket configuration is required for formal execution' "$out" ||
    { printf 'Z02: the adapter did not progress beyond context_validate:\n%s\n' "$(cat "$out")"; return 1; }
  grep -Fq 'adapter_mode=FORMAL' "$root/proof-artifacts/adapter-provenance.txt" 2>/dev/null ||
    { printf 'Z02: the adapter never recorded FORMAL adapter mode\n'; return 1; }
  assert_no_file "$root/core-invoked.sentinel"
  c14_assert_numeric_adapter_rc "$root" 'Z02' || return 1
  printf 'Z02_REAL_HANDSHAKE=PASS\n'
}

# Z03 — persisted digest binds nonce A while the runtime presents nonce B.
z03() {
  local root="$TMPROOT/z03-proof" out="$TMPROOT/z03.out" nonce_a nonce_b rc
  c14_real_adapter_fixture "$root"
  nonce_a="$(printf 'z03-nonce-A' | sha256sum | cut -d' ' -f1)"
  nonce_b="$(printf 'z03-nonce-B' | sha256sum | cut -d' ' -f1)"
  c14_write_context "$root" "$nonce_a"
  rc="$(c14_run_real_adapter "$root" "$nonce_b" "$out")"
  (( rc != 0 )) || { printf 'Z03: a tampered runtime nonce was accepted\n'; return 1; }
  grep -Fq 'context_invocation_nonce' "$out" ||
    { printf 'Z03: the runtime-nonce tamper did not fail context_invocation_nonce:\n%s\n' "$(cat "$out")"; return 1; }
  assert_no_file "$root/core-invoked.sentinel"
  if grep -Fq 'adapter_mode=FORMAL' "$root/proof-artifacts/adapter-provenance.txt" 2>/dev/null; then
    printf 'Z03: the adapter reached FORMAL mode despite a nonce mismatch\n'
    return 1
  fi
  c14_assert_numeric_adapter_rc "$root" 'Z03' || return 1
  printf 'Z03_TAMPERED_RUNTIME_NONCE=PASS\n'
}

# Z04 — the runtime nonce is correct but the persisted digest was altered.
z04() {
  local root="$TMPROOT/z04-proof" out="$TMPROOT/z04.out" nonce wrong rc
  c14_real_adapter_fixture "$root"
  nonce="$(printf 'z04-nonce-correct' | sha256sum | cut -d' ' -f1)"
  wrong="$(printf 'z04-nonce-wrong' | sha256sum | cut -d' ' -f1)"
  c14_write_context "$root" "$nonce" "$wrong"
  rc="$(c14_run_real_adapter "$root" "$nonce" "$out")"
  (( rc != 0 )) || { printf 'Z04: a tampered persisted nonce digest was accepted\n'; return 1; }
  grep -Fq 'context_invocation_nonce' "$out" ||
    { printf 'Z04: the persisted-digest tamper did not fail context_invocation_nonce:\n%s\n' "$(cat "$out")"; return 1; }
  assert_no_file "$root/core-invoked.sentinel"
  if grep -Fq 'adapter_mode=FORMAL' "$root/proof-artifacts/adapter-provenance.txt" 2>/dev/null; then
    printf 'Z04: the adapter reached FORMAL mode despite a digest mismatch\n'
    return 1
  fi
  c14_assert_numeric_adapter_rc "$root" 'Z04' || return 1
  printf 'Z04_TAMPERED_PERSISTED_DIGEST=PASS\n'
}

# Z05 — static ordering. There must be exactly ONE `trap adapter_finalize EXIT`,
# and EVERY formal-entry eligibility boundary must precede it, with
# adapter_finalize defined < trap < context_validate < core invocation.
z05() {
  local trap_count trap_line ctx_line core_line def_line
  trap_count="$(grep -c -F 'trap adapter_finalize EXIT' "$ADAPTER")"
  assert_eq "$trap_count" '1' 'Z05: exactly one adapter_finalize EXIT trap installation'
  trap_line="$(c14_adapter_line 'trap adapter_finalize EXIT')"
  [[ "$trap_line" =~ ^[0-9]+$ ]] || { printf 'Z05: the EXIT trap was not located\n'; return 1; }

  local seam_line root_line presence_line path_line ctxfile_line evid_line
  local corefile_line redir_line circle_line
  seam_line="$(c14_adapter_line 'm8_reject_synthetic_overrides ||')"
  root_line="$(c14_adapter_line 'the proof repository root could not be resolved')"
  presence_line="$(c14_adapter_line '[[ -n "${M8_FORMAL_WRAPPER_CONTEXT:-}" ]] ||')"
  path_line="$(c14_adapter_line '[[ "$M8_FORMAL_WRAPPER_CONTEXT" == "$CONTEXT_FILE" ]] ||')"
  ctxfile_line="$(c14_adapter_line '[[ -f "$CONTEXT_FILE" ]] ||')"
  evid_line="$(c14_adapter_line '[[ -d "$EVIDENCE" ]] ||')"
  corefile_line="$(c14_adapter_line 'semantic core is missing')"
  redir_line="$(c14_adapter_line 'M8_PROOF_EVIDENCE_DIR must be unset or exactly')"
  circle_line="$(c14_adapter_line 'for v in CIRCLE_PROJECT_USERNAME')"

  c14_assert_before 'the synthetic-seam rejection' "$seam_line" "$trap_line" || return 1
  c14_assert_before 'the resolved proof-root guard' "$root_line" "$trap_line" || return 1
  c14_assert_before 'the wrapper-context presence guard' "$presence_line" "$trap_line" || return 1
  c14_assert_before 'the wrapper-context path-equality guard' "$path_line" "$trap_line" || return 1
  c14_assert_before 'the context-file existence guard' "$ctxfile_line" "$trap_line" || return 1
  c14_assert_before 'the evidence-directory existence guard' "$evid_line" "$trap_line" || return 1
  c14_assert_before 'the semantic-core existence guard' "$corefile_line" "$trap_line" || return 1
  c14_assert_before 'the evidence-redirection rejection' "$redir_line" "$trap_line" || return 1
  c14_assert_before 'the CircleCI spoof rejection' "$circle_line" "$trap_line" || return 1

  def_line="$(c14_adapter_line 'adapter_finalize() {')"
  ctx_line="$(grep -n -x -F 'context_validate' "$ADAPTER" | head -n1 | cut -d: -f1)"
  core_line="$(c14_adapter_line 'bash "$CORE" || CORE_RC=$?')"
  c14_assert_before 'the adapter_finalize definition' "$def_line" "$trap_line" || return 1
  [[ "$ctx_line" =~ ^[0-9]+$ ]] || { printf 'Z05: the context_validate invocation was not located\n'; return 1; }
  [[ "$core_line" =~ ^[0-9]+$ ]] || { printf 'Z05: the core invocation was not located\n'; return 1; }
  (( trap_line < ctx_line )) ||
    { printf 'Z05: the EXIT trap is not installed before context_validate (trap=%s ctx=%s)\n' "$trap_line" "$ctx_line"; return 1; }
  (( ctx_line < core_line )) ||
    { printf 'Z05: context_validate is not before the core invocation (ctx=%s core=%s)\n' "$ctx_line" "$core_line"; return 1; }
  printf 'Z05_TRAP_ORDERING=PASS\n'
}

# Z06 — a direct NONFORMAL invocation still refuses before any trap exists and
# creates no formal adapter RC/evidence state.
z06() {
  local root="$TMPROOT/z06-proof" out="$TMPROOT/z06.out" rc=0 sentinel="$TMPROOT/z06-core.sentinel"
  c14_real_adapter_fixture "$root"
  rm -rf "$root/proof-artifacts"
  rm -f "$sentinel"
  env -u M8_SYNTHETIC_TEST_MODE -u M8_IMDS_BASE_URL -u M8_IMDS_CURL_BIN \
    -u M8_OSSUTIL_BIN -u M8_OSSUTIL_GET_OUTPUT_FLAG \
    -u M8_ADAPTER_SCRIPT_OVERRIDE -u M8_PYTHON_BIN \
    -u M8_FORMAL_WRAPPER_CONTEXT -u M8_FORMAL_RUN_NONCE \
    M8_PROOF_ROOT="$root" M8_CORE_SENTINEL="$sentinel" \
    bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1 || rc=$?
  (( rc != 0 )) || { printf 'Z06: a direct NONFORMAL adapter invocation succeeded\n'; return 1; }
  assert_contains "$out" 'M8_ADAPTER_MODE=NONFORMAL'
  assert_contains "$out" 'M8_FORMAL_STATUS=NOT_APPLICABLE'
  assert_no_file "$sentinel"
  assert_no_file "$root/proof-artifacts"
  assert_no_file "$root/candidate"
  local residue
  residue="$(find "$root" \( -name 'adapter-exit-code.txt' -o -name 'formal-execution-rc.txt' -o -name 'outcome.txt' \) -print 2>/dev/null)"
  [[ -z "$residue" ]] ||
    { printf 'Z06: a NONFORMAL invocation created formal RC state: %s\n' "$residue"; return 1; }
  printf 'Z06_NONFORMAL_PRESERVED=PASS\n'
}

# ===========================================================================
# R2I-C15 — adapter canonical proof-root propagation (W01).
#
# C14 hosted failure forensics (do not reinterpret): the wrapper resolved
# M8_PROOF_ROOT as an unexported shell variable, so the adapter child never saw
# it. The adapter then resolved its own PROOF_ROOT from git but did NOT publish it
# back into M8_PROOF_ROOT, so the first proof-root-dependent OSS helper call died
# with "M8_PROOF_ROOT is not set; cannot resolve the canonical OSS config" inside
# m8_oss_canonical_config_guard, before any adapter OSS network request and before
# the claim read-back. The semantic core was never invoked.
#
# The C14 fixtures could not catch this because they explicitly supply
# M8_PROOF_ROOT to the adapter. W01 reproduces the real hosted environment gap:
# M8_PROOF_ROOT is ABSENT at adapter launch and the adapter must self-resolve.
# ===========================================================================

# Real proof-tree fixture for the C15 regression: real adapter, real libraries,
# the frozen canonical OSS config, a core sentinel stub, and a real git root.
c15_real_adapter_fixture() {
  local root=$1
  mkdir -p "$root/scripts/lib" "$root/scripts/config" "$root/proof-artifacts"
  cp -a "$REPO_ROOT/scripts/lib/." "$root/scripts/lib/"
  cp "$ADAPTER" "$root/scripts/run-m8-proof-alibaba-ecs.sh"
  cp "$REPO_ROOT/scripts/config/m8-ossutil-formal.ini" "$root/scripts/config/m8-ossutil-formal.ini"
  cat >"$root/scripts/run-m8-proof-core.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'core-invoked\n' >>"${M8_CORE_SENTINEL:?}"
EOF
  git -C "$root" init -q
  git -C "$root" add -A >/dev/null 2>&1 || true
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$root" commit -qm 'c15 fixture' >/dev/null 2>&1 || true
}

# W01 — with M8_PROOF_ROOT ABSENT at launch and the adapter started from inside its
# own proof tree, the adapter must self-resolve the proof root, publish it, and
# therefore advance PAST the historical proof-root propagation failure into the
# intended later pre-network fail-closed diagnostic. No OSS/provider access.
w01() {
  local root="$TMPROOT/c15-proof" out="$TMPROOT/c15.out" nonce rc=0
  local pathdir="$TMPROOT/c15-bin" ossutil_sentinel="$TMPROOT/c15-ossutil-invoked"
  local curl_sentinel="$TMPROOT/c15-curl-invoked"
  c15_real_adapter_fixture "$root"

  # PATH-only client stubs. The production-forbidden M8_OSSUTIL_BIN and
  # M8_IMDS_CURL_BIN synthetic seams are deliberately NOT set, so the real code
  # would resolve `ossutil` and `curl` from PATH. Both stubs record any invocation:
  # that is the explicit proof that no OSS client AND no IMDS/provider client was
  # ever reached in this fail-closed path.
  mkdir -p "$pathdir"
  cat >"$pathdir/ossutil" <<'EOF'
#!/usr/bin/env bash
printf 'ossutil-stub-invoked\n' >>"${C15_OSSUTIL_SENTINEL:?}"
printf 'synthetic ossutil: no operation performed\n'
exit 0
EOF
  cat >"$pathdir/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl-stub-invoked\n' >>"${C15_CURL_SENTINEL:?}"
exit 22
EOF
  chmod +x "$pathdir/ossutil" "$pathdir/curl"
  rm -f "$ossutil_sentinel" "$curl_sentinel"

  nonce="$(printf 'c15-nonce' | sha256sum | cut -d' ' -f1)"
  c14_write_context "$root" "$nonce"
  assert_file "$root/scripts/config/m8-ossutil-formal.ini"

  # Launch from INSIDE the fixture with M8_PROOF_ROOT explicitly removed, so the
  # adapter must resolve the root itself via `git rev-parse --show-toplevel`.
  (
    cd "$root" || exit 1
    env -u M8_PROOF_ROOT -u M8_OSS_ECS_ROLE_NAME -u M8_SYNTHETIC_TEST_MODE \
      -u M8_IMDS_BASE_URL -u M8_IMDS_CURL_BIN -u M8_OSSUTIL_BIN \
      -u M8_OSSUTIL_GET_OUTPUT_FLAG -u M8_ADAPTER_SCRIPT_OVERRIDE -u M8_PYTHON_BIN \
      -u M8_PROOF_EVIDENCE_DIR \
      PATH="$pathdir:$PATH" \
      M8_OSS_BUCKET='test-bucket' \
      M8_FORMAL_WRAPPER_CONTEXT="$root/proof-artifacts/formal-invocation-context.txt" \
      M8_FORMAL_RUN_NONCE="$nonce" \
      M8_PROOF_RUN_AUTHORIZATION='z-token' \
      APPROVED_PROOF_SHA='8c28875286cbf4170c1e67eea4948f0218be738f' \
      M8_CORE_SENTINEL="$root/core-invoked.sentinel" \
      C15_OSSUTIL_SENTINEL="$ossutil_sentinel" \
      C15_CURL_SENTINEL="$curl_sentinel" \
      bash "$root/scripts/run-m8-proof-alibaba-ecs.sh" >"$out" 2>&1
  ) || rc=$?

  (( rc != 0 )) || { printf 'W01: the adapter unexpectedly succeeded\n'; return 1; }

  # The claim read-back OSS log is the exact production locus where the historical
  # hosted failure was recorded.
  local osslog="$root/proof-artifacts/adapter-oss.log"
  assert_file "$osslog"

  # A. The historical proof-root propagation failure locus must be GONE, in the
  #    adapter stream AND in the OSS log.
  if grep -Fq 'M8_PROOF_ROOT is not set; cannot resolve the canonical OSS config' "$out" "$osslog"; then
    printf 'W01: the historical M8_PROOF_ROOT propagation failure is still present:\n%s\n%s\n' \
      "$(cat "$out")" "$(cat "$osslog")"
    return 1
  fi
  # The canonical config must genuinely have been resolved (not merely "not errored").
  if grep -Fq 'canonical OSS config is absent' "$out" "$osslog"; then
    printf 'W01: the adapter did not resolve the canonical config from its own root:\n%s\n' "$(cat "$osslog")"
    return 1
  fi

  # B. Execution must have advanced to the intended later pre-network fail-closed
  #    diagnostic: the observed ECS role binding has not been established.
  grep -Fq 'observed ECS RAM role name is not established; refusing any OSS call' "$osslog" ||
    { printf 'W01: the intended later pre-network diagnostic is absent from the OSS log:\n%s\n' "$(cat "$osslog")"; return 1; }
  # ...and the read-back must have been attempted through the canonical root path.
  grep -Fq 'get_object key=authorizations/' "$osslog" ||
    { printf 'W01: no claim read-back attempt was logged:\n%s\n' "$(cat "$osslog")"; return 1; }

  # fail-closed progression, core never invoked, and no OSS client AND no
  # IMDS/provider client ever reached (PATH-only sentinels)
  assert_no_file "$root/core-invoked.sentinel"
  assert_no_file "$ossutil_sentinel"
  assert_no_file "$curl_sentinel"
  c14_assert_numeric_adapter_rc "$root" 'W01' || return 1
  local code
  code="$(cat "$root/proof-artifacts/adapter-exit-code.txt")"
  [[ "$code" != '0' ]] || { printf 'W01: the adapter reported RC 0 on a fail-closed path\n'; return 1; }

  # no durable artifact of any canonical kind was created by this regression,
  # including the canonical archive (+ sidecar) and the closure-receipt readback
  local residue
  residue="$(find "$root" \( \
    -name 'claim.json' -o -name 'claim-adapter-readback.json' \
    -o -name 'closure-receipt.json' -o -name 'closure-receipt.readback.json' \
    -o -name 'closure-receipt-check.json' -o -name 'existing-closure-receipt.json' \
    -o -name 'package-index.json' \
    -o -name 'm8-proof-artifacts-*.tar.gz' -o -name 'm8-proof-artifacts-*.tar.gz.sha256' \
    \) -print 2>/dev/null)"
  [[ -z "$residue" ]] ||
    { printf 'W01: the regression created durable-looking objects: %s\n' "$residue"; return 1; }

  printf 'W01_ADAPTER_ROOT_PROPAGATION=PASS\n'
}

# ===========================================================================
printf '===== M8-HSDR-F02 R2E-B01 + R2I-C1 offline verification =====\n'
printf 'repo=%s\n' "$REPO_ROOT"

for f in "$WRAPPER" "$CORE" "$ADAPTER" "$PREFLIGHT" "$OSS_LIB" "$IDENTITY_LIB" \
  "$MANIFEST_LIB" "$SEAMS_LIB"; do
  bash -n "$f" || { printf 'SYNTAX FAILURE: %s\n' "$f"; exit 1; }
done

run_check static V01 'core never writes core-exit-code.txt; adapter owns that RC' v01
run_check static V02 'adapter captures the core RC immediately after the child returns' v02
run_check static V03 'adapter-exit-code.txt is written by the adapter EXIT trap' v03
run_check static V04 'wrapper captures formal-execution-rc.txt immediately after the adapter' v04
run_check static V05 'wrapper cross-checks the two RC records and fails closed' v05
run_check synth V06 'absent/empty/mismatched/non-numeric RC fixtures fail closed' v06
run_check synth V07 'SIGTERM yields a distinct numeric RC (143)' v07
run_check synth V08 'SIGKILL does not fabricate an in-process adapter RC' v08
run_check synth V09 'the closure receipt is the last mutating commit object' v09
run_check synth V10 'a sealed archive mutated after its digest fails durability' v10
run_check synth V11 'a durability failure produces no closure receipt' v11
run_check synth V12 'receipt read-back tamper fails closed without a formal RC' v12
run_check synth V13 'success: fetched receipt RC == terminal marker == wrapper success' v13
run_check synth V14 'ALREADY_COMMITTED re-invocation hard-refuses without a formal RC' v14
run_check synth V15 'the adapter refuses to run without wrapper formal context' v15
run_check synth V16 'a claim without a receipt cannot be re-consumed' v16
run_check static V17 'provider identity constants are single-sourced and guards fail closed' v17
run_check static V18 'wrapper order and fail-closed guards in condition contexts' v18
run_check static V19 'adapter re-verifies identity after the claim and creates no canonical object' v19
run_check static V20 'create-if-absent only; capability guard fails closed; no HEAD-then-PUT' v20
run_check synth V21 'versioning Enabled fails closed' v21
run_check synth V22 'versioning Suspended fails closed' v22
run_check synth V23 'versioning Null/Unversioned is eligible' v23
run_check synth V24 'unparseable and access-denied versioning fail closed' v24
run_check synth V25 'FileAlreadyExists never overwrites' v25
run_check synth V26 'the versioning guard precedes the first PutObject' v26
run_check synth V27 'valid Playwright JSON writes the exact effective-retries file' v27
run_check synth V28 'project retries != 0 fails closed' v28
run_check synth V29 'non-chromium project set fails closed' v29
run_check synth V30 'unexpected/flaky/skipped counts fail closed' v30
run_check synth V31 'missing or unparseable Playwright report fails closed' v31
run_check static V32 'core uses CI=1, one reporter option and an explicit JSON file' v32
run_check static V33 'core keeps retries=0, fail-on-flaky and the seven frozen specs' v33
run_check synth V34 'artifact completeness fails closed on missing artifacts' v34
run_check synth V35 'no receipt carries a redundant terminal_line field' v35
run_check synth V36 'receipt cross-binding/digest/provider fields are self-consistent' v36
run_check synth V37 'a receipt whose formal_command_rc is not 0 is rejected' v37
run_check synth V38 'issuer/executor split documented; no delete/versioning-write authority' v38
run_check synth V39 'a retry cannot regenerate a missing package-index' v39
run_check synth V40 'a retry never reruns core/adapter and writes only canonical objects' v40

printf '\n----- R2E-B01 correction regressions (C01..C09) -----\n'
run_check corr C01 'B1 token -> authorization_sha256; no issued.json self-reference' c01
run_check corr C02 'B1 mismatched issued.json.authorization_sha256 fails closed' c02
run_check corr C03 'B2 both production entrypoints reject all seven production override seams' c03
run_check corr C04 'B3 JSON report uses the Playwright testDir-relative suite.file namespace' c04
run_check corr C05 'B4 every PutObject uses the official file:// body form' c05
run_check corr C06 'B5 completeness rejects unexpected/unclassified artifacts' c06
run_check corr C07 'B5 required-list duplicates/absolute/traversal/globs are rejected' c07
run_check corr C08 'B5 manifest exact-set, self-hash and digest validation' c08
run_check corr C09 'R2E-B01 reserved manifest is exactly one root-relative path' c09

printf '\n----- R2I-C1 regressions (I01..I02) -----\n'
run_check r2i I01 'M8_ADAPTER_SCRIPT_OVERRIDE rejected fail-closed by both entrypoints' i01
run_check r2i I02 'M8_PYTHON_BIN rejected fail-closed by both entrypoints' i02

printf '\n----- R2I-C4/B03 trust-target regressions (T01..T12) -----\n'
run_check r2i_c4 T01 'closed 19-name OSS trust environment, separate from the 7 C1 seams' t01
run_check r2i_c4 T02 'every API call is issued through the exact frozen CLI trust target' t02
run_check r2i_c4 T03 'canonical proof-tree role-bound config identity and fail-closed mutation' t03
run_check r2i_c4 T04 'ossutil path/version/binary identity with a 2.2.0 minimum' t04
run_check r2i_c4 T05 'bucket-location guard rejects non-canonical locations before any write' t05
run_check r2i_c4 T06 'read-only single role-name observation; credential payload never requested' t06
run_check r2i_c4 T07 '18-record trust-profile canonicalization and digest sensitivity' t07
run_check r2i_c4 T08 'issued authorization binds the exact trust profile before claim' t08
run_check r2i_c4 T09 'claim, package index and receipt all bind the trust profile' t09
run_check r2i_c4 T10 'receipt carriers and verifier expectation are load-bearing' t10
run_check r2i_c4 T11 'retry trust-target mismatch fails closed; matching retry never reruns core' t11
run_check r2i_c4 T12 'pre-claim order: first permitted write is the atomic claim' t12

printf '\n----- R2I-C7 provider binary-safety regressions (P01..P04) -----\n'
run_check r2i_c7 P01 'five scalar immutable NUL bypasses fail closed before the tuple comparison' p01
run_check r2i_c7 P02 'identity document and PKCS7 NUL bodies fail before digest acceptance' p02
run_check r2i_c7 P03 'preflight uses the shared byte-safe authority for immutable inputs' p03
run_check r2i_c7 P04 'clean provider semantics and canonical digests match the pre-C7 oracle' p04

printf '\n----- R2I-C11 auth-path correction regressions (S01..S18) -----\n'
run_check r2i_c11 S01 'canonical config is exactly 81 bytes' s01
run_check r2i_c11 S02 'canonical config SHA-256 is the frozen value' s02
run_check r2i_c11 S03 'canonical config semantic content is exact' s03
run_check r2i_c11 S04 'production CLI vector contains the five frozen pins' s04
run_check r2i_c11 S05 'production CLI vector has no --mode and no --ecs-role-name' s05
run_check r2i_c11 S06 'synthetic help does not advertise --ecs-role-name' s06
run_check r2i_c11 S07 'synthetic ossutil models the exact 2.4.0 CLI mode set; rejects --ecs-role-name, Ali-EcsRamRole, RamRoleArn' s07
run_check r2i_c11 S08 'missing stored observed role fails closed before OSS' s08
run_check r2i_c11 S09 'stored role disagreeing with the config fails closed' s09
run_check r2i_c11 S10 'fresh live role disagreeing with stored/config fails closed' s10
run_check r2i_c11 S11 'missing durable provider helper fails closed' s11
run_check r2i_c11 S12 'triple-equal role binding permits the synthetic OSS call' s12
run_check r2i_c11 S13 'auth mode constant is Ali-EcsRamRole' s13
run_check r2i_c11 S14 'config policy id and 81-byte identity constants' s14
run_check r2i_c11 S15 'trust profile stays 18 records with exact LF semantics' s15
run_check r2i_c11 S16 'trust profile records the new auth mode / config identity' s16
run_check r2i_c11 S17 'trust-profile digest is sensitive to bucket, role, version, binary' s17
run_check r2i_c11 S18 'a mismatched role cannot produce an eligible network path' s18

printf '\n----- R2I-C12 versioning classifier correction regressions (X01..X27) -----\n'
run_check r2i_c12 X01 'exact live 94-byte XML+timing capture is eligible via the structured classifier' x01
run_check r2i_c12 X02 'structural positives: no Status (both namespaces), Null, empty response' x02
run_check r2i_c12 X03 'versioning Enabled is rejected' x03
run_check r2i_c12 X04 'versioning Suspended is rejected' x04
run_check r2i_c12 X05 'a non-zero versioning query RC is rejected' x05
run_check r2i_c12 X06 'an unknown XML namespace is rejected' x06
run_check r2i_c12 X07 'an unexpected child is rejected' x07
run_check r2i_c12 X08 'a duplicate Status is rejected' x08
run_check r2i_c12 X09 'a nested Status is rejected' x09
run_check r2i_c12 X10 'an unexpected root attribute is rejected' x10
run_check r2i_c12 X11 'a wrong root element is rejected' x11
run_check r2i_c12 X12 'malformed XML is rejected' x12
run_check r2i_c12 X13 'DOCTYPE is rejected' x13
run_check r2i_c12 X14 'ENTITY is rejected' x14
run_check r2i_c12 X15 'unknown trailing text is rejected' x15
run_check r2i_c12 X16 'a double timing footer is rejected' x16
run_check r2i_c12 X17 'unknown/aliased/lower-cased Status values fail closed' x17
run_check r2i_c12 X18 'stray text, tails, attributes, bad footer grammar and invalid UTF-8 fail closed' x18
run_check r2i_c12 X19 'the XML branch is structured ElementTree parsing, never broad regex' x19
run_check r2i_c12 X20 'a malformed XML declaration is rejected, never repaired' x20
run_check r2i_c12 X21 'a valid XML declaration is validated by the XML parser and accepted' x21
run_check r2i_c12 X22 'a comment or processing-instruction child is rejected' x22
run_check r2i_c12 X23 'document-level comments/PIs around the root are rejected' x23
run_check r2i_c12 X24 'the timing footer must match the frozen grammar exactly' x24
run_check r2i_c12 X25 'a misplaced declaration is rejected; leading whitespace follows parser semantics' x25
run_check r2i_c12 X26 'comment-only/PI-only documents and an encoding declaration are classified correctly' x26
run_check r2i_c12 X27 'no prolog pre-processing, observable comments/PIs, exact footer match' x27

printf '\n----- R2I-C13 GetObject byte-exactness regressions (Y01..Y08) -----\n'
run_check r2i_c13 Y01 'no-quiet get-object stdout is body + deterministic elapsed footer (not byte-exact)' y01
run_check r2i_c13 Y02 'production m8_oss_get_object frames GetObject with --quiet; --quiet is not a sixth pin' y02
run_check r2i_c13 Y03 'text payload is byte-exact through production get-object' y03
run_check r2i_c13 Y04 'arbitrary binary payload (NUL/CR/LF/DEL/0x80/0xFF) is byte-exact through production get-object' y04
run_check r2i_c13 Y05 'no-get-object-quiet guards fail closed AND reject --quiet/-q at runtime while ordinary GetObject works' y05
run_check r2i_c13 Y06 'ordinary corrected capability surface still passes' y06
run_check r2i_c13 Y07 'the synthetic --output response-body seam stays byte-exact and quiet-framed' y07
run_check r2i_c13 Y08 'absent/error/cleanup/rename/tampered-readback semantics preserved' y08

printf '\n----- R2I-C14 formal invocation nonce / pre-core RC regressions (Z01..Z06) -----\n'
run_check r2i_c14 Z01 'wrapper persists SHA256(runtime nonce); the raw nonce stays process-local' z01
run_check r2i_c14 Z02 'real wrapper writer -> real adapter: generated context validates and stops pre-network with a numeric RC' z02
run_check r2i_c14 Z03 'tampered runtime nonce fails context_invocation_nonce with a numeric adapter RC' z03
run_check r2i_c14 Z04 'tampered persisted nonce digest fails context_invocation_nonce with a numeric adapter RC' z04
run_check r2i_c14 Z05 'exactly one EXIT trap, after every eligibility boundary and before context_validate/core' z05
run_check r2i_c14 Z06 'direct NONFORMAL invocation still refuses and creates no adapter RC state' z06

printf '\n----- R2I-C15 adapter canonical proof-root propagation regressions (W01) -----\n'
run_check r2i_c15 W01 'adapter self-resolves and exports M8_PROOF_ROOT so sourced OSS helpers see the canonical root' w01

printf '\n===== summary =====\n'
printf 'R2E_B01_LEGACY_V01_V40=%s/%s\n' \
  "$((STATIC_PASS + SYNTH_PASS))" "$((STATIC_TOTAL + SYNTH_TOTAL))"
printf 'R2E_B01_CORRECTION_REGRESSIONS=%s/%s\n' "$CORR_PASS" "$CORR_TOTAL"
printf 'R2E_B01_STATIC_CHECKS=%s/%s\n' "$STATIC_PASS" "$STATIC_TOTAL"
printf 'R2E_B01_SYNTHETIC_CHECKS=%s/%s\n' "$SYNTH_PASS" "$SYNTH_TOTAL"
printf 'R2I_C1_REGRESSIONS=%s/%s\n' "$R2I_PASS" "$R2I_TOTAL"
printf 'R2I_C4_B03_REGRESSIONS=%s/%s\n' "$R2I_C4_PASS" "$R2I_C4_TOTAL"
printf 'R2I_C7_PROVIDER_BINARY_REGRESSIONS=%s/%s\n' "$R2I_C7_PASS" "$R2I_C7_TOTAL"
printf 'R2I_C11_AUTH_PATH_REGRESSIONS=%s/%s\n' "$R2I_C11_PASS" "$R2I_C11_TOTAL"
printf 'R2I_C12_VERSIONING_CLASSIFIER_REGRESSIONS=%s/%s\n' "$R2I_C12_PASS" "$R2I_C12_TOTAL"
printf 'R2I_C13_GETOBJECT_BYTE_EXACTNESS_REGRESSIONS=%s/%s\n' "$R2I_C13_PASS" "$R2I_C13_TOTAL"
printf 'R2I_C14_FORMAL_CONTEXT_REGRESSIONS=%s/%s\n' "$R2I_C14_PASS" "$R2I_C14_TOTAL"
printf 'R2I_C15_ADAPTER_PROOF_ROOT_REGRESSIONS=%s/%s\n' "$R2I_C15_PASS" "$R2I_C15_TOTAL"
if ((${#FAILED_CHECKS[@]})); then
  printf 'R2E_B01_OFFLINE_VERIFICATION=FAIL failed=%s\n' "${FAILED_CHECKS[*]}"
  exit 1
fi
printf 'R2E_B01_OFFLINE_VERIFICATION=PASS\n'
